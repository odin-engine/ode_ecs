/*
    2026 (c) Oleh, https://github.com/zm69

    Many-to-many relations ("pairs"), unlike Relations_Table's single-parent
    model: a holder can point at any number of targets, and a target can be
    pointed at by any number of holders.

    Unlike Relations_Table, a Pair_Table DOES affect Views. Every Pair_Table
    owns a real Tag_Table (`presence`) with one row per holder that currently
    has >= 1 pair — that Tag_Table gets full, correct View-subscriber
    notification for free, so `{&pairs.presence}` is
    usable directly in view_init's includes/excludes/any_of to mean "has (or
    doesn't have) at least one pair of this relation." The actual
    (holder, target, data) rows live in a separate, non-View-visible, freelist-
    based row array, cross-indexed by TWO intrusive doubly-linked lists per
    row — one by holder (first_pair/next_pair/prev_pair, same technique
    Relations_Table uses for first_child/next_sibling, generalized from
    "children of a parent" to "pair-rows of a holder"), one by target
    (first_pair_by_target/next_pair_by_target/prev_pair_by_target, for O(1)
    per-row target-destroy cleanup).
    Rows are never tail-swapped/compacted — that would break Pair_Row_Id
    stability for both linked lists on every remove.

    Split into a non-generic Pair_Table_Base (everything except the payload
    array) and the generic Pair_Table($T) wrapper (adds only `data: []T`).
    This is what lets database.odin (target-destroy cleanup) and
    command_buffer.odin (cmd_pair_add/cmd_pair_remove replay) operate on a
    Pair_Table without knowing T — they only ever see a ^Pair_Table_Base,
    obtained from Database.pair_tables. Pair_Table_Raw
    mirrors Table_Raw's technique (table.odin) for freeing the generic `data`
    slice without knowing T: same field name/position as Pair_Table($T)'s
    `data`, reinterpreted as []byte via a same-address cast.

    database__terminate automatically terminates any still-attached
    Pair_Table — same as Relations_Table, which is also
    not itself a Shared_Table. pair_table__terminate remains available for
    early/explicit termination; both paths funnel through the same
    pair_table_base__terminate, so there's no double-terminate risk.

    Destroying an entity that appears as a TARGET is handled the same as a
    destroyed holder: every referencing
    row is removed, O(#pairs for that target) via first_pair_by_target, not a
    full-table scan — this must stay cheap since destroy_entity is a
    universal hot path, run for every entity regardless of whether it's ever
    touched a Pair_Table. Pair_Table is also a Command_Buffer target
    (cmd_pair_add/cmd_pair_remove) and
    serialization-aware (pair_table_base__snapshot_write/apply) — both close over pair_table_base__add_raw, the same
    type-erased entry point the generic pair_table__add wraps.
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"

// ODE
    import oc "ode_core"

    Pair_Row_Id :: distinct int // index into the pair-row arrays; DELETED_INDEX = none

///////////////////////////////////////////////////////////////////////////////
// Pair_Table

    Pair_Table_Base :: struct {
        db:    ^Database,
        state: Object_State,
        id:    pair_table_id,

        presence: Tag_Table, // one row per holder with >= 1 pair — drives View matching

        pairs_cap:   int,
        pairs_count: int,

        // Freelist-based, never compacted (unlike Table($T)'s tail-swap) — a dense/tail-swapped array would break Pair_Row_Id stability for the linked lists below on every remove.
        targets:    []entity_id,   // pairs_cap
        row_holder: []entity_id,   // pairs_cap — owning holder, for freelist recycling

        // Doubly-linked list of a holder's pair rows, head-insert.
        next_pair:  []Pair_Row_Id, // pairs_cap
        prev_pair:  []Pair_Row_Id, // pairs_cap
        first_pair: []Pair_Row_Id, // entities_cap, indexed by holder.ix

        // Doubly-linked list of a target's pair rows, head-insert — lets pair_table_base__remove_target run in O(#pairs for that target) instead of O(pairs_cap).
        next_pair_by_target:  []Pair_Row_Id, // pairs_cap
        prev_pair_by_target:  []Pair_Row_Id, // pairs_cap
        first_pair_by_target: []Pair_Row_Id, // entities_cap, indexed by target.ix

        free_rows:  []Pair_Row_Id, // pairs_cap, freelist stack
        free_count: int,

        // targets_of() result buffer — valid only until the next call or any structural change.
        scratch: []entity_id, // pairs_cap

        // Set once at generic init — lets the non-generic procs below copy/size the `data` payload without needing T.
        data_type_info: ^runtime.Type_Info,
    }

    Pair_Table :: struct($T: typeid) {
        using base: Pair_Table_Base,
        data: []T, // pairs_cap — the only field that needs T
    }

    // Same-layout view of Pair_Table($T) with `data` reinterpreted as []byte — mirrors table.odin's Table_Raw, letting pair_table_base__terminate free `data`'s backing allocation without knowing T.
    @(private)
    Pair_Table_Raw :: struct {
        using base: Pair_Table_Base,
        data: []byte,
    }

    @(private)
    pair_table_base__is_valid :: proc(self: ^Pair_Table_Base) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if !tag_table__is_valid(&self.presence) do return false
        if self.targets == nil do return false
        if self.row_holder == nil do return false
        if self.next_pair == nil do return false
        if self.prev_pair == nil do return false
        if self.first_pair == nil do return false
        if self.next_pair_by_target == nil do return false
        if self.prev_pair_by_target == nil do return false
        if self.first_pair_by_target == nil do return false
        if self.free_rows == nil do return false
        if self.scratch == nil do return false
        if self.pairs_cap <= 0 do return false
        if self.data_type_info == nil do return false

        return true
    }

    pair_table__is_valid :: proc(self: ^Pair_Table($T)) -> bool {
        if self == nil do return false
        return pair_table_base__is_valid(&self.base)
    }

    @(private)
    pair_table_base__init :: proc(self: ^Pair_Table_Base, db: ^Database, holders_cap: int, pairs_cap: int, data_type_info: ^runtime.Type_Info, loc := #caller_location) -> Error {
        tag_table__init(&self.presence, db, holders_cap, loc = loc) or_return

        self.db = db
        self.pairs_cap = pairs_cap
        self.data_type_info = data_type_info

        entities_cap := db.overbase.id_factory.cap

        self.targets    = make([]entity_id,   pairs_cap,    db.allocator) or_return
        self.row_holder = make([]entity_id,   pairs_cap,    db.allocator) or_return
        self.next_pair  = make([]Pair_Row_Id, pairs_cap,    db.allocator) or_return
        self.prev_pair  = make([]Pair_Row_Id, pairs_cap,    db.allocator) or_return
        self.first_pair = make([]Pair_Row_Id, entities_cap, db.allocator) or_return

        self.next_pair_by_target  = make([]Pair_Row_Id, pairs_cap,    db.allocator) or_return
        self.prev_pair_by_target  = make([]Pair_Row_Id, pairs_cap,    db.allocator) or_return
        self.first_pair_by_target = make([]Pair_Row_Id, entities_cap, db.allocator) or_return

        self.free_rows = make([]Pair_Row_Id, pairs_cap, db.allocator) or_return
        self.scratch   = make([]entity_id,   pairs_cap, db.allocator) or_return

        // database__attach_pair_table grows the registry on demand rather than hard-capping it, so failure here is only a rare OOM case; no special rollback needed.
        self.id = database__attach_pair_table(db, self) or_return

        self.state = Object_State.Normal

        pair_table_base__clear(self) or_return

        return nil
    }

    // holders_cap bounds distinct holders with >= 1 pair (sizes `presence`); pairs_cap bounds total concurrent (holder, target) rows.
    pair_table__init :: proc(self: ^Pair_Table($T), db: ^Database, holders_cap: int, pairs_cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(holders_cap > 0, loc = loc)
            assert(pairs_cap > 0, loc = loc)
        }

        pair_table_base__init(&self.base, db, holders_cap, pairs_cap, type_info_of(typeid_of(T)), loc) or_return

        self.data = make([]T, pairs_cap, db.allocator) or_return

        return nil
    }

    // Frees everything, including the generic `data` payload, via the Pair_Table_Raw same-address cast, without needing T.
    @(private)
    pair_table_base__terminate :: proc(self: ^Pair_Table_Base) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        database__detach_pair_table(self.db, self)

        if self.presence.state == Object_State.Normal do tag_table__terminate(&self.presence) or_return

        delete(self.targets, self.db.allocator) or_return
        delete(self.row_holder, self.db.allocator) or_return
        delete(self.next_pair, self.db.allocator) or_return
        delete(self.prev_pair, self.db.allocator) or_return
        delete(self.first_pair, self.db.allocator) or_return
        delete(self.next_pair_by_target, self.db.allocator) or_return
        delete(self.prev_pair_by_target, self.db.allocator) or_return
        delete(self.first_pair_by_target, self.db.allocator) or_return
        delete(self.free_rows, self.db.allocator) or_return
        delete(self.scratch, self.db.allocator) or_return

        raw := cast(^Pair_Table_Raw) self
        if raw.data != nil do delete(raw.data, self.db.allocator) or_return
        raw.data = nil

        self.targets = nil
        self.row_holder = nil
        self.next_pair = nil
        self.prev_pair = nil
        self.first_pair = nil
        self.next_pair_by_target = nil
        self.prev_pair_by_target = nil
        self.first_pair_by_target = nil
        self.free_rows = nil
        self.scratch = nil
        self.pairs_count = 0
        self.pairs_cap = 0
        self.free_count = 0
        self.data_type_info = nil

        self.db = nil
        // Not_Initialized (not Terminated), so the same struct can be re-init'd.
        self.state = Object_State.Not_Initialized

        return nil
    }

    pair_table__terminate :: proc(self: ^Pair_Table($T)) -> Error {
        return pair_table_base__terminate(&self.base)
    }

    // Resets the row/link/freelist bookkeeping only — does NOT touch `presence`, so snapshot deserialize can reset just the rows without wiping the presence tags it just loaded.
    @(private)
    pair_table_base__reset_rows :: proc(self: ^Pair_Table_Base) {
        for i := 0; i < len(self.first_pair); i += 1 {
            self.first_pair[i] = Pair_Row_Id(DELETED_INDEX)
            self.first_pair_by_target[i] = Pair_Row_Id(DELETED_INDEX)
        }
        for i := 0; i < self.pairs_cap; i += 1 {
            self.row_holder[i].ix = DELETED_INDEX
            self.next_pair[i] = Pair_Row_Id(DELETED_INDEX)
            self.prev_pair[i] = Pair_Row_Id(DELETED_INDEX)
            self.next_pair_by_target[i] = Pair_Row_Id(DELETED_INDEX)
            self.prev_pair_by_target[i] = Pair_Row_Id(DELETED_INDEX)
            self.free_rows[i] = Pair_Row_Id(i)
        }
        self.free_count = self.pairs_cap
        self.pairs_count = 0
    }

    @(private)
    pair_table_base__clear :: proc(self: ^Pair_Table_Base) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        tag_table__clear(&self.presence) or_return
        pair_table_base__reset_rows(self)

        return nil
    }

    @(private)
    pair_table_base__memory_usage :: proc(self: ^Pair_Table_Base) -> int {
        total := tag_table__memory_usage(&self.presence)

        if self.targets != nil               do total += size_of(entity_id) * self.pairs_cap
        if self.row_holder != nil            do total += size_of(entity_id) * self.pairs_cap
        if self.next_pair != nil             do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.prev_pair != nil             do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.next_pair_by_target != nil   do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.prev_pair_by_target != nil   do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.free_rows != nil             do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.scratch != nil               do total += size_of(entity_id) * self.pairs_cap
        if self.first_pair != nil            do total += size_of(Pair_Row_Id) * len(self.first_pair)
        if self.first_pair_by_target != nil  do total += size_of(Pair_Row_Id) * len(self.first_pair_by_target)
        if self.data_type_info != nil        do total += self.data_type_info.size * self.pairs_cap

        return total
    }

    // size_of(self^) captures Pair_Table($T)'s own fixed footprint; everything heap-allocated comes from the base call.
    pair_table__memory_usage :: proc(self: ^Pair_Table($T)) -> int {
        return size_of(self^) + pair_table_base__memory_usage(&self.base)
    }

    pair_table__len :: #force_inline proc "contextless" (self: ^Pair_Table($T)) -> int {
        return self.pairs_count
    }

    pair_table__cap :: #force_inline proc "contextless" (self: ^Pair_Table($T)) -> int {
        return self.pairs_cap
    }

    // Unlinks row from both the holder-side and target-side doubly-linked lists (O(1) each) and returns it to the freelist; does NOT touch `presence`.
    @(private)
    pair_table_base__unlink_row :: #force_inline proc(self: ^Pair_Table_Base, row: Pair_Row_Id) #no_bounds_check {
        holder := self.row_holder[row]
        target := self.targets[row]

        // Fires before any unlink below — data_ptr (if any) is still readable.
        data_ptr: rawptr
        if self.data_type_info.size > 0 {
            raw := cast(^Pair_Table_Raw) self
            data_ptr = rawptr(uintptr(raw_data(raw.data)) + uintptr(row) * uintptr(self.data_type_info.size))
        }
        database__notify_observers(self.db, .Pair_Removed, holder, pair_table_id = self.id, related = target, data = data_ptr)

        pv, nx := self.prev_pair[row], self.next_pair[row]
        if pv != Pair_Row_Id(DELETED_INDEX) do self.next_pair[pv] = nx
        else do self.first_pair[holder.ix] = nx
        if nx != Pair_Row_Id(DELETED_INDEX) do self.prev_pair[nx] = pv

        tpv, tnx := self.prev_pair_by_target[row], self.next_pair_by_target[row]
        if tpv != Pair_Row_Id(DELETED_INDEX) do self.next_pair_by_target[tpv] = tnx
        else do self.first_pair_by_target[target.ix] = tnx
        if tnx != Pair_Row_Id(DELETED_INDEX) do self.prev_pair_by_target[tnx] = tpv

        self.row_holder[row].ix = DELETED_INDEX
        self.next_pair[row] = Pair_Row_Id(DELETED_INDEX)
        self.prev_pair[row] = Pair_Row_Id(DELETED_INDEX)
        self.next_pair_by_target[row] = Pair_Row_Id(DELETED_INDEX)
        self.prev_pair_by_target[row] = Pair_Row_Id(DELETED_INDEX)

        self.free_rows[self.free_count] = row
        self.free_count += 1
        self.pairs_count -= 1
    }

    // Adds (holder -> target) with payload `data` (nil or size-0 for a tag-only Pair_Table); adding an already-existing exact (holder, target) pair is a no-op that returns the existing row.
    //
    // Type-erased: this is what Command_Buffer replay and the generic pair_table__add both funnel through.
    @(private)
    pair_table_base__add_raw :: proc(self: ^Pair_Table_Base, holder, target: entity_id, data: rawptr, loc := #caller_location) -> (row: Pair_Row_Id, err: Error) #no_bounds_check {
        row = Pair_Row_Id(DELETED_INDEX)

        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
        }

        database__is_entity_correct(self.db, holder) or_return
        database__is_entity_correct(self.db, target) or_return

        // Dedupe: O(#pairs for holder), same complexity class as remove/targets_of.
        r := self.first_pair[holder.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            if self.targets[r] == target do return r, nil
            r = self.next_pair[r]
        }

        is_new_holder := !tag_table__has_tag(&self.presence, holder)

        if self.free_count <= 0 do return Pair_Row_Id(DELETED_INDEX), oc.Core_Error.Container_Is_Full
        if is_new_holder && tag_table__len(&self.presence) >= tag_table__cap(&self.presence) {
            return Pair_Row_Id(DELETED_INDEX), oc.Core_Error.Container_Is_Full
        }

        if is_new_holder {
            tag_table__add_tag(&self.presence, holder, loc) or_return
        }

        self.free_count -= 1
        new_row := self.free_rows[self.free_count]

        self.targets[new_row] = target
        self.row_holder[new_row] = holder

        self.next_pair[new_row] = self.first_pair[holder.ix]
        self.prev_pair[new_row] = Pair_Row_Id(DELETED_INDEX)
        if self.first_pair[holder.ix] != Pair_Row_Id(DELETED_INDEX) do self.prev_pair[self.first_pair[holder.ix]] = new_row
        self.first_pair[holder.ix] = new_row

        self.next_pair_by_target[new_row] = self.first_pair_by_target[target.ix]
        self.prev_pair_by_target[new_row] = Pair_Row_Id(DELETED_INDEX)
        if self.first_pair_by_target[target.ix] != Pair_Row_Id(DELETED_INDEX) do self.prev_pair_by_target[self.first_pair_by_target[target.ix]] = new_row
        self.first_pair_by_target[target.ix] = new_row

        self.pairs_count += 1

        data_ptr: rawptr
        if data != nil && self.data_type_info.size > 0 {
            raw := cast(^Pair_Table_Raw) self
            dst := rawptr(uintptr(raw_data(raw.data)) + uintptr(new_row) * uintptr(self.data_type_info.size))
            mem.copy(dst, data, self.data_type_info.size)
            data_ptr = dst
        }

        database__notify_observers(self.db, .Pair_Added, holder, pair_table_id = self.id, related = target, data = data_ptr)

        return new_row, nil
    }

    pair_table__add :: proc(self: ^Pair_Table($T), holder: entity_id, target: entity_id, data: T, loc := #caller_location) -> (row: Pair_Row_Id, err: Error) {
        value := data
        return pair_table_base__add_raw(&self.base, holder, target, &value, loc)
    }

    // Removes the first row matching (holder, target), O(#pairs for holder); if this was holder's last pair, removes its presence tag too.
    @(private)
    pair_table_base__remove :: proc(self: ^Pair_Table_Base, holder: entity_id, target: entity_id, loc := #caller_location) -> Error #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
        }

        database__is_entity_correct(self.db, holder) or_return

        r := self.first_pair[holder.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            if self.targets[r] == target do break
            r = self.next_pair[r]
        }

        if r == Pair_Row_Id(DELETED_INDEX) do return oc.Core_Error.Not_Found

        pair_table_base__unlink_row(self, r)

        if self.first_pair[holder.ix] == Pair_Row_Id(DELETED_INDEX) {
            tag_table__remove_tag(&self.presence, holder, loc) or_return
        }

        return nil
    }

    pair_table__remove :: proc(self: ^Pair_Table($T), holder: entity_id, target: entity_id, loc := #caller_location) -> Error {
        return pair_table_base__remove(&self.base, holder, target, loc)
    }

    // Removes ALL of holder's pairs, a no-op (not an error) if holder has none.
    @(private)
    pair_table_base__remove_all :: proc(self: ^Pair_Table_Base, holder: entity_id, loc := #caller_location) -> Error #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
        }

        database__is_entity_correct(self.db, holder) or_return

        r := self.first_pair[holder.ix]
        if r == Pair_Row_Id(DELETED_INDEX) do return nil

        for r != Pair_Row_Id(DELETED_INDEX) {
            next := self.next_pair[r]
            pair_table_base__unlink_row(self, r)
            r = next
        }

        terr := tag_table__remove_tag(&self.presence, holder, loc)
        if terr != nil && terr != oc.Core_Error.Not_Found do return terr
        return nil
    }

    pair_table__remove_all :: proc(self: ^Pair_Table($T), holder: entity_id, loc := #caller_location) -> Error {
        return pair_table_base__remove_all(&self.base, holder, loc)
    }

    // Removes every row where `target` is the target, called once per attached Pair_Table when `target` is destroyed, O(#pairs for that target) via first_pair_by_target/next_pair_by_target, not O(pairs_cap).
    @(private)
    pair_table_base__remove_target :: proc(self: ^Pair_Table_Base, target: entity_id) -> Error #no_bounds_check {
        r := self.first_pair_by_target[target.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            next := self.next_pair_by_target[r]
            holder := self.row_holder[r]

            pair_table_base__unlink_row(self, r)

            if self.first_pair[holder.ix] == Pair_Row_Id(DELETED_INDEX) {
                terr := tag_table__remove_tag(&self.presence, holder)
                if terr != nil && terr != oc.Core_Error.Not_Found do return terr
            }

            r = next
        }

        return nil
    }

    @(private)
    pair_table_base__has_pair :: proc(self: ^Pair_Table_Base, holder: entity_id, target: entity_id) -> bool #no_bounds_check {
        if database__is_entity_correct(self.db, holder) != nil do return false

        r := self.first_pair[holder.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            if self.targets[r] == target do return true
            r = self.next_pair[r]
        }

        return false
    }

    pair_table__has_pair :: proc(self: ^Pair_Table($T), holder: entity_id, target: entity_id) -> bool {
        return pair_table_base__has_pair(&self.base, holder, target)
    }

    // == tag_table__has_tag(&self.presence, holder) — does holder have >= 1 pair?
    pair_table__has_any :: #force_inline proc(self: ^Pair_Table($T), holder: entity_id) -> bool {
        return tag_table__has_tag(&self.presence, holder)
    }

    @(private)
    pair_table_base__first_row :: #force_inline proc "contextless" (self: ^Pair_Table_Base, holder: entity_id) -> (row: Pair_Row_Id, ok: bool) #no_bounds_check {
        r := self.first_pair[holder.ix]
        if r == Pair_Row_Id(DELETED_INDEX) do return Pair_Row_Id(DELETED_INDEX), false
        return r, true
    }

    // O(1): the most-recently-added target among holder's pairs — arbitrary among several, NOT a stable/deterministic choice.
    pair_table__first_target :: proc(self: ^Pair_Table($T), holder: entity_id) -> (target: entity_id, ok: bool) #no_bounds_check {
        target.ix = DELETED_INDEX
        if database__is_entity_correct(self.db, holder) != nil do return target, false

        r, found := pair_table_base__first_row(&self.base, holder)
        if !found do return target, false

        return self.targets[r], true
    }

    // O(1) counterpart to first_target: a pointer to that same row's payload.
    pair_table__first_data :: proc(self: ^Pair_Table($T), holder: entity_id) -> (data: ^T, ok: bool) #no_bounds_check {
        if database__is_entity_correct(self.db, holder) != nil do return nil, false

        r, found := pair_table_base__first_row(&self.base, holder)
        if !found do return nil, false

        return &self.data[r], true
    }

    // holder's targets as a slice of the internal scratch buffer, valid only until the next targets_of call or any structural change.
    @(private)
    pair_table_base__targets_of :: proc(self: ^Pair_Table_Base, holder: entity_id) -> (res: []entity_id, err: Error) #no_bounds_check {
        database__is_entity_correct(self.db, holder) or_return

        n := 0
        r := self.first_pair[holder.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            when VALIDATIONS do assert(n < len(self.scratch), "pair links corrupted — more pairs than cap")
            self.scratch[n] = self.targets[r]
            n += 1
            r = self.next_pair[r]
        }

        return self.scratch[:n], nil
    }

    pair_table__targets_of :: proc(self: ^Pair_Table($T), holder: entity_id) -> (res: []entity_id, err: Error) {
        return pair_table_base__targets_of(&self.base, holder)
    }

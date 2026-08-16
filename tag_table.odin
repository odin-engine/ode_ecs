/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:math"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

// Tag_Table

    Tag_Table :: struct {
        using shared: Shared_Table,

        rows: []entity_id,                          // rid_to_eid
        eid_to_rid: oc_maps.Rh_Map32,               // eid.ix -> row id in rows (8-byte items, see Compact_Table)

        cap: int,

        // Deferred tail swap (db.tail_swap_paused) hole bookkeeping.
        // A hole is a row with rows[rid].ix == DELETED_INDEX inside [0, len).
        holes_count: int,
        first_hole_rid: int, // scan-start hint for pack; max(int) when no holes

        subscribers: oc.Dense_Arr(^View),
        subscribers_excluding: oc.Dense_Arr(^View), // views that EXCLUDE this table (see view__init excludes)
        subscribers_any_of: oc.Dense_Arr(^View), // views that any_of this table (see view__init any_of)

        // sync_channels_cap sizes sync_watchers, lazily allocated on first sync_register.
        // Structural-only (add_tag/remove_tag) — a Tag_Table carries no component data to diff.
        sync_channels_cap: int,
        sync_watchers: oc.Dense_Arr(^Sync_Channel),
    }

    tag_table__is_valid :: proc(self: ^Tag_Table) -> bool {
        if self == nil do return false
        if !shared_table__is_valid_internal(&self.shared) do return false
        if self.rows == nil do return false
        if !oc_maps.rh_map32__is_valid(&self.eid_to_rid) do return false
        if self.cap <= 0 do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_excluding) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_any_of) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.sync_watchers) do return false

        return true
    }

    tag_table__init :: proc(self: ^Tag_Table, db: ^Database, cap: int, sync_channels_cap: int = SYNC_CHANNELS_CAP, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(cap > 0, loc = loc)
            assert(cap <= db.overbase.id_factory.cap, loc = loc) // cannot be larger than entities_cap
            assert(db.overbase.id_factory.cap < int(max(u32)), loc = loc) // eid.ix keys must fit the u32 rid map
        }

        shared_table__init(&self.shared, Table_Type.Tag_Table, db)
        self.cap = cap
        self.sync_channels_cap = sync_channels_cap
        // subscriber lists and sync_watchers are allocated lazily, on first attach.

        self.rows = make([]entity_id, self.cap, db.allocator) or_return
        // load factor 0.5 and make it power of two
        oc_maps.rh_map32__init(&self.eid_to_rid, math.next_power_of_two(self.cap * 2), db.allocator) or_return

        // database__attach_table is capacity-limited and must not leak the allocations above
        // on failure. Can't reuse tag_table__terminate here — it requires state == Normal.
        id, aerr := database__attach_table(db, self)
        if aerr != nil {
            delete(self.rows, db.allocator)
            oc_maps.rh_map32__terminate(&self.eid_to_rid, db.allocator)
            if self.sync_watchers.items != nil do oc.dense_arr__terminate(&self.sync_watchers, db.allocator)
            if self.subscribers_any_of.items != nil do oc.dense_arr__terminate(&self.subscribers_any_of, db.allocator)
            if self.subscribers_excluding.items != nil do oc.dense_arr__terminate(&self.subscribers_excluding, db.allocator)
            if self.subscribers.items != nil do oc.dense_arr__terminate(&self.subscribers, db.allocator)
            return aerr
        }
        self.id = id
        self.state = Object_State.Normal

        tag_table__clear(self) or_return

        return nil
    }

    tag_table__terminate :: proc(self: ^Tag_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        for view in self.subscribers.items do view.state = Object_State.Invalid
        for view in self.subscribers_excluding.items do view.state = Object_State.Invalid
        for view in self.subscribers_any_of.items do view.state = Object_State.Invalid
        for ch in self.sync_watchers.items do sync_channel__on_table_terminated(ch, self.id)

        // Clear this table's bit from all entities, see table_raw__terminate
        for &bits in self.db.eid_to_bits do uni_bits__remove(&bits, self.id)

        if self.sync_watchers.items != nil do oc.dense_arr__terminate(&self.sync_watchers, self.db.allocator) or_return
        if self.subscribers_any_of.items != nil do oc.dense_arr__terminate(&self.subscribers_any_of, self.db.allocator) or_return
        if self.subscribers_excluding.items != nil do oc.dense_arr__terminate(&self.subscribers_excluding, self.db.allocator) or_return
        if self.subscribers.items != nil do oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return
        oc_maps.rh_map32__terminate(&self.eid_to_rid, self.db.allocator) or_return

        delete(self.rows, self.db.allocator) or_return

        database__detach_table(self.db, self)

        shared_table__clear_state(&self.shared)

        return nil
    }

    tag_table__memory_usage :: proc (self: ^Tag_Table) -> int {
        total := size_of(self^)

        if self.rows != nil {
            // cap, not len(self.rows) — len tracks the live row span, but all cap slots are allocated
            total += size_of(entity_id) * self.cap
        }

        total += oc_maps.rh_map32__memory_usage(&self.eid_to_rid)
        total += oc.dense_arr__memory_usage(&self.sync_watchers)

        return total
    }

    // Row-slot count, including holes left while packing is paused (same semantics as the
    // other tables) — `for rid in 0..<len` with an is_not_set skip visits every live tag.
    tag_table__len :: #force_inline proc "contextless" (self: ^Tag_Table) -> int {
        return len(self.rows)
    }

    tag_table__cap :: #force_inline proc "contextless" (self: ^Tag_Table) -> int {
        return self.cap
    }

    // Tagged entities as one contiguous slice — `rows` is already the full row-slot span (see
    // tag_table__len's holes-while-paused note). Returned by value from a call — see table__slice's doc comment (table.odin) for why that matters for codegen.
    @(require_results)
    tag_table__slice :: #force_inline proc "contextless" (self: ^Tag_Table) -> []entity_id {
        return self.rows
    }

    tag_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Tag_Table, #any_int row_number: int) -> entity_id {
        return self.rows[row_number]
    }

    tag_table__add_tag :: proc(self: ^Tag_Table, eid: entity_id, loc:= #caller_location) -> (err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(eid.ix >= 0, loc = loc)
        }

        database__is_entity_correct(self.db, eid) or_return

        raw := (^runtime.Raw_Slice)(&self.rows)

        // One probe serves both the existence check and insert — get_or_insert reuses the
        // located slot instead of get()+add() re-walking the chain. Capacity only gates the
        // actual insert, so re-adding an existing tag on a full table stays a no-op.
        _, found, gerr := oc_maps.rh_map32__get_or_insert(&self.eid_to_rid, u32(eid.ix), u32(raw.len), raw.len < self.cap)

        if found do return nil // already added

        if raw.len >= self.cap do return oc.Core_Error.Container_Is_Full
        if gerr != nil do return gerr

        #no_bounds_check {
            self.rows[raw.len] = eid
        }

        // Update eid_to_bits in db
        database__add_component(self.db, eid, self.id)

        tag_table__notify_sync_add(self, eid)
        database__notify_observers(self.db, .Tag_Added, eid, table_id = self.id)

        raw.len += 1

        // Notify subscribed views
        for view in self.subscribers.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        // Views any_of-ing this table may have gained their (first) matching table for
        // this entity (no-op if already a member via another any_of table).
        for view in self.subscribers_any_of.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        // Views excluding this table lose the entity (no-op if it wasn't a member)
        for view in self.subscribers_excluding.items {
            if !view.suspended do view__remove_record(view, eid)
        }

        return nil
    }

    tag_table__remove_tag :: proc(self: ^Tag_Table, target_eid: entity_id, loc:= #caller_location) -> (err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(target_eid.ix >= 0, loc = loc)
        }

        database__is_entity_correct(self.db, target_eid) or_return

        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found

        // One lookup serves both the existence check and removal below — remove_at reuses the slot index instead of re-probing the key
        target_rid_u, target_slot := oc_maps.rh_map32__get_with_index(&self.eid_to_rid, u32(target_eid.ix))

        if target_slot == oc.DELETED_INDEX do return oc.Core_Error.Not_Found

        target_rid := int(target_rid_u)

        // Fires before any mutation below (tags carry no data, so `data` stays nil).
        database__notify_observers(self.db, .Tag_Removed, target_eid, table_id = self.id)

        // Deferred tail swap: clear the tag in place, leaving a hole.
        // Nothing moves, so nothing needs to stay stable while iterating.
        if shared_table__is_packing_paused(cast(^Shared_Table) self) {
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)

            self.rows[target_rid].ix = DELETED_INDEX

            if target_rid == raw.len - 1 {
                raw.len -= 1
                // absorb trailing holes so they never need packing
                for raw.len > 0 && is_not_set(self.rows[raw.len - 1]) {
                    raw.len -= 1
                    self.holes_count -= 1
                }
            } else {
                self.holes_count += 1
                if target_rid < self.first_hole_rid do self.first_hole_rid = target_rid
            }

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
                else do view__missed_update_for_member(view, target_eid)
            }

            // Update eid_to_bits in db
            database__remove_component(self.db, target_eid, self.id)
            tag_table__notify_sync_remove(self, target_eid)
            tag_table__notify_excluding_views(self, target_eid)
            tag_table__notify_any_of_views(self, target_eid)

            return nil
        }

        tail_rid := raw.len - 1

        if target_rid == tail_rid {
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)

            self.rows[tail_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
                else do view__missed_update_for_member(view, target_eid)
            }

        } else {
            tail_eid := self.rows[tail_rid]
            when VALIDATIONS do assert(!is_not_set(tail_eid))

            // Update tail indexes (value-only update — slots don't move, so
            // target_slot stays valid for the remove_at)
            oc_maps.rh_map32__update(&self.eid_to_rid, u32(tail_eid.ix), target_rid_u)
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)

            self.rows[target_rid] = tail_eid
            self.rows[tail_rid].ix = DELETED_INDEX

            // Notify subscribed views
            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    // tag columns carry no component data, but this also feeds the dense safety
                    // net — the moved tag now occupies the removed row's id.
                    view__update_component_rid(view, self, tail_eid, target_rid)
                } else {
                    view__missed_update_for_member(view, target_eid)
                    view__missed_update_for_member(view, tail_eid)
                }
            }
        }

        raw.len -= 1

        // Update eid_to_bits in db
        database__remove_component(self.db, target_eid, self.id)

        tag_table__notify_sync_remove(self, target_eid)
        tag_table__notify_excluding_views(self, target_eid)
        tag_table__notify_any_of_views(self, target_eid)

        return nil
    }

    tag_table__remove_component :: tag_table__remove_tag

    @(require_results)
    tag_table__has_tag :: proc (self: ^Tag_Table, eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix)) != oc_maps.RH_MAP32_DELETED
    }

    // Soft toggle: excludes the component from View matching without removing it — see
    // database.odin's "Component enable/disable" section.
    tag_table__disable_component :: proc(self: ^Tag_Table, eid: entity_id) -> Error {
        return database__disable_component(self.db, eid, self.id)
    }

    tag_table__enable_component :: proc(self: ^Tag_Table, eid: entity_id) -> Error {
        return database__enable_component(self.db, eid, self.id)
    }

    @(require_results)
    tag_table__is_component_disabled :: proc(self: ^Tag_Table, eid: entity_id) -> bool {
        return database__is_component_disabled(self.db, eid, self.id)
    }

    // Compact holes left by removals made while tail swap was paused
    // (see database__pause_packing). Callable mid-pause too.
    tag_table__pack :: proc(self: ^Tag_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.holes_count <= 0 {
            self.first_hole_rid = max(int)
            return nil
        }

        raw := (^runtime.Raw_Slice)(&self.rows)

        front := self.first_hole_rid
        back := raw.len - 1

        for self.holes_count > 0 {
            // shrink span past trailing holes
            for back >= 0 && is_not_set(self.rows[back]) {
                back -= 1
                self.holes_count -= 1
            }
            if self.holes_count <= 0 do break

            // next hole from the front; guaranteed to exist below back
            for !is_not_set(self.rows[front]) do front += 1

            // move the last live row's tag into the hole
            moved_eid := self.rows[back]
            self.rows[front] = moved_eid
            self.rows[back].ix = DELETED_INDEX

            oc_maps.rh_map32__update(&self.eid_to_rid, u32(moved_eid.ix), u32(front))

            // keep subscriber rids current, same as the other tables' pack (tag columns carry
            // no data, but see the remove_tag note on the dense safety net)
            for view in self.subscribers.items {
                if !view.suspended do view__update_component_rid(view, self, moved_eid, front)
                else do view__missed_update_for_member(view, moved_eid)
            }

            back -= 1
            front += 1
            self.holes_count -= 1
        }

        raw.len = back + 1
        self.first_hole_rid = max(int)

        return nil
    }

    // Pause tail swapping for this table only, independent of the
    // database-wide pause_packing.
    tag_table__pause_packing :: proc(self: ^Tag_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = true
        return nil
    }

    // Resume tail swapping for this table and pack the holes it accumulated.
    tag_table__resume_packing :: proc(self: ^Tag_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = false
        return tag_table__pack(self)
    }

    tag_table__clear :: proc (self: ^Tag_Table) -> Error {
        if !tag_table__is_valid(self) do return API_Error.Object_Invalid

        if self.rows != nil {
            for i := 0; i < len(self.rows); i+=1 do self.rows[i].ix = DELETED_INDEX
        }

        (^runtime.Raw_Slice)(&self.rows).len = 0

        oc_maps.rh_map32__clear(&self.eid_to_rid)

        self.holes_count = 0
        self.first_hole_rid = max(int)

        return nil
    }

    @(private)
    tag_table__attach_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        if self.subscribers.items == nil do oc.dense_arr__init(&self.subscribers, SUBSCRIBERS_CAP, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers, view, self.db.allocator)
        return err
    }

    @(private)
    tag_table__detach_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        err := oc.dense_arr__remove_by_value(&self.subscribers, view)
        return err
    }

    @(private)
    tag_table__attach_exclude_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        if self.subscribers_excluding.items == nil do oc.dense_arr__init(&self.subscribers_excluding, SUBSCRIBERS_CAP, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers_excluding, view, self.db.allocator)
        return err
    }

    @(private)
    tag_table__detach_exclude_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_excluding, view)
    }

    @(private)
    tag_table__attach_any_of_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        if self.subscribers_any_of.items == nil do oc.dense_arr__init(&self.subscribers_any_of, SUBSCRIBERS_CAP, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers_any_of, view, self.db.allocator)
        return err
    }

    @(private)
    tag_table__detach_any_of_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_any_of, view)
    }

    @(private)
    tag_table__attach_sync_channel :: proc(self: ^Tag_Table, ch: ^Sync_Channel) -> Error {
        when !SYNC_ENABLED do return API_Error.Sync_Feature_Disabled

        if self.sync_watchers.items == nil do oc.dense_arr__init(&self.sync_watchers, self.sync_channels_cap, self.db.allocator) or_return
        _, err := oc.dense_arr__add(&self.sync_watchers, ch)
        return err
    }

    @(private)
    tag_table__detach_sync_channel :: proc(self: ^Tag_Table, ch: ^Sync_Channel) -> Error {
        when !SYNC_ENABLED do return API_Error.Sync_Feature_Disabled

        return oc.dense_arr__remove_by_value(&self.sync_watchers, ch)
    }

    @(private)
    tag_table__notify_sync_add :: #force_inline proc(self: ^Tag_Table, eid: entity_id) {
        when SYNC_ENABLED {
            for ch in self.sync_watchers.items {
                sync_channel__notify_structural(ch, self.id, eid, true)
            }
        }
    }

    @(private)
    tag_table__notify_sync_remove :: #force_inline proc(self: ^Tag_Table, eid: entity_id) {
        when SYNC_ENABLED {
            for ch in self.sync_watchers.items {
                sync_channel__notify_structural(ch, self.id, eid, false)
            }
        }
    }

    @(private)
    tag_table__notify_excluding_views :: #force_inline proc(self: ^Tag_Table, eid: entity_id) {
        if self.db.destroying_eid_ix == eid.ix do return
        for view in self.subscribers_excluding.items {
            if !view.suspended && view__components_match(view, eid) {
                when VALIDATIONS {
                    // see table_base__notify_excluding_views
                    aerr := view__add_record(view, eid)
                    assert(aerr != API_Error.Cannot_Add_Record_To_View_Container_Is_Full, "excluding view is full — entity silently dropped, raise the view's included tables' caps")
                } else {
                    view__add_record(view, eid)
                }
            }
        }
    }

    @(private)
    tag_table__notify_any_of_views :: #force_inline proc(self: ^Tag_Table, eid: entity_id) {
        for view in self.subscribers_any_of.items {
            if !view.suspended && !view__components_match(view, eid) do view__remove_record(view, eid)
        }
    }
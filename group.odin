/*
    2026 (c) Oleh, https://github.com/zm69

    Owned groups: enforced dense alignment (EnTT-style "full-owning groups").

    A Group owns a set of Tables (only Table type — not Compact/Tiny/Tag). It
    maintains this invariant: the entities that have ALL owned components occupy
    the contiguous prefix [0, group.len) of every owned table, at the SAME row
    index in each. Where a View *detects* alignment, a Group *enforces* it by
    swapping table rows on add/remove — so group_dense_slice is always valid:
    no pointer records, no rescans, iteration is a raw SoA sweep at table speed.

    Cost model: add_component that completes a group membership (and
    remove_component/destroy_entity that breaks one) pays O(owned tables) row
    swaps. A table can be owned by at most one group.

    Deferred tail swap (database__pause_tail_swap): group maintenance would move
    rows, which pause forbids, so membership changes while paused only mark the
    group dirty; database__resume_tail_swap rebuilds dirty groups after packing.
    While dirty, group_dense_slice returns nil.
*/
package ode_ecs

// Core
    import "core:slice"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Group

    Group :: struct {
        state: Object_State,
        db: ^Database,

        tables: []^Table_Raw, // owned tables
        bits: Uni_Bits,       // ids of owned tables

        // number of entities in the group == length of the aligned prefix
        // shared by every owned table
        len: int,

        // membership changed while tail swap was paused; prefix can no longer be
        // trusted until database__resume_tail_swap (or group__rebuild) fixes it
        dirty: bool,
    }

    // Is group valid and ready to use (initialized and everything is ok)
    group__is_valid :: proc(self: ^Group) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if self.tables == nil do return false
        if len(self.tables) <= 0 do return false

        return true
    }

    group__init :: proc(
        self: ^Group,
        db: ^Database,
        owned: []^Shared_Table,
        loc := #caller_location,
    ) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
        }

        if owned == nil || len(owned) <= 0 do return API_Error.Tables_Array_Should_Not_Be_Empty

        // Make sure we do not have repeating tables.
        // Sort a copy — the caller's slice must not be mutated.
        sorted_owned := slice.clone(owned, db.allocator) or_return
        defer delete(sorted_owned, db.allocator)
        slice.sort(sorted_owned)
        uniq_tables := slice.unique(sorted_owned)

        for table in uniq_tables {
            when VALIDATIONS {
                assert(shared_table__is_valid(table), loc = loc)
                assert(table.db == db, loc = loc)
            }
            if table.type != Table_Type.Table do return API_Error.Only_Table_Can_Be_Owned_By_Group
            if (cast(^Table_Raw) table).owner != nil do return API_Error.Table_Already_Owned_By_Group
        }

        // A re-init'd struct (issue #8) may carry state from its previous life.
        uni_bits__clear(&self.bits)
        self.len = 0
        self.dirty = false

        self.db = db

        self.tables = make([]^Table_Raw, len(uniq_tables), db.allocator) or_return

        for table, index in uniq_tables {
            self.tables[index] = cast(^Table_Raw) table
            uni_bits__add(&self.bits, table.id)
        }

        database__attach_group(db, self) or_return

        // Claim ownership only after nothing can fail anymore.
        for table in self.tables do table.owner = self

        self.state = Object_State.Normal

        // Build the prefix from whatever data the tables already hold.
        group__rebuild(self) or_return

        return nil
    }

    group__terminate :: proc(self: ^Group) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

        // Release ownership. A table that was itself terminated already reset
        // its owner field (see table_raw__terminate).
        for table in self.tables {
            if table != nil && table.owner == self do table.owner = nil
        }

        database__detach_group(self.db, self)

        delete(self.tables, self.db.allocator) or_return
        self.tables = nil

        uni_bits__clear(&self.bits)
        self.len = 0
        self.dirty = false

        // Leave the group in Not_Initialized state (not Terminated) so the same
        // struct can be re-init'd without zeroing it first. See issue #8.
        self.state = Object_State.Not_Initialized
        return nil
    }

    // Number of entities in the group
    group__len :: #force_inline proc "contextless" (self: ^Group) -> int {
        return self.len
    }

    // Batch (dense) access: the owned `table`'s components of all group members, in
    // group order, as one contiguous slice — table.rows[:group_len]. Unlike
    // view_dense_slice this needs no alignment check: the group maintains it.
    //
    // Slices for different owned tables of one group share indexing: slice_a[i] and
    // slice_b[i] belong to the same entity (get it with get_entity(table, i)).
    //
    // Returns nil when `table` is not owned by this group, or membership changes
    // were deferred by a paused tail swap (group is dirty until resume).
    // The slice is invalidated by any structural change; do not hold on to it.
    group__dense_slice :: proc "contextless" (self: ^Group, table: ^Table($T)) -> []T {
        if self == nil || table == nil do return nil
        if self.state != Object_State.Normal do return nil
        if table.owner != self do return nil
        if self.dirty do return nil

        #no_bounds_check {
            return table.rows[:self.len]
        }
    }

    // Rebuild the group prefix from scratch — O(smallest owned table) matches, each
    // paying O(owned tables) swaps. Normally never needed (membership is maintained
    // incrementally); database__resume_tail_swap calls it for dirty groups. While
    // tail swap is paused rows must not move, so it only marks the group dirty.
    group__rebuild :: proc(self: ^Group) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.db.tail_swap_paused {
            self.dirty = true
            return nil
        }

        self.len = 0

        // iterate the smallest owned table, swap every full match into the prefix
        min_table := self.tables[0]
        for table in self.tables {
            if table_raw__len(table) < table_raw__len(min_table) do min_table = table
        }

        n := table_raw__len(min_table)
        for r := 0; r < n; r += 1 {
            eid := min_table.rid_to_eid[r] // current occupant (swaps below keep unvisited rows unvisited)
            if eid.ix == DELETED_INDEX do continue // hole (removal while tail swap was paused)

            if uni_bits__is_subset(&self.bits, &self.db.eid_to_bits[eid.ix]) {
                group__swap_in(self, eid)
            }
        }

        self.dirty = false

        return nil
    }

    // Group memory usage in bytes (the group stores no component data — only the
    // owned-tables list; the prefix lives inside the tables themselves)
    group__memory_usage :: proc (self: ^Group) -> int {
        total := size_of(self^)

        if self.tables != nil {
            total += size_of(self.tables[0]) * len(self.tables)
        }

        return total
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    // Move entity's rows into the prefix at position len (in every owned table),
    // then grow the prefix. The entity must have all owned components.
    group__swap_in :: proc(self: ^Group, eid: entity_id) {
        for table in self.tables {
            table_raw__swap_rows(table, int(table.eid_to_rid[eid.ix]), self.len)
        }
        self.len += 1
    }

    @(private)
    // Move entity's rows out of the prefix (to position len-1 in every owned
    // table), then shrink the prefix. The entity must currently be a member.
    group__swap_out :: proc(self: ^Group, eid: entity_id) {
        last := self.len - 1
        for table in self.tables {
            table_raw__swap_rows(table, int(table.eid_to_rid[eid.ix]), last)
        }
        self.len = last
    }

    @(private)
    // Called by an owned table after a component was added (bits already updated).
    // Idempotent: the add path also notifies on the already-exists branch.
    group__on_add :: proc(self: ^Group, eid: entity_id) {
        // full match? (needs every owned component)
        if !uni_bits__is_subset(&self.bits, &self.db.eid_to_bits[eid.ix]) do return

        if self.db.tail_swap_paused {
            // rows must not move while paused — rebuild on resume
            self.dirty = true
            return
        }

        // already inside the prefix? (members sit at the same rid < len in every
        // owned table, so checking one table suffices)
        #no_bounds_check {
            if int(self.tables[0].eid_to_rid[eid.ix]) < self.len do return
        }

        group__swap_in(self, eid)
    }

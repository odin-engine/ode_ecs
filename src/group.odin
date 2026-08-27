/*
    2026 (c) Oleh, https://github.com/zm69

    Owned groups: enforced dense alignment (EnTT-style "full-owning groups").

    A Group owns a set of Tables (only Table type — not Compact/Tiny/Tag). It
    maintains this invariant: the entities that have ALL owned components occupy
    the contiguous prefix [0, group.len) of every owned table, at the SAME row
    index in each. Where a View *detects* alignment, a Group *enforces* it by
    swapping table rows on add/remove — so slice is always valid:
    no rid records, no rescans, iteration is a raw SoA sweep at table speed.

    Cost model: add_component that completes a group membership (and
    remove_component/destroy_entity that breaks one) pays O(owned tables) row
    swaps. A table can be owned by at most one group.

    Deferred tail swap (database__pause_packing): group maintenance would move
    rows, which pause forbids, so membership changes while paused only mark the
    group dirty; database__resume_packing rebuilds dirty groups after packing.
    While dirty, slice returns nil.
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

        tables: []^Table_Raw,       // owned Table($T)s
        arch_tables: []^Arch_Table, // owned Arch_Tables, separate slice (not a tagged union) so
                                    // Table-only groups pay zero extra cost — loop below is just empty.
        bits: Uni_Bits,             // ids of owned tables (either kind)

        // number of entities in the group == length of the aligned prefix
        // shared by every owned table
        len: int,

        // membership changed while tail swap was paused; prefix can no longer be
        // trusted until database__resume_packing (or group__rebuild) fixes it
        dirty: bool,

        // Deferred tail swap for this group's owned tables only, independent of db.tail_swap_paused.
        pause_packing: bool,
    }

    group__is_valid :: proc(self: ^Group) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if len(self.tables) + len(self.arch_tables) <= 0 do return false

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

        // Make sure we do not have repeating tables — sort a copy, since the caller's slice must not be mutated.
        sorted_owned := slice.clone(owned, db.allocator) or_return
        defer delete(sorted_owned, db.allocator)
        slice.sort(sorted_owned)
        uniq_tables := slice.unique(sorted_owned)

        table_count, arch_count := 0, 0
        for table in uniq_tables {
            when VALIDATIONS {
                assert(shared_table__is_valid(table), loc = loc)
                assert(table.db == db, loc = loc)
            }
            #partial switch table.type {
                case Table_Type.Table:
                    if (cast(^Table_Raw) table).owner != nil do return API_Error.Table_Already_Owned_By_Group
                    table_count += 1
                case Table_Type.Arch_Table:
                    if (cast(^Arch_Table) table).owner != nil do return API_Error.Table_Already_Owned_By_Group
                    arch_count += 1
                case:
                    return API_Error.Only_Table_Can_Be_Owned_By_Group
            }
        }

        // A re-init'd struct (issue #8) may carry state from its previous life.
        uni_bits__clear(&self.bits)
        self.len = 0
        self.dirty = false
        self.pause_packing = false

        self.db = db

        self.tables = make([]^Table_Raw, table_count, db.allocator) or_return
        self.arch_tables = make([]^Arch_Table, arch_count, db.allocator) or_return

        ti, ai := 0, 0
        for table in uniq_tables {
            uni_bits__add(&self.bits, table.id)
            if table.type == Table_Type.Table {
                self.tables[ti] = cast(^Table_Raw) table
                ti += 1
            } else {
                self.arch_tables[ai] = cast(^Arch_Table) table
                ai += 1
            }
        }

        database__attach_group(db, self) or_return

        // Claim ownership only after nothing can fail anymore.
        for table in self.tables do table.owner = self
        for at in self.arch_tables do at.owner = self

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

        // Release ownership; a table that was itself terminated already reset its owner field.
        for table in self.tables {
            if table != nil && table.owner == self do table.owner = nil
        }
        for at in self.arch_tables {
            if at != nil && at.owner == self do at.owner = nil
        }

        database__detach_group(self.db, self)

        delete(self.tables, self.db.allocator) or_return
        delete(self.arch_tables, self.db.allocator) or_return
        self.tables = nil
        self.arch_tables = nil

        uni_bits__clear(&self.bits)
        self.len = 0
        self.dirty = false
        self.pause_packing = false

        // Leave the group in Not_Initialized state (not Terminated) so the same struct can be re-init'd without zeroing it first.
        self.state = Object_State.Not_Initialized
        return nil
    }

    // While dirty (membership deferred by a paused tail swap) the stored len is stale until resume_packing rebuilds it.
    group__len :: #force_inline proc "contextless" (self: ^Group) -> int {
        when VALIDATIONS {
            assert_contextless(!self.dirty, "group_len while the group is dirty (paused packing) — resume_packing first")
        }
        return self.len
    }

    // Batch (dense) access: the owned `table`'s components of all group members, as table.rows[:group_len] — no alignment check needed, unlike View's slice.
    group__slice :: proc "contextless" (self: ^Group, table: ^Table($T)) -> []T {
        if self == nil || table == nil do return nil
        if self.state != Object_State.Normal do return nil
        if table.owner != self do return nil
        if self.dirty do return nil

        #no_bounds_check {
            return table.rows[:self.len]
        }
    }

    // Same as group__slice, for an owned Arch_Table's column: columns are type-erased, so this derives the pointer via arch_table__column_index.
    group__slice_arch :: proc(self: ^Group, table: ^Arch_Table, $T: typeid) -> []T {
        if self == nil || table == nil do return nil
        if self.state != Object_State.Normal do return nil
        if table.owner != self do return nil
        if self.dirty do return nil

        col_idx := arch_table__column_index(table, typeid_of(T))
        if col_idx < 0 do return nil

        col := &table.columns[col_idx]
        return slice.from_ptr(cast(^T) raw_data(col.rows), self.len)
    }

    // Entity ids for the group's aligned prefix, in the same row order as group__slice/group__slice_arch.
    group__entities_slice :: proc "contextless" (self: ^Group) -> []entity_id {
        if self == nil do return nil
        if self.state != Object_State.Normal do return nil
        if self.dirty do return nil

        #no_bounds_check {
            if len(self.tables) > 0 do return self.tables[0].rid_to_eid[:self.len]
            if len(self.arch_tables) > 0 do return self.arch_tables[0].rid_to_eid[:self.len]
        }
        return nil
    }

    // Rebuild the group prefix from scratch — normally unneeded, since membership is maintained incrementally; resume_packing calls it for dirty groups.
    group__rebuild :: proc(self: ^Group) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if group__is_packing_paused(self) {
            self.dirty = true
            return nil
        }

        self.len = 0

        // Iterate the smallest owned table, swap every full match into the prefix (not a hot path).
        min_len := max(int)
        min_rid_to_eid: []entity_id
        for table in self.tables {
            l := table_raw__len(table)
            if l < min_len {
                min_len = l
                min_rid_to_eid = table.rid_to_eid[:l]
            }
        }
        for at in self.arch_tables {
            l := arch_table__len(at)
            if l < min_len {
                min_len = l
                min_rid_to_eid = at.rid_to_eid[:l]
            }
        }

        for eid in min_rid_to_eid { // current occupant (swaps below keep unvisited rows unvisited)
            if is_not_set(eid) do continue // hole (removal while tail swap was paused)

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

        total += size_of(^Table_Raw) * len(self.tables)
        total += size_of(^Arch_Table) * len(self.arch_tables)

        return total
    }

    // Pause tail swapping for every table this group owns, as one atomic unit, independent of database-wide pause_packing and other groups.
    group__pause_packing :: proc(self: ^Group) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = true
        return nil
    }

    // Resume tail swapping for this group: pack every owned table, then rebuild the group prefix if membership changed while paused.
    group__resume_packing :: proc(self: ^Group) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = false

        err: Error
        for table in self.tables {
            terr := table_raw__pack(table)
            if err == nil do err = terr
        }
        for at in self.arch_tables {
            terr := arch_table__pack(at)
            if err == nil do err = terr
        }

        gerr := group__rebuild(self)
        if err == nil do err = gerr

        return err
    }

    // Pack every table this group owns (compact holes left while paused); callable mid-pause too, like table-level pack.
    group__pack :: proc(self: ^Group) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        err: Error
        for table in self.tables {
            terr := table_raw__pack(table)
            if err == nil do err = terr
        }
        for at in self.arch_tables {
            terr := arch_table__pack(at)
            if err == nil do err = terr
        }
        return err
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    // Is packing (tail swap) currently deferred for this group's owned tables
    // — either by a database-wide pause or by this group's own pause_packing.
    group__is_packing_paused :: #force_inline proc "contextless" (self: ^Group) -> bool {
        return self.db.tail_swap_paused || self.pause_packing
    }

    @(private)
    // Move entity's rows into the prefix at position len (in every owned table), then grow the prefix.
    group__swap_in :: #force_inline proc(self: ^Group, eid: entity_id) {
        for table in self.tables {
            table_raw__swap_rows(table, int(table.eid_to_rid[eid.ix]), self.len)
        }
        for at in self.arch_tables {
            arch_table__swap_rows(at, int(at.eid_to_rid[eid.ix]), self.len)
        }
        self.len += 1
    }

    @(private)
    // Move entity's rows out of the prefix (to position len-1 in every owned table), then shrink the prefix.
    group__swap_out :: #force_inline proc(self: ^Group, eid: entity_id) {
        last := self.len - 1
        for table in self.tables {
            table_raw__swap_rows(table, int(table.eid_to_rid[eid.ix]), last)
        }
        for at in self.arch_tables {
            arch_table__swap_rows(at, int(at.eid_to_rid[eid.ix]), last)
        }
        self.len = last
    }

    @(private)
    // Called by an owned table after a component was added; returns whether rows moved, so the caller only re-derives its component pointer when the swap actually happened.
    group__on_add :: #force_inline proc(self: ^Group, eid: entity_id) -> (moved: bool) {
        // full match? (needs every owned component)
        if !uni_bits__is_subset(&self.bits, &self.db.eid_to_bits[eid.ix]) do return false

        if group__is_packing_paused(self) {
            // rows must not move while paused — rebuild on resume
            self.dirty = true
            return false
        }

        // Already inside the prefix? Members sit at the same rid < len in every owned table, so checking one suffices.
        #no_bounds_check {
            if len(self.tables) > 0 {
                if int(self.tables[0].eid_to_rid[eid.ix]) < self.len do return false
            } else {
                if int(self.arch_tables[0].eid_to_rid[eid.ix]) < self.len do return false
            }
        }

        group__swap_in(self, eid)
        return true
    }

/*
    2026 (c) Oleh, https://github.com/zm69

    Growing capacities in place, at load boundaries and never mid-frame: the entity capacity of an
    Overbase with every Database attached to it, and the row capacity of individual tables.
    Growing never moves or renumbers entities; a smaller capacity is a no-op.

    NOTE: Created to be used outside of the main loop, at load time, and never mid-frame. 
*/
package ode_ecs

// Base
    import "base:runtime"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Entity capacity

    overbase__grow :: proc(self: ^Overbase, entities_cap: u32) -> Error {
        when VALIDATIONS {
            assert(overbase__is_valid(self))
            assert(entities_cap < max(u32))
        }

        new_cap := int(entities_cap)
        if new_cap <= self.id_factory.cap do return nil

        for db in self.databases.items {
            if database__has_sync(db) do return API_Error.Cannot_Grow_With_Sync
        }

        // the factory grows last, so a failed allocation leaves only unused slack
        for db in self.databases.items do database__grow_entities(db, new_cap) or_return
        return oc.ix_gen_factory__grow(&self.id_factory, new_cap, self.allocator)
    }

///////////////////////////////////////////////////////////////////////////////
// Row capacity

    table__grow :: proc(self: ^Table($T), cap: int) -> Error {
        when VALIDATIONS {
            assert(table__is_valid(self))
            assert(cap <= self.db.overbase.id_factory.cap)
        }
        if cap <= self.cap do return nil

        a := self.db.allocator
        n := len(self.rows)

        rows := make([]T, cap, a) or_return
        rid_to_eid, err := make([]entity_id, cap, a)
        if err != nil {
            delete(rows, a)
            return err
        }

        runtime.copy_slice(rows, self.rows)
        runtime.copy_slice(rid_to_eid, self.rid_to_eid)
        for i in self.cap..<cap do rid_to_eid[i].ix = DELETED_INDEX

        delete(self.rows, a)
        delete(self.rid_to_eid, a)
        self.rows = rows[:n]
        self.rid_to_eid = rid_to_eid
        self.cap = cap

        for view in self.subscribers.items do view__regrow(view) or_return
        grow__repoint_views(self.subscribers.items, self, self.rid_to_eid[:n], raw_data(self.rows), size_of(T))
        return nil
    }

    compact_table__grow :: proc(self: ^Compact_Table($T), cap: int) -> Error {
        when VALIDATIONS {
            assert(compact_table__is_valid(self))
            assert(cap <= self.db.overbase.id_factory.cap)
        }
        if cap <= self.cap do return nil

        a := self.db.allocator
        n := len(self.rows)

        oc_maps.rh_map32__grow(&self.eid_to_rid, oc_maps.rh_map32__capacity_for(cap), a) or_return

        rows := make([]T, cap, a) or_return
        rid_to_eid, err := make([]entity_id, cap, a)
        if err != nil {
            delete(rows, a)
            return err
        }

        runtime.copy_slice(rows, self.rows)
        runtime.copy_slice(rid_to_eid, self.rid_to_eid)
        for i in self.cap..<cap do rid_to_eid[i].ix = DELETED_INDEX

        delete(self.rows, a)
        delete(self.rid_to_eid, a)
        self.rows = rows[:n]
        self.rid_to_eid = rid_to_eid
        self.cap = cap

        for view in self.subscribers.items do view__regrow(view) or_return
        grow__repoint_views(self.subscribers.items, self, self.rid_to_eid[:n], raw_data(self.rows), size_of(T))
        return nil
    }

    flags_table__grow :: proc(self: ^Flags_Table, cap: int) -> Error {
        compact_table__grow(&self.compact, cap) or_return
        for sub in self.flags_subscribers.items do view__regrow(sub.view) or_return
        return nil
    }

    tag_table__grow :: proc(self: ^Tag_Table, cap: int) -> Error {
        when VALIDATIONS {
            assert(tag_table__is_valid(self))
            assert(cap <= self.db.overbase.id_factory.cap)
        }
        if cap <= self.cap do return nil

        a := self.db.allocator
        n := len(self.rows)

        oc_maps.rh_map32__grow(&self.eid_to_rid, oc_maps.rh_map32__capacity_for(cap), a) or_return

        rows := make([]entity_id, cap, a) or_return
        runtime.copy_slice(rows, self.rows)
        for i in n..<cap do rows[i].ix = DELETED_INDEX

        delete(self.rows, a)
        self.rows = rows[:n]
        self.cap = cap

        for view in self.subscribers.items do view__regrow(view) or_return
        return nil
    }

    // holders_cap grows presence; pairs_cap grows the pair rows.
    pair_table__grow :: proc(self: ^Pair_Table($T), holders_cap: int, pairs_cap: int) -> Error {
        when VALIDATIONS do assert(pair_table__is_valid(self))

        tag_table__grow(&self.presence, holders_cap) or_return
        if pairs_cap <= self.pairs_cap do return nil

        a := self.db.allocator
        old := self.pairs_cap
        none: entity_id
        none.ix = DELETED_INDEX
        no_row := pair_row_id(DELETED_INDEX)

        grow_slice(&self.targets, pairs_cap, none, a) or_return
        grow_slice(&self.row_holder, pairs_cap, none, a) or_return
        grow_slice(&self.next_pair, pairs_cap, no_row, a) or_return
        grow_slice(&self.prev_pair, pairs_cap, no_row, a) or_return
        grow_slice(&self.next_pair_by_target, pairs_cap, no_row, a) or_return
        grow_slice(&self.prev_pair_by_target, pairs_cap, no_row, a) or_return
        grow_slice(&self.scratch, pairs_cap, none, a) or_return
        grow_slice(&self.scratch_by_target, pairs_cap, none, a) or_return
        grow_slice(&self.data, pairs_cap, T{}, a) or_return
        grow_slice(&self.free_rows, pairs_cap, no_row, a) or_return

        for row in old..<pairs_cap {
            self.free_rows[self.free_count] = pair_row_id(row)
            self.free_count += 1
        }
        self.pairs_cap = pairs_cap
        return nil
    }

    relations_table__grow :: proc(self: ^Relations_Table, cap: int) -> Error {
        when VALIDATIONS {
            assert(relations_table__is_valid(self))
            assert(cap <= self.db.overbase.id_factory.cap)
        }
        if cap <= self.cap do return nil

        a := self.db.allocator
        none: entity_id
        none.ix = DELETED_INDEX

        grow_slice(&self.scratch, cap, none, a) or_return
        grow_slice(&self.walk_buf, cap * 2, none, a) or_return
        grow_slice(&self.level_offsets, cap + 2, 0, a) or_return
        self.cap = cap
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    // A longer copy of s^, the new tail set to fill; nil stays nil.
    @(private)
    grow_slice :: proc(s: ^[]$E, n: int, fill: E, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        if s^ == nil || n <= len(s^) do return nil

        grown := make([]E, n, allocator) or_return
        runtime.copy_slice(grown, s^)
        for i in len(s^)..<n do grown[i] = fill

        delete(s^, allocator)
        s^ = grown
        return nil
    }

    @(private)
    database__has_sync :: proc(self: ^Database) -> bool {
        when !SYNC_ENABLED do return false

        for table in self.tables.items {
            if table == nil do continue
            #partial switch table.type {
            case .Table:
                if len((cast(^Table_Base)table).sync_watchers.items) > 0 do return true
            case .Compact_Table, .Flags_Table:
                if len((cast(^Compact_Table_Base)table).sync_watchers.items) > 0 do return true
            }
        }
        for tag in self.tag_tables.items {
            if tag != nil && len(tag.sync_watchers.items) > 0 do return true
        }
        return false
    }

    @(private)
    database__grow_entities :: proc(self: ^Database, n: int) -> Error {
        a := self.allocator
        none: entity_id
        none.ix = DELETED_INDEX

        grow_slice(&self.eid_to_bits, n, Uni_Bits{}, a) or_return
        grow_slice(&self.eid_to_disabled_bits, n, Uni_Bits{}, a) or_return
        grow_slice(&self.eid_to_tag_bits, n, Uni_Bits{}, a) or_return
        grow_slice(&self.eid_to_tag_disabled_bits, n, Uni_Bits{}, a) or_return
        grow_slice(&self.eid_to_arch_table, n, nil, a) or_return

        for table in self.tables.items {
            if table == nil do continue
            #partial switch table.type {
            case .Table:
                grow_slice(&(cast(^Table_Base)table).eid_to_rid, n, TABLE_NO_RID, a) or_return
            case .Arch_Table:
                grow_slice(&(cast(^Arch_Table)table).eid_to_rid, n, ARCH_TABLE_NO_RID, a) or_return
            }
        }

        for view in self.views.items {
            if view != nil do grow_slice(&view.eid_to_rid, n, VIEW_NO_RID, a) or_return
        }

        for pt in self.pair_tables.items {
            if pt == nil do continue
            grow_slice(&pt.first_pair, n, pair_row_id(DELETED_INDEX), a) or_return
            grow_slice(&pt.first_pair_by_target, n, pair_row_id(DELETED_INDEX), a) or_return
        }

        if r := self.relations; r != nil {
            grow_slice(&r.parent, n, none, a) or_return
            grow_slice(&r.first_child, n, none, a) or_return
            grow_slice(&r.next_sibling, n, none, a) or_return
            grow_slice(&r.prev_sibling, n, none, a) or_return
            grow_slice(&r.children_count, n, 0, a) or_return
        }

        return nil
    }

    // A view holds as many rows as its smallest included table.
    @(private)
    view__regrow :: proc(self: ^View) -> Error {
        cap := max(int)
        for table in self.tables do cap = min(cap, shared_table__cap(table))
        for tag in self.tags do cap = min(cap, tag.cap)
        if cap <= self.cap do return nil

        a := self.db.allocator
        for &col in self.columns do grow_slice(&col.rows, cap + 1, nil, a) or_return
        for &col in self.arch_columns.items do grow_slice(&col.rows, cap + 1, nil, a) or_return
        grow_slice(&self.rid_to_eid, cap + 1, entity_id{}, a) or_return
        self.cap = cap
        return nil
    }

    // Views cache a pointer per row; rows moved to a new allocation.
    @(private)
    grow__repoint_views :: proc(views: []^View, table: ^Shared_Table, eids: []entity_id, rows: rawptr, size: int) {
        for view in views {
            for eid, rid in eids {
                if eid.ix == DELETED_INDEX do continue
                if view.suspended {
                    view__missed_update_for_member(view, eid)
                } else {
                    _ = view__update_component_ptr(view, table, eid, rawptr(uintptr(rows) + uintptr(rid * size)))
                }
            }
        }
    }

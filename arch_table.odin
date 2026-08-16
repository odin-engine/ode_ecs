/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:slice"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Arch_Table — true-SoA archetype table: N type-erased columns sharing one
// eid_to_rid/rid_to_eid index; a row (every column) moves as a single unit
// in one swap, unlike Group's N separate table_raw__swap_rows calls.
// Membership is whole-row, all-or-nothing (like Tag_Table, not per-component like Table).
//

    // eid_to_rid value for "entity has no row in this archetype"
    @(private)
    ARCH_TABLE_NO_RID :: max(u32)

    Arch_Column :: struct {
        type_info: ^runtime.Type_Info,
        rows: []byte, // cap * type_info.size bytes; row r at &rows[r*type_info.size], never length-hijacked
    }

    Arch_Table :: struct {
        using shared: Shared_Table,

        columns: []Arch_Column,        // order == order of component_types passed to init
        col_payload_offsets: []int,    // byte offset of each column inside one packed row payload (Command_Buffer)
        payload_size: int,

        rid_to_eid: []entity_id,       // shared across ALL columns, len == cap, always full length
        eid_to_rid: []u32,             // shared across ALL columns, len == entities_cap; ARCH_TABLE_NO_RID when absent

        len: int,                      // live row count [0, cap] — plain field, not a slice-length hijack: unlike
                                        // Table (rows hijacked, rid_to_eid full-length), Arch_Table has only one shared index slice.

        owner: ^Group,                 // Group that owns this Arch_Table (at most one), nil when not owned

        cap: int,

        // Deferred tail swap (db.tail_swap_paused / self.pause_packing) hole bookkeeping.
        // A hole is a row with rid_to_eid[rid].ix == DELETED_INDEX inside [0, len).
        holes_count: int,
        first_hole_rid: int, // scan-start hint for pack; max(int) when no holes

        // 1-entry memo for arch_table__column_index: repeated queries for the same
        // component type (the common case — a View column or a system reading one
        // type every row) skip the linear scan. last_col_type == nil means empty.
        last_col_type: typeid,
        last_col_idx: int,

        // Sizes subscribers/subscribers_with_filter/subscribers_excluding/subscribers_any_of
        // when they're lazily allocated on first attach.
        subscribers_cap: int,

        subscribers: oc.Dense_Arr(^View),
        subscribers_with_filter: oc.Dense_Arr(^View),
        subscribers_excluding: oc.Dense_Arr(^View), // views that EXCLUDE this table 
        subscribers_any_of: oc.Dense_Arr(^View), // views that any_of this table
    }

    arch_table__is_valid :: proc(self: ^Arch_Table) -> bool {
        if self == nil do return false
        if !shared_table__is_valid_internal(&self.shared) do return false
        if self.columns == nil do return false
        if self.rid_to_eid == nil do return false
        if self.eid_to_rid == nil do return false
        if self.cap <= 0 do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_with_filter) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_excluding) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_any_of) do return false

        return true
    }

    arch_table__init :: proc(self: ^Arch_Table, db: ^Database, cap: int, component_types: []typeid, subscribers_cap: int = SUBSCRIBERS_CAP, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(cap > 0, loc = loc)
            assert(cap <= db.overbase.id_factory.cap, loc = loc) // cannot be larger than entities_cap
            assert(cap < int(max(u32)), loc = loc) // row ids must fit the u32 eid_to_rid index
        }

        if len(component_types) == 0 do return API_Error.Tables_Array_Should_Not_Be_Empty

        when VALIDATIONS {
            for t in component_types {
                ti := type_info_of(t)
                assert(ti != nil && ti.size != 0, "Arch_Table: component type must not be zero-sized — use Tag_Table for a marker/tag component that carries no data", loc = loc)
            }

            for i in 0..<len(component_types) {
                for j in i + 1..<len(component_types) {
                    assert(component_types[i] != component_types[j], "Arch_Table: duplicate component type in component_types", loc = loc)
                }
            }
        }

        for t in component_types {
            ti := type_info_of(t)
            if ti == nil || ti.size == 0 do return API_Error.Component_Size_Cannot_Be_Zero
        }

        shared_table__init(&self.shared, Table_Type.Arch_Table, db)

        self.owner = nil
        self.cap = cap
        self.last_col_type = nil

        self.columns = make([]Arch_Column, len(component_types), db.allocator) or_return
        self.col_payload_offsets = make([]int, len(component_types), db.allocator) or_return

        offset := 0
        for t, i in component_types {
            ti := type_info_of(t)
            self.columns[i].type_info = ti
            self.columns[i].rows = make([]byte, cap * ti.size, db.allocator) or_return

            offset = mem.align_forward_int(offset, ti.align)
            self.col_payload_offsets[i] = offset
            offset += ti.size
        }
        self.payload_size = offset

        self.rid_to_eid = make([]entity_id, cap, db.allocator) or_return
        self.eid_to_rid = make([]u32, db.overbase.id_factory.cap, db.allocator) or_return

        self.subscribers_cap = subscribers_cap

        self.id = database__attach_table(db, self) or_return
        self.state = Object_State.Normal

        arch_table__clear(self) or_return

        return nil
    }

    arch_table__terminate :: proc(self: ^Arch_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        for view in self.subscribers.items do view.state = Object_State.Invalid
        for view in self.subscribers_excluding.items do view.state = Object_State.Invalid
        for view in self.subscribers_any_of.items do view.state = Object_State.Invalid

        // A group missing one of its owned tables is meaningless — invalidate it
        // (it still owns its allocations; terminate it to release them).
        if self.owner != nil {
            self.owner.state = Object_State.Invalid
            self.owner = nil
        }

        // Clear this table's bit from all entities: the id may be reused by a
        // future table, and a stale bit would make destroy_entity fail on it.
        for &bits in self.db.eid_to_bits do uni_bits__remove(&bits, self.id)

        database__detach_table(self.db, self)

        for &col in self.columns {
            if col.rows != nil do delete(col.rows, self.db.allocator) or_return
        }
        delete(self.columns, self.db.allocator) or_return
        delete(self.col_payload_offsets, self.db.allocator) or_return
        delete(self.rid_to_eid, self.db.allocator) or_return
        delete(self.eid_to_rid, self.db.allocator) or_return

        if self.subscribers_any_of.items != nil do oc.dense_arr__terminate(&self.subscribers_any_of, self.db.allocator) or_return
        if self.subscribers_excluding.items != nil do oc.dense_arr__terminate(&self.subscribers_excluding, self.db.allocator) or_return
        if self.subscribers_with_filter.items != nil do oc.dense_arr__terminate(&self.subscribers_with_filter, self.db.allocator) or_return
        if self.subscribers.items != nil do oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return

        shared_table__clear_state(&self.shared)

        return nil
    }

    arch_table__len :: #force_inline proc "contextless" (self: ^Arch_Table) -> int {
        return self.len
    }

    arch_table__cap :: #force_inline proc "contextless" (self: ^Arch_Table) -> int {
        return self.cap
    }

    arch_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Arch_Table, #any_int row_number: int) -> entity_id {
        return self.rid_to_eid[row_number]
    }

    @(require_results)
    arch_table__has_entity :: proc(self: ^Arch_Table, eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return self.eid_to_rid[eid.ix] != ARCH_TABLE_NO_RID
    }

    arch_table__disable_component :: proc(self: ^Arch_Table, eid: entity_id) -> Error {
        return database__disable_component(self.db, eid, self.id)
    }

    arch_table__enable_component :: proc(self: ^Arch_Table, eid: entity_id) -> Error {
        return database__enable_component(self.db, eid, self.id)
    }

    @(require_results)
    arch_table__is_component_disabled :: proc(self: ^Arch_Table, eid: entity_id) -> bool {
        return database__is_component_disabled(self.db, eid, self.id)
    }

    // Memory usage in bytes
    arch_table__memory_usage :: proc(self: ^Arch_Table) -> int {
        total := size_of(self^)

        if self.columns != nil {
            total += size_of(Arch_Column) * len(self.columns)
            for col in self.columns {
                if col.rows != nil do total += len(col.rows)
            }
        }

        if self.col_payload_offsets != nil do total += size_of(int) * len(self.col_payload_offsets)
        if self.rid_to_eid != nil do total += size_of(entity_id) * len(self.rid_to_eid)
        if self.eid_to_rid != nil do total += size_of(u32) * len(self.eid_to_rid)

        total += oc.dense_arr__memory_usage(&self.subscribers)
        total += oc.dense_arr__memory_usage(&self.subscribers_with_filter)
        total += oc.dense_arr__memory_usage(&self.subscribers_excluding)
        total += oc.dense_arr__memory_usage(&self.subscribers_any_of)

        return total
    }

    @(private)
    // Deferred packing check: a Group-owned table defers to the group's pause state
    // (rows move in lock-step across owned tables); standalone checks db-wide/self flag.
    arch_table__is_packing_paused :: #force_inline proc "contextless" (self: ^Arch_Table) -> bool {
        if self.owner != nil do return group__is_packing_paused(self.owner)
        return shared_table__is_packing_paused(cast(^Shared_Table) self)
    }

    @(private)
    // Column index for type T, -1 if absent. 1-entry memo hit skips the scan
    // entirely (the common case: repeated queries for the same T — a View column
    // read every row, or back-to-back get_component/dense_slice calls). Linear
    // scan on miss — cheap for realistic archetype column counts, avoids the
    // hidden allocation a map[typeid]int would need.
    arch_table__column_index :: proc "contextless" (self: ^Arch_Table, id: typeid) -> int {
        if id == self.last_col_type do return self.last_col_idx

        for &col, i in self.columns {
            if col.type_info.id == id {
                self.last_col_type = id
                self.last_col_idx = i
                return i
            }
        }
        return -1
    }

    @(private)
    // Fast path for Arch_Iterator's nextN (col_idx resolved once, cached) — no
    // per-row scan, no VALIDATIONS assert, so it can stay contextless.
    arch_table__component_ptr_by_col :: #force_inline proc "contextless" (self: ^Arch_Table, #any_int row: int, #any_int col_idx: int, $T: typeid) -> ^T #no_bounds_check {
        col := &self.columns[col_idx]
        // size_of(T) is compile-time (unlike col.type_info.size), so the multiply
        // folds into a constant shift — same trick as table_raw__rid_to_ptr_sized.
        return cast(^T) rawptr(uintptr(raw_data(col.rows)) + uintptr(row) * uintptr(size_of(T)))
    }

    @(require_results)
    arch_table__get_component_by_row :: proc(self: ^Arch_Table, #any_int row: int, $T: typeid) -> ^T {
        idx := arch_table__column_index(self, typeid_of(T))
        when VALIDATIONS {
            assert(idx >= 0, "Arch_Table: component type is not one of this archetype's columns")
        }
        if idx < 0 do return nil

        col := &self.columns[idx]
        #no_bounds_check {
            return cast(^T) rawptr(uintptr(raw_data(col.rows)) + uintptr(row) * uintptr(col.type_info.size))
        }
    }

    @(require_results)
    arch_table__get_component :: proc(self: ^Arch_Table, eid: entity_id, $T: typeid) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        #no_bounds_check {
            rid := self.eid_to_rid[eid.ix]
            if rid == ARCH_TABLE_NO_RID do return nil
            return arch_table__get_component_by_row(self, int(rid), T)
        }
    }

    // One column's components as a contiguous slice, row order — archetype rows
    // are already packed, so (unlike View's slice) no alignment check needed.
    @(require_results)
    arch_table__dense_slice :: proc(self: ^Arch_Table, $T: typeid) -> []T {
        idx := arch_table__column_index(self, typeid_of(T))
        if idx < 0 do return nil

        col := &self.columns[idx]
        return slice.from_ptr(cast(^T) raw_data(col.rows), self.len)
    }

    // Adds a row for `eid` across every column (zero-initialized). All-or-
    // nothing: there is no per-component add for a fixed archetype column set.
    arch_table__add_entity :: proc(self: ^Arch_Table, eid: entity_id, loc := #caller_location) -> (err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(eid.ix >= 0, loc = loc)
        }

        database__is_entity_correct(self.db, eid) or_return

        rid := self.eid_to_rid[eid.ix]

        if rid != ARCH_TABLE_NO_RID {
            // Notify subscribed views anyway — recovers view membership a previous add
            // failed to register (e.g. view was at cap); same as table_raw__add_component_sized.
            for view in self.subscribers.items {
                if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
            }
            for view in self.subscribers_any_of.items {
                if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
            }
            for view in self.subscribers_excluding.items {
                if !view.suspended do view__remove_record(view, eid)
            }
            return API_Error.Component_Already_Exist
        }

        if self.len >= self.cap do return oc.Core_Error.Container_Is_Full

        new_rid := self.len

        for &col in self.columns {
            elem_size := col.type_info.size
            dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(new_rid) * uintptr(elem_size))
            mem.zero(dst, elem_size)
        }

        self.eid_to_rid[eid.ix] = u32(new_rid)
        self.rid_to_eid[new_rid] = eid

        database__add_component(self.db, eid, self.id)
        database__notify_observers(self.db, .Arch_Entity_Added, eid, table_id = self.id)

        self.len += 1

        // Group maintenance: swap into the group prefix if the entity now has every
        // owned component (deferred while tail swap paused). No pointer to re-derive here.
        if self.owner != nil do group__on_add(self.owner, eid)

        for view in self.subscribers.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }
        for view in self.subscribers_any_of.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }
        for view in self.subscribers_excluding.items {
            if !view.suspended do view__remove_record(view, eid)
        }

        return nil
    }

    // Allocates an entity id and its archetype row in one call. Rolls back the
    // freshly allocated id if the row allocation fails (e.g. container full).
    @(require_results)
    arch_table__create_entity :: proc(self: ^Arch_Table, loc := #caller_location) -> (eid: entity_id, err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
        }

        eid, err = database__create_entity(self.db)
        if err != nil do return eid, err

        aerr := arch_table__add_entity(self, eid, loc)
        if aerr != nil {
            database__destroy_entity(self.db, eid)
            return entity_id{ix = DELETED_INDEX}, aerr
        }

        return eid, nil
    }

    // Removes target_eid's row (every column) via one tail-swap across all
    // columns — vs. N separate swaps for N Group-owned tables.
    arch_table__remove_entity :: proc(self: ^Arch_Table, target_eid: entity_id, loc := #caller_location) -> (err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(target_eid.ix >= 0, loc = loc)
        }

        database__is_entity_correct(self.db, target_eid) or_return

        if self.len <= 0 do return oc.Core_Error.Not_Found

        target_rid := self.eid_to_rid[target_eid.ix]
        if target_rid == ARCH_TABLE_NO_RID do return oc.Core_Error.Not_Found

        // Fires before any mutation below (a whole row spans several columns, so
        // there's no single pointer to hand back — `data` stays nil).
        database__notify_observers(self.db, .Arch_Entity_Removed, target_eid, table_id = self.id)

        // Cached once: nothing between here and the deferred-tail-swap check
        // below changes the pause state.
        paused := arch_table__is_packing_paused(self)

        // Group maintenance: losing an owned component evicts the member — swap its
        // row out of the prefix before this table's tail swap runs (members sit at
        // rid < owner.len). Paused: mark dirty and rebuild on resume instead of moving rows.
        if self.owner != nil && int(target_rid) < self.owner.len {
            if paused {
                self.owner.dirty = true
            } else {
                group__swap_out(self.owner, target_eid)
                target_rid = self.eid_to_rid[target_eid.ix]
            }
        }

        // Deferred tail swap: clear every column's row in place, leaving a
        // hole. Nothing moves, so component pointers stay stable while iterating.
        if paused {
            self.eid_to_rid[target_eid.ix] = ARCH_TABLE_NO_RID
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for &col in self.columns {
                elem_size := col.type_info.size
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(target_rid) * uintptr(elem_size))
                mem.zero(dst, elem_size)
            }

            if int(target_rid) == self.len - 1 {
                self.len -= 1
                // absorb trailing holes so they never need packing
                for self.len > 0 && is_not_set(self.rid_to_eid[self.len - 1]) {
                    self.len -= 1
                    self.holes_count -= 1
                }
            } else {
                self.holes_count += 1
                if int(target_rid) < self.first_hole_rid do self.first_hole_rid = int(target_rid)
            }

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
                else do view__missed_update_for_member(view, target_eid)
            }

            database__remove_component(self.db, target_eid, self.id)
            arch_table__notify_excluding_views(self, target_eid)
            arch_table__notify_any_of_views(self, target_eid)
            return nil
        }

        tail_rid := self.len - 1

        if int(target_rid) == tail_rid {
            self.eid_to_rid[target_eid.ix] = ARCH_TABLE_NO_RID
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for &col in self.columns {
                elem_size := col.type_info.size
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(target_rid) * uintptr(elem_size))
                mem.zero(dst, elem_size)
            }

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
                else do view__missed_update_for_member(view, target_eid)
            }
        } else {
            tail_eid := self.rid_to_eid[tail_rid]
            when VALIDATIONS do assert(!is_not_set(tail_eid))

            // Move every column's tail row into the hole in ONE pass — a single
            // swap for the whole archetype row instead of one swap per column.
            for &col in self.columns {
                elem_size := col.type_info.size
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(target_rid) * uintptr(elem_size))
                src := rawptr(uintptr(raw_data(col.rows)) + uintptr(tail_rid) * uintptr(elem_size))
                mem.copy(dst, src, elem_size)
                mem.zero(src, elem_size)
            }

            self.eid_to_rid[tail_eid.ix] = target_rid
            self.eid_to_rid[target_eid.ix] = ARCH_TABLE_NO_RID

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component_rid(view, cast(^Shared_Table) self, tail_eid, target_rid)
                } else {
                    view__missed_update_for_member(view, target_eid)
                    view__missed_update_for_member(view, tail_eid)
                }
            }
        }

        self.len -= 1

        database__remove_component(self.db, target_eid, self.id)
        arch_table__notify_excluding_views(self, target_eid)
        arch_table__notify_any_of_views(self, target_eid)

        return nil
    }

    // Compact holes left by removals made while tail swap was paused. Callable mid-pause too.
    arch_table__pack :: proc(self: ^Arch_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.holes_count <= 0 {
            self.first_hole_rid = max(int)
            return nil
        }

        front := self.first_hole_rid
        back := self.len - 1

        for self.holes_count > 0 {
            // shrink span past trailing holes
            for back >= 0 && is_not_set(self.rid_to_eid[back]) {
                back -= 1
                self.holes_count -= 1
            }
            if self.holes_count <= 0 do break

            // next hole from the front; guaranteed to exist below back
            for !is_not_set(self.rid_to_eid[front]) do front += 1

            // move the last live row's every column into the hole, one pass
            for &col in self.columns {
                elem_size := col.type_info.size
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(front) * uintptr(elem_size))
                src := rawptr(uintptr(raw_data(col.rows)) + uintptr(back) * uintptr(elem_size))
                mem.copy(dst, src, elem_size)
                mem.zero(src, elem_size)
            }

            moved_eid := self.rid_to_eid[back]
            self.rid_to_eid[front] = moved_eid
            self.rid_to_eid[back].ix = DELETED_INDEX
            self.eid_to_rid[moved_eid.ix] = u32(front)

            for view in self.subscribers.items {
                if !view.suspended do view__update_component_rid(view, cast(^Shared_Table) self, moved_eid, front)
                else do view__missed_update_for_member(view, moved_eid)
            }

            back -= 1
            front += 1
            self.holes_count -= 1
        }

        self.len = back + 1
        self.first_hole_rid = max(int)

        return nil
    }

    // Pause tail swapping for this table only, independent of the
    // database-wide pause_packing.
    arch_table__pause_packing :: proc(self: ^Arch_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.owner != nil do return API_Error.Cannot_Pause_Table_Owned_By_Group

        self.pause_packing = true
        return nil
    }

    // Resume tail swapping for this table and pack the holes it accumulated.
    arch_table__resume_packing :: proc(self: ^Arch_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.owner != nil do return API_Error.Cannot_Pause_Table_Owned_By_Group

        self.pause_packing = false
        return arch_table__pack(self)
    }

    arch_table__clear :: proc(self: ^Arch_Table) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.rid_to_eid != nil {
            for i := 0; i < self.cap; i += 1 do self.rid_to_eid[i].ix = DELETED_INDEX
        }

        slice.fill(self.eid_to_rid, ARCH_TABLE_NO_RID)

        // an empty owned table means no entity can match the owner group
        if self.owner != nil {
            self.owner.len = 0
            self.owner.dirty = false
        }

        for &col in self.columns {
            if col.rows != nil do mem.zero(raw_data(col.rows), len(col.rows))
        }

        self.len = 0
        self.holes_count = 0
        self.first_hole_rid = max(int)

        return nil
    }

    @(private)
    // Swaps two live rows (all columns + both index directions) and notifies
    // subscribed views. One call moves the whole archetype row — contrast with
    // Group's one table_raw__swap_rows call per owned table.
    arch_table__swap_rows :: proc(self: ^Arch_Table, #any_int rid_a: int, #any_int rid_b: int) #no_bounds_check {
        if rid_a == rid_b do return

        for &col in self.columns {
            elem_size := col.type_info.size
            pa := rawptr(uintptr(raw_data(col.rows)) + uintptr(rid_a) * uintptr(elem_size))
            pb := rawptr(uintptr(raw_data(col.rows)) + uintptr(rid_b) * uintptr(elem_size))
            slice.ptr_swap_non_overlapping(pa, pb, elem_size)
        }

        eid_a := self.rid_to_eid[rid_a]
        eid_b := self.rid_to_eid[rid_b]
        self.rid_to_eid[rid_a] = eid_b
        self.rid_to_eid[rid_b] = eid_a
        self.eid_to_rid[eid_a.ix] = u32(rid_b)
        self.eid_to_rid[eid_b.ix] = u32(rid_a)

        for view in self.subscribers.items {
            if !view.suspended {
                view__update_component_rid(view, cast(^Shared_Table) self, eid_a, rid_b)
                view__update_component_rid(view, cast(^Shared_Table) self, eid_b, rid_a)
            } else {
                view__missed_update_for_member(view, eid_a)
                view__missed_update_for_member(view, eid_b)
            }
        }
    }

    @(private)
    // Type-erased add for Command_Buffer replay — `data`, if not nil, is a packed
    // payload blob laid out per col_payload_offsets. "Last write wins": overwrites
    // an existing row instead of dropping it; membership notify already ran in arch_table__add_entity.
    arch_table__add_entity_from_payload :: proc(self: ^Arch_Table, eid: entity_id, data: rawptr) -> (component: rawptr, err: Error) {
        aerr := arch_table__add_entity(self, eid)
        if aerr != nil && aerr != API_Error.Component_Already_Exist do return nil, aerr

        if data != nil {
            rid := self.eid_to_rid[eid.ix]
            for &col, i in self.columns {
                elem_size := col.type_info.size
                src := rawptr(uintptr(data) + uintptr(self.col_payload_offsets[i]))
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(rid) * uintptr(elem_size))
                mem.copy(dst, src, elem_size)
            }

            if aerr == API_Error.Component_Already_Exist {
                for view in self.subscribers_with_filter.items {
                    if !view.suspended do view__rerun_filter(view, eid)
                }
            }
        }

        return nil, aerr
    }

    @(private)
    arch_table__attach_subscriber :: proc(self: ^Arch_Table, view: ^View) -> Error {
        if self.subscribers.items == nil do oc.dense_arr__init(&self.subscribers, self.subscribers_cap, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers, view, self.db.allocator)
        if err != nil do return err

        if view.filter != nil {
            if self.subscribers_with_filter.items == nil do oc.dense_arr__init(&self.subscribers_with_filter, self.subscribers_cap, self.db.allocator) or_return

            _, err = oc.dense_arr__add_growing(&self.subscribers_with_filter, view, self.db.allocator)
            if err != nil do return err
        }

        return nil
    }

    @(private)
    arch_table__detach_subscriber :: proc(self: ^Arch_Table, view: ^View) -> Error {
        err := oc.dense_arr__remove_by_value(&self.subscribers, view)
        if err != nil do return err

        err = oc.dense_arr__remove_by_value(&self.subscribers_with_filter, view)
        if err == oc.Core_Error.Not_Found do return nil // not found is ok, it means view has no filter
        return err
    }

    @(private)
    arch_table__attach_exclude_subscriber :: proc(self: ^Arch_Table, view: ^View) -> Error {
        if self.subscribers_excluding.items == nil do oc.dense_arr__init(&self.subscribers_excluding, self.subscribers_cap, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers_excluding, view, self.db.allocator)
        return err
    }

    @(private)
    arch_table__detach_exclude_subscriber :: proc(self: ^Arch_Table, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_excluding, view)
    }

    @(private)
    arch_table__attach_any_of_subscriber :: proc(self: ^Arch_Table, view: ^View) -> Error {
        if self.subscribers_any_of.items == nil do oc.dense_arr__init(&self.subscribers_any_of, self.subscribers_cap, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers_any_of, view, self.db.allocator)
        return err
    }

    @(private)
    arch_table__detach_any_of_subscriber :: proc(self: ^Arch_Table, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_any_of, view)
    }

    @(private)
    // A view excluding this table may newly match after a component removal here.
    // Skipped mid-destroy (later removals would just evict it again).
    arch_table__notify_excluding_views :: #force_inline proc(self: ^Arch_Table, eid: entity_id) {
        if self.db.destroying_eid_ix == eid.ix do return
        for view in self.subscribers_excluding.items {
            if !view.suspended && view__components_match(view, eid) {
                when VALIDATIONS {
                    aerr := view__add_record(view, eid)
                    assert(aerr != API_Error.Cannot_Add_Record_To_View_Container_Is_Full, "excluding view is full — entity silently dropped, raise the view's included tables' caps")
                } else {
                    view__add_record(view, eid)
                }
            }
        }
    }

    @(private)
    arch_table__notify_any_of_views :: #force_inline proc(self: ^Arch_Table, eid: entity_id) {
        for view in self.subscribers_any_of.items {
            if !view.suspended && !view__components_match(view, eid) do view__remove_record(view, eid)
        }
    }

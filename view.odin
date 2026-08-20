/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:slice"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// View

    @(private)
    VIEW_NO_RID :: view_record_id(max(u32))

    View_Column :: struct {
        type_info: ^runtime.Type_Info,
        rows: []rawptr,
        arch_base: int, // only meaningful when the owning table is an Arch_Table
    }

    Arch_View_Column :: struct {
        table: ^Arch_Table,
        col_idx: int,
        type_info: ^runtime.Type_Info,
        rows: []rawptr,
    }

    View_Dense_State :: enum u8 {
        Unknown = 0,
        Aligned,
        Misaligned,
    }

    View :: struct {
        id: view_id,
        state: Object_State,
        db: ^Database,

        tables: []^Shared_Table,
        excludes: oc.Dense_Arr(^Shared_Table),
        any_of: oc.Dense_Arr(^Shared_Table),

        tid_to_cid: []view_column_id,
        columns: []View_Column,
        arch_columns: oc.Dense_Arr(Arch_View_Column),

        eid_to_rid: []view_record_id,
        rid_to_eid: []entity_id,

        bits: Uni_Bits,
        exclude_bits: Uni_Bits,
        any_of_bits: Uni_Bits,
        suspended: bool,
        stale: bool,

        dense_state: View_Dense_State,
        dense_cols: []View_Dense_State,

        filter: proc(row: ^View_Row, user_data: rawptr) -> bool,
        user_data: rawptr,

        len: int,
        cap: int,
    }

    view__is_valid :: proc(self: ^View) -> bool {
        if self == nil do return false
        if self.id < 0 do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if self.tables == nil do return false
        if self.tid_to_cid == nil do return false
        if self.columns == nil do return false
        if self.eid_to_rid == nil do return false
        if self.rid_to_eid == nil do return false
        if self.cap <= 0 do return false

        return true
    }

    view__init :: proc(
        self: ^View,
        db: ^Database,
        includes: []^Shared_Table,
        excludes: []^Shared_Table = nil,
        any_of: []^Shared_Table = nil,
        filter: proc(row: ^View_Row, user_data: rawptr = nil) -> bool = nil,
        loc := #caller_location,
    ) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
        }

        if includes == nil || len(includes) <= 0 do return API_Error.Tables_Array_Should_Not_Be_Empty

        uni_bits__clear(&self.bits)
        uni_bits__clear(&self.exclude_bits)
        uni_bits__clear(&self.any_of_bits)
        self.excludes = {}
        self.any_of = {}
        self.arch_columns = {}
        self.suspended = false
        self.stale = false

        self.db = db
        self.filter = filter

        sorted_includes := slice.clone(includes, db.allocator) or_return
        defer delete(sorted_includes, db.allocator)
        slice.sort(sorted_includes)
        uniq_tables := slice.unique(sorted_includes)
        tables_len := len(uniq_tables)

        uniq_excludes: []^Shared_Table
        sorted_excludes: []^Shared_Table
        defer if sorted_excludes != nil do delete(sorted_excludes, db.allocator)
        if excludes != nil && len(excludes) > 0 {
            sorted_excludes = slice.clone(excludes, db.allocator) or_return
            slice.sort(sorted_excludes)
            uniq_excludes = slice.unique(sorted_excludes)

            for table in uniq_excludes {
                when VALIDATIONS {
                    assert(shared_table__is_valid(table), loc = loc)
                }
                if slice.contains(uniq_tables, table) do return API_Error.Table_Cannot_Be_Included_And_Excluded
            }
        }

        uniq_any_of: []^Shared_Table
        sorted_any_of: []^Shared_Table
        defer if sorted_any_of != nil do delete(sorted_any_of, db.allocator)
        if any_of != nil && len(any_of) > 0 {
            sorted_any_of = slice.clone(any_of, db.allocator) or_return
            slice.sort(sorted_any_of)
            uniq_any_of = slice.unique(sorted_any_of)

            for table in uniq_any_of {
                when VALIDATIONS {
                    assert(shared_table__is_valid(table), loc = loc)
                }
                if slice.contains(uniq_tables, table) do return API_Error.Table_Cannot_Be_Included_And_Any_Of
            }
        }

        max_table_id: int = -1
        for table in uniq_tables {
            when VALIDATIONS {
                assert(shared_table__is_valid(table), loc = loc)
            }
            if int(table.id) > max_table_id do max_table_id = int(table.id)
        }

        self.tables = make([]^Shared_Table, tables_len, db.allocator) or_return

        self.tid_to_cid = make([]view_column_id, max_table_id + 1, db.allocator) or_return
        for i := 0; i < len(self.tid_to_cid); i += 1 do self.tid_to_cid[i] = DELETED_INDEX

        self.columns = make([]View_Column, tables_len, db.allocator) or_return

        self.cap = max(int)
        for table, index in uniq_tables {
            self.tables[index] = table
            self.tid_to_cid[table.id] = cast(view_column_id) index

            if shared_table__cap(table) < self.cap do self.cap = shared_table__cap(table)

            self.columns[index].type_info = shared_table__type_info(table)

            uni_bits__add(&self.bits, table.id)
        }

        when VALIDATIONS {
            assert(self.cap < int(max(u32)), loc = loc)
        }

        if len(uniq_excludes) > 0 {
            oc.dense_arr__init(&self.excludes, len(uniq_excludes), db.allocator) or_return
            for table in uniq_excludes {
                oc.dense_arr__add(&self.excludes, cast(^Shared_Table) table)
                uni_bits__add(&self.exclude_bits, table.id)
            }
        }

        if len(uniq_any_of) > 0 {
            oc.dense_arr__init(&self.any_of, len(uniq_any_of), db.allocator) or_return
            for table in uniq_any_of {
                oc.dense_arr__add(&self.any_of, cast(^Shared_Table) table)
                uni_bits__add(&self.any_of_bits, table.id)
            }
        }

        for &col in self.columns {
            col.rows = make([]rawptr, self.cap + 1, db.allocator) or_return
        }

        for table in uniq_tables {
            if table.type == Table_Type.Arch_Table {
                if aerr := view__auto_register_arch_columns(self, cast(^Arch_Table) table); aerr != nil {
                    for &col in self.columns do if col.rows != nil do delete(col.rows, db.allocator)
                    delete(self.columns, db.allocator)
                    for &col in self.arch_columns.items do if col.rows != nil do delete(col.rows, db.allocator)
                    if self.arch_columns.items != nil do oc.dense_arr__terminate(&self.arch_columns, db.allocator)
                    delete(self.tid_to_cid, db.allocator)
                    if self.excludes.items != nil do oc.dense_arr__terminate(&self.excludes, db.allocator)
                    if self.any_of.items != nil do oc.dense_arr__terminate(&self.any_of, db.allocator)
                    delete(self.tables, db.allocator)
                    return aerr
                }
            }
        }

        self.dense_cols = make([]View_Dense_State, tables_len, db.allocator) or_return

        self.eid_to_rid = make([]view_record_id, db.overbase.id_factory.cap, db.allocator) or_return
        self.rid_to_eid = make([]entity_id, self.cap + 1, db.allocator) or_return

        self.len = 0
        self.state = Object_State.Normal

        view__clear(self) or_return

        //
        // Attach to db
        //
        {
            id, aerr := database__attach_view(db, self)
            if aerr != nil {
                for &col in self.columns do if col.rows != nil do delete(col.rows, db.allocator)
                delete(self.columns, db.allocator)
                for &col in self.arch_columns.items do if col.rows != nil do delete(col.rows, db.allocator)
                if self.arch_columns.items != nil do oc.dense_arr__terminate(&self.arch_columns, db.allocator)
                delete(self.dense_cols, db.allocator)
                delete(self.eid_to_rid, db.allocator)
                delete(self.rid_to_eid, db.allocator)
                delete(self.tid_to_cid, db.allocator)
                if self.excludes.items != nil do oc.dense_arr__terminate(&self.excludes, db.allocator)
                if self.any_of.items != nil do oc.dense_arr__terminate(&self.any_of, db.allocator)
                delete(self.tables, db.allocator)
                return aerr
            }
            self.id = id
        }

        //
        // Subscribe to tables
        //
        for table in uniq_tables {
            serr := shared_table__attach_subscriber(table, self)
            if serr != nil {
                view__terminate(self)
                return serr
            }
        }
        for table in self.excludes.items {
            serr := shared_table__attach_exclude_subscriber(table, self)
            if serr != nil {
                view__terminate(self)
                return serr
            }
        }
        for table in self.any_of.items {
            serr := shared_table__attach_any_of_subscriber(table, self)
            if serr != nil {
                view__terminate(self)
                return serr
            }
        }

        return nil
    }

    view__terminate :: proc(self: ^View) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

        for table in self.tables {
            if table == nil || table.type == Table_Type.Auto do continue
            derr := shared_table__detach_subscriber(table, self)
            if derr != nil && derr != oc.Core_Error.Not_Found do return derr
        }
        for table in self.excludes.items {
            if table == nil || table.type == Table_Type.Auto do continue
            derr := shared_table__detach_exclude_subscriber(table, self)
            if derr != nil && derr != oc.Core_Error.Not_Found do return derr
        }
        for table in self.any_of.items {
            if table == nil || table.type == Table_Type.Auto do continue
            derr := shared_table__detach_any_of_subscriber(table, self)
            if derr != nil && derr != oc.Core_Error.Not_Found do return derr
        }

        for &col in self.columns {
            if col.rows != nil do delete(col.rows, self.db.allocator) or_return
        }
        if self.columns != nil do delete(self.columns, self.db.allocator) or_return
        for &col in self.arch_columns.items {
            if col.rows != nil do delete(col.rows, self.db.allocator) or_return
        }
        if self.arch_columns.items != nil do oc.dense_arr__terminate(&self.arch_columns, self.db.allocator) or_return
        if self.dense_cols != nil do delete(self.dense_cols, self.db.allocator) or_return
        if self.tid_to_cid != nil do delete(self.tid_to_cid, self.db.allocator) or_return
        if self.eid_to_rid != nil do delete(self.eid_to_rid, self.db.allocator) or_return
        if self.rid_to_eid != nil do delete(self.rid_to_eid, self.db.allocator) or_return
        if self.tables != nil do delete(self.tables, self.db.allocator) or_return

        if self.excludes.items != nil do oc.dense_arr__terminate(&self.excludes, self.db.allocator) or_return
        if self.any_of.items != nil do oc.dense_arr__terminate(&self.any_of, self.db.allocator) or_return

        database__detach_view(self.db, self)

        self.tables = nil
        self.tid_to_cid = nil
        self.columns = nil
        self.dense_cols = nil
        self.eid_to_rid = nil
        self.rid_to_eid = nil
        self.bits = {}
        self.exclude_bits = {}
        self.any_of_bits = {}
        self.filter = nil
        self.len = 0
        self.cap = 0
        self.db = nil

        self.state = Object_State.Not_Initialized
        return nil
    }

    view__clear :: proc(self: ^View) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.eid_to_rid != nil do slice.fill(self.eid_to_rid, VIEW_NO_RID)

        self.len = 0

        #no_bounds_check for &col, cid in self.dense_cols {
            col = self.tables[cid].type == Table_Type.Table ? View_Dense_State.Aligned : View_Dense_State.Misaligned
        }
        self.dense_state = View_Dense_State.Aligned

        self.stale = false

        return nil
    }

    view__rebuild :: proc(self: ^View) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.tables != nil)
        }

        view__clear(self) or_return

        min_records_count: int = max(int)
        min_table: ^Shared_Table
        for table in self.tables {
            table_len := shared_table__len(table)
            if table_len < min_records_count {
                min_table = table
                min_records_count = table_len
            }
        }

        min_eids := shared_table__rid_to_eid_slice(min_table)
        assert(self.cap >= len(min_eids))

        for eid in min_eids {
            if is_not_set(eid) do continue

            if view__components_match(self, eid) {
                view__add_record(self, eid) or_return
            }
        }

        return nil
    }

    view__len :: #force_inline proc "contextless" (self: ^View) -> int {
        return self.len
    }

    view__cap :: #force_inline proc "contextless" (self: ^View) -> int { return self.cap }

    view__memory_usage :: proc(self: ^View) -> int {
        total := size_of(self^)

        total += oc.dense_arr__memory_usage(&self.excludes)
        total += oc.dense_arr__memory_usage(&self.any_of)

        if self.tid_to_cid != nil do total += size_of(self.tid_to_cid[0]) * len(self.tid_to_cid)
        if self.eid_to_rid != nil do total += size_of(self.eid_to_rid[0]) * len(self.eid_to_rid)
        if self.rid_to_eid != nil do total += size_of(self.rid_to_eid[0]) * len(self.rid_to_eid)
        if self.dense_cols != nil do total += size_of(self.dense_cols[0]) * len(self.dense_cols)
        if self.tables != nil do total += size_of(self.tables[0]) * len(self.tables)

        for col in self.columns {
            total += size_of(View_Column) + size_of(rawptr) * len(col.rows)
        }

        total += oc.dense_arr__memory_usage(&self.arch_columns)
        for col in self.arch_columns.items {
            total += size_of(rawptr) * len(col.rows)
        }

        return total
    }

    view__components_match :: #force_inline proc(self: ^View, eid: entity_id) -> bool {
        bits := &self.db.eid_to_bits[eid.ix]

        return uni_bits__is_subset(&self.bits, bits) &&
               uni_bits__no_intersection(&self.exclude_bits, bits) &&
               (oc.dense_arr__len(&self.any_of) == 0 || uni_bits__intersects(&self.any_of_bits, bits)) &&
               (!self.db.has_disabled_components || uni_bits__no_intersection(&self.bits, &self.db.eid_to_disabled_bits[eid.ix]))
    }

    view__filter_match :: proc(self: ^View, eid: entity_id) -> bool {
        if self == nil do return false
        if self.filter == nil do return true

        rid := self.eid_to_rid[eid.ix]
        if rid == VIEW_NO_RID {
            view__fill_columns(self, eid, self.cap)
            return view__filter_match_private(self, self.cap)
        }
        return view__filter_match_private(self, int(rid))
    }

    view__rerun_filter :: proc(self: ^View, eid: entity_id) -> Error {
        if !view__components_match(self, eid) do return nil

        return view__rerun_filter_private(self, eid)
    }

    view__refilter :: proc(self: ^View) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.filter == nil do return nil

        for i := self.len - 1; i >= 0; i -= 1 {
            if !view__filter_match_private(self, i) {
                view__remove_record_by_row(self, i)
            }
        }

        min_records_count: int = max(int)
        min_table: ^Shared_Table
        for table in self.tables {
            table_len := shared_table__len(table)
            if table_len < min_records_count {
                min_table = table
                min_records_count = table_len
            }
        }

        for eid in shared_table__rid_to_eid_slice(min_table) {
            if is_not_set(eid) do continue
            if self.eid_to_rid[eid.ix] != VIEW_NO_RID do continue
            if !view__components_match(self, eid) do continue

            view__fill_columns(self, eid, self.cap)
            if view__filter_match_private(self, self.cap) {
                view__add_record_prefilled(self, eid) or_return
            }
        }

        return nil
    }

    view__suspend :: proc(self: ^View) {
        when VALIDATIONS {
            assert(self != nil)
        }
        self.suspended = true
    }

    view__resume :: proc(self: ^View) {
        when VALIDATIONS {
            assert(self != nil)
        }
        self.suspended = false

        view__dense_degrade_to_unknown(self)
    }

    view__column_slice :: proc(self: ^View, $T: typeid) -> []^T {
        for &col in self.columns {
            if col.type_info != nil && col.type_info.id == typeid_of(T) {
                return transmute([]^T) col.rows[:self.len]
            }
        }
        for &col in self.arch_columns.items {
            if col.type_info.id == typeid_of(T) {
                return transmute([]^T) col.rows[:self.len]
            }
        }
        when VALIDATIONS {
            assert(false, "View has no column of type T")
        }
        return nil
    }

    view__entities_slice :: #force_inline proc "contextless" (self: ^View) -> []entity_id {
        return self.rid_to_eid[:self.len]
    }

    // Real contiguous []T straight off `table.rows`, no per-row pointer-cache indirection — nil
    // if `table`'s rows aren't currently aligned to the view's row order (or the view is
    // suspended). Cheaper than view__column_slice(view, T) when it succeeds, but callers must
    // handle the nil case (fall back to view__column_slice, or skip this table this frame).
    view__try_dense_slice :: proc(self: ^View, table: ^Table($T)) -> []T {
        cid := self.tid_to_cid[table.id]
        when VALIDATIONS {
            assert(cid != DELETED_INDEX)
        }

        view__dense_resolve(self)
        if self.suspended || self.dense_cols[cid] != View_Dense_State.Aligned do return nil

        return table.rows[:self.len]
    }

    @(private)
    view__auto_register_arch_columns :: proc(self: ^View, table: ^Arch_Table) -> Error {
        if self.arch_columns.items == nil {
            oc.dense_arr__init(&self.arch_columns, len(table.columns), self.db.allocator) or_return
        }

        self.columns[self.tid_to_cid[table.id]].arch_base = len(self.arch_columns.items)

        for arch_col, col_idx in table.columns {
            new_col: Arch_View_Column
            new_col.table = table
            new_col.col_idx = col_idx
            new_col.type_info = arch_col.type_info
            new_col.rows = make([]rawptr, self.cap + 1, self.db.allocator) or_return

            oc.dense_arr__add_growing(&self.arch_columns, new_col, self.db.allocator) or_return
        }

        return nil
    }

    view__get_component_for_table :: #force_inline proc "contextless" (self: ^View, rec: ^View_Row, table: ^Table($T)) -> ^T {
        #no_bounds_check {
            return cast(^T) rec.view.columns[rec.view.tid_to_cid[table.id]].rows[rec.row_ix]
        }
    }

    view__get_component_for_compact_table :: #force_inline proc "contextless" (self: ^View, rec: ^View_Row, table: ^Compact_Table($T)) -> ^T {
        #no_bounds_check {
            return cast(^T) rec.view.columns[rec.view.tid_to_cid[table.id]].rows[rec.row_ix]
        }
    }

    view__get_component_for_tiny_table :: #force_inline proc "contextless" (self: ^View, rec: ^View_Row, table: ^Tiny_Table($T)) -> ^T {
        #no_bounds_check {
            return cast(^T) rec.view.columns[rec.view.tid_to_cid[table.id]].rows[rec.row_ix]
        }
    }

    view__get_component_for_arch_table :: #force_inline proc "contextless" (self: ^View, rec: ^View_Row, table: ^Arch_Table, $T: typeid) -> ^T {
        #no_bounds_check {
            col_idx := arch_table__column_index(table, typeid_of(T))
            if col_idx < 0 do return nil
            base := rec.view.columns[rec.view.tid_to_cid[table.id]].arch_base
            return cast(^T) rec.view.arch_columns.items[base + col_idx].rows[rec.row_ix]
        }
    }

///////////////////////////////////////////////////////////////////////////////
// View_Row

    View_Row :: struct {
        view: ^View,
        row_ix: int,
    }

    view_row__get_component_for_table :: #force_inline proc "contextless" (table: ^Table($T), view_row: ^View_Row) -> ^T #no_bounds_check {
        return view__get_component_for_table(view_row.view, view_row, table)
    }

    view_row__get_component_for_compact_table :: #force_inline proc "contextless" (table: ^Compact_Table($T), view_row: ^View_Row) -> ^T #no_bounds_check {
        return view__get_component_for_compact_table(view_row.view, view_row, table)
    }

    view_row__get_component_for_tiny_table :: #force_inline proc "contextless" (table: ^Tiny_Table($T), view_row: ^View_Row) -> ^T #no_bounds_check {
        return view__get_component_for_tiny_table(view_row.view, view_row, table)
    }

    view_row__get_component_for_arch_table :: #force_inline proc "contextless" (table: ^Arch_Table, view_row: ^View_Row, $T: typeid) -> ^T #no_bounds_check {
        return view__get_component_for_arch_table(view_row.view, view_row, table, T)
    }

    view_row__get_entity :: #force_inline proc "contextless" (self: ^View_Row) -> entity_id {
        return self.view.rid_to_eid[self.row_ix]
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    view__fill_columns :: proc(self: ^View, eid: entity_id, #any_int row_ix: int) #no_bounds_check {
        self.rid_to_eid[row_ix] = eid

        for table, cid in self.tables {
            switch table.type {
                case Table_Type.Auto:
                    self.columns[cid].rows[row_ix] = nil
                case Table_Type.Table:
                    self.columns[cid].rows[row_ix] = table_raw__get_component_by_entity(cast(^Table_Raw) table, eid)
                case Table_Type.Compact_Table:
                    self.columns[cid].rows[row_ix] = compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) table, eid)
                case Table_Type.Tiny_Table:
                    self.columns[cid].rows[row_ix] = tiny_table_base__get_component_by_entity(cast(^Tiny_Table_Base) table, eid)
                case Table_Type.Tag_Table:
                    self.columns[cid].rows[row_ix] = nil
                case Table_Type.Arch_Table:
                    self.columns[cid].rows[row_ix] = rawptr(uintptr((cast(^Arch_Table) table).eid_to_rid[eid.ix]))
            }
        }

        for &col in self.arch_columns.items {
            rid := col.table.eid_to_rid[eid.ix]
            col.rows[row_ix] = rid == ARCH_TABLE_NO_RID ? nil : arch_table__component_rawptr_by_col(col.table, rid, col.col_idx)
        }
    }

    @(private)
    view__filter_match_private :: proc(self: ^View, #any_int row_ix: int) -> bool {
        if self.filter == nil do return true
        row := View_Row{view = self, row_ix = row_ix}
        return self.filter(&row, self.user_data)
    }

    @(private)
    view__missed_update_for_member :: #force_inline proc "contextless" (self: ^View, eid: entity_id) #no_bounds_check {
        when VALIDATIONS {
            if self.eid_to_rid[eid.ix] != VIEW_NO_RID do self.stale = true
        }
    }

    @(private)
    view__add_record :: proc(self: ^View, eid: entity_id, use_filter := true) -> Error #no_bounds_check {
        if self.len >= self.cap do return API_Error.Cannot_Add_Record_To_View_Container_Is_Full
        if self.eid_to_rid[eid.ix] != VIEW_NO_RID do return oc.Core_Error.Already_Exists

        if use_filter && self.filter != nil {
            view__fill_columns(self, eid, self.cap)
            if !view__filter_match_private(self, self.cap) do return nil
            return view__add_record_prefilled(self, eid)
        }

        row_ix := self.len
        self.eid_to_rid[eid.ix] = cast(view_record_id) row_ix
        self.rid_to_eid[row_ix] = eid
        view__fill_columns(self, eid, row_ix)
        view__dense_check_row_degrade(self, row_ix)
        self.len += 1

        return nil
    }

    @(private)
    view__add_record_prefilled :: proc(self: ^View, eid: entity_id) -> Error #no_bounds_check {
        if self.len >= self.cap do return API_Error.Cannot_Add_Record_To_View_Container_Is_Full
        if self.eid_to_rid[eid.ix] != VIEW_NO_RID do return oc.Core_Error.Already_Exists

        row_ix := self.len
        self.eid_to_rid[eid.ix] = cast(view_record_id) row_ix
        self.rid_to_eid[row_ix] = eid
        for &col in self.columns do col.rows[row_ix] = col.rows[self.cap]
        for &col in self.arch_columns.items do col.rows[row_ix] = col.rows[self.cap]
        view__dense_check_row_degrade(self, row_ix)
        self.len += 1

        return nil
    }

    @(private)
    view__remove_record :: proc(self: ^View, eid: entity_id) #no_bounds_check {
        if self.len <= 0 do return

        rid := self.eid_to_rid[eid.ix]
        if rid == VIEW_NO_RID do return

        view__remove_record_by_row(self, int(rid))
    }

    @(private)
    view__remove_record_by_row :: proc(self: ^View, dest_row_ix: int) {
        src_row_ix := self.len - 1

        dest_eid := self.rid_to_eid[dest_row_ix]
        src_eid := self.rid_to_eid[src_row_ix]

        if dest_row_ix != src_row_ix {
            for &col in self.columns do col.rows[dest_row_ix] = col.rows[src_row_ix]
            for &col in self.arch_columns.items do col.rows[dest_row_ix] = col.rows[src_row_ix]

            self.rid_to_eid[dest_row_ix] = src_eid
            self.eid_to_rid[src_eid.ix] = self.eid_to_rid[dest_eid.ix]

            view__dense_degrade_to_unknown(self)
        }

        for &col in self.columns do col.rows[src_row_ix] = nil
        for &col in self.arch_columns.items do col.rows[src_row_ix] = nil
        self.rid_to_eid[src_row_ix].ix = DELETED_INDEX
        self.rid_to_eid[src_row_ix].gen = 0

        self.eid_to_rid[dest_eid.ix] = VIEW_NO_RID
        self.len -= 1
    }

    @(private)
    view__rerun_filter_private :: proc(self: ^View, eid: entity_id) -> Error {
        rid := self.eid_to_rid[eid.ix]

        if rid == VIEW_NO_RID {
            view__fill_columns(self, eid, self.cap)
            if view__filter_match_private(self, self.cap) {
                view__add_record_prefilled(self, eid) or_return
            }
        } else {
            if !view__filter_match_private(self, int(rid)) {
                view__remove_record(self, eid)
            }
        }

        return nil
    }

    @(private)
    view__update_component_ptr :: proc(self: ^View, table: ^Shared_Table, eid: entity_id, ptr: rawptr) -> Error {
        cid := self.tid_to_cid[table.id]
        when VALIDATIONS {
            assert(cid != DELETED_INDEX)
        }

        if self.eid_to_rid[eid.ix] == VIEW_NO_RID do return oc.Core_Error.Not_Found
        row_ix := int(self.eid_to_rid[eid.ix])
        #no_bounds_check {
            self.columns[cid].rows[row_ix] = ptr
        }

        #no_bounds_check {
            col := &self.dense_cols[cid]
            if col^ == View_Dense_State.Aligned && table.type == Table_Type.Table {
                raw := cast(^Table_Raw) table
                expected := table_raw__rid_to_ptr_sized(raw, row_ix, raw.type_info.size)
                if ptr != expected do col^ = View_Dense_State.Misaligned
            }
        }

        return nil
    }

    @(private)
    view__update_component_rid :: proc(self: ^View, table: ^Shared_Table, eid: entity_id, #any_int rid: int) -> Error {
        cid := self.tid_to_cid[table.id]
        when VALIDATIONS {
            assert(cid != DELETED_INDEX)
        }

        if self.eid_to_rid[eid.ix] == VIEW_NO_RID do return oc.Core_Error.Not_Found
        row_ix := int(self.eid_to_rid[eid.ix])
        #no_bounds_check {
            self.columns[cid].rows[row_ix] = rawptr(uintptr(rid))
        }

        #no_bounds_check {
            if table.type == Table_Type.Arch_Table {
                at := cast(^Arch_Table) table
                base := self.columns[cid].arch_base
                for i in 0..<len(at.columns) {
                    col := &self.arch_columns.items[base + i]
                    col.rows[row_ix] = arch_table__component_rawptr_by_col(at, rid, col.col_idx)
                }
            }
        }

        return nil
    }

    @(private)
    view__dense_check_row_degrade :: proc(self: ^View, row_ix: int) {
        #no_bounds_check {
            for &col, cid in self.dense_cols {
                if col != View_Dense_State.Aligned do continue
                raw := cast(^Table_Raw) self.tables[cid]
                expected := table_raw__rid_to_ptr_sized(raw, row_ix, raw.type_info.size)
                if self.columns[cid].rows[row_ix] != expected {
                    col = View_Dense_State.Misaligned
                }
            }
        }
    }

    @(private)
    view__dense_degrade_to_unknown :: #force_inline proc "contextless" (self: ^View) {
        for &col in self.dense_cols {
            if col == View_Dense_State.Aligned do col = View_Dense_State.Unknown
        }
    }

    @(private)
    view__dense_col_rescan :: proc(self: ^View, #any_int cid: int) -> bool {
        #no_bounds_check if self.tables[cid].type != Table_Type.Table do return false

        raw := cast(^Table_Raw) self.tables[cid]
        #no_bounds_check {
            for r := 0; r < self.len; r += 1 {
                expected := table_raw__rid_to_ptr_sized(raw, r, raw.type_info.size)
                if self.columns[cid].rows[r] != expected do return false
            }
        }
        return true
    }

    @(private)
    view__dense_resolve :: proc(self: ^View) -> bool {
        all_aligned := true
        #no_bounds_check for &col, cid in self.dense_cols {
            if self.tables[cid].type != Table_Type.Table do continue
            if col == View_Dense_State.Unknown {
                col = view__dense_col_rescan(self, cid) ? View_Dense_State.Aligned : View_Dense_State.Misaligned
            }
            if col != View_Dense_State.Aligned do all_aligned = false
        }

        self.dense_state = all_aligned ? View_Dense_State.Aligned : View_Dense_State.Misaligned

        return all_aligned && !self.suspended
    }

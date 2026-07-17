/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"
    
// Core
    import "core:slice"
    import "core:mem"

// ODE
    import oc "ode_core"


///////////////////////////////////////////////////////////////////////////////
// View_Row_Raw - raw data of the row

    View_Row_Raw :: struct {
        eid: entity_id,
        refs: [1] rawptr, // at least one component
    } 

    @(private)
    // #no_bounds_check: eid validated upstream; refs has one slot per column
    view_row_raw__fill :: proc (self: ^View_Row_Raw, view: ^View, eid: entity_id) #no_bounds_check {
        self.eid = eid

        // cid equals the column's position in view.tables.items by construction
        // (view__init sets tid_to_cid[table.id] = index), so no lookup is needed
        for table, cid in view.tables.items {
            if table.type == Table_Type.Table {
                // devirtualized fast path for the most common column type
                self.refs[cid] = table_raw__get_component_by_entity(cast(^Table_Raw) table, eid)
            } else {
                self.refs[cid] = shared_table__get_component(table, eid)
            }
        }
    }

    @(private)
    view_row_raw__clear :: #force_inline proc (self: ^View_Row_Raw, view: ^View) {
        mem.zero(self, view.one_record_size)
        self.eid.ix = DELETED_INDEX
    }

///////////////////////////////////////////////////////////////////////////////
// View_Row - wrapper around View_Row_Raw, used in View filter proc and Iterator
// 

    View_Row :: struct {
        view: ^View,
        raw: ^View_Row_Raw,
    }

    @(private)
    view_row__get_component_for_table :: #force_inline proc "contextless" (table: ^Table($T), view_row: ^View_Row) -> ^T #no_bounds_check {
        #no_bounds_check {
            return (^T)(view_row.raw.refs[view_row.view.tid_to_cid[table.id]])
        }
    }

    @(private)
    view_row__get_component_for_small_table :: #force_inline proc "contextless" (table: ^Compact_Table($T), view_row: ^View_Row) -> ^T #no_bounds_check {
        #no_bounds_check {
            return (^T)(view_row.raw.refs[view_row.view.tid_to_cid[table.id]])
        }
    }

    @(private)
    view_row__get_component_for_tiny_table :: #force_inline proc "contextless" (table: ^Tiny_Table($T), view_row: ^View_Row) -> ^T #no_bounds_check {
        #no_bounds_check {
            return (^T)(view_row.raw.refs[view_row.view.tid_to_cid[table.id]])
        }
    }

    @(private)
    view_row__get_entity :: #force_inline proc "contextless" (self: ^View_Row) -> entity_id {
        return self.raw.eid
    }

///////////////////////////////////////////////////////////////////////////////
// View
//

    // Dense (aligned) fast path state.
    //
    // A column is "aligned" when, for its Table (not Compact_Table/Tiny_Table/Tag_Table),
    // view row `r` references exactly `table.rows[r]`. When that holds, Iterator reads
    // that column's components directly from the table's dense array and skips the
    // per-row pointer records (~3x faster reads). Alignment is tracked per column, so
    // one misaligned table (or a Compact/Tiny/Tag column) doesn't push the other
    // columns onto the pointer path.
    //
    // The state is maintained incrementally: appends verify the new row in O(tables),
    // a non-tail removal degrades still-aligned columns to Unknown, and Unknown is
    // resolved by an early-abort per-column rescan on the next iterator_init/
    // iterator_reset. Tables with identical membership stay aligned even under
    // tail-swap churn, so this fast path survives despawn/respawn workloads.
    View_Dense_State :: enum u8 {
        Unknown = 0,    // needs rescan (resolved lazily on iterator init/reset)
        Aligned,
        Misaligned,     // sticky until view__clear/view__rebuild
    }

    View_Dense_Col :: struct {
        base: uintptr,   // &table.rows[0]
        stride: uintptr, // size_of(T), or 0 when the column is not a Table
        // Invariant: state == Aligned implies stride != 0 (non-Table columns are kept
        // Misaligned by view__clear/view__dense_resolve and never take the dense path).
        state: View_Dense_State,
    }

    View :: struct {
        id: view_id,
        state: Object_State,
        db: ^Database,
        tables: oc.Dense_Arr(^Shared_Table), // includes tables, removing table invalidates View
        excludes: oc.Dense_Arr(^Shared_Table), // excluded tables (see view__init), removing table invalidates View

        tid_to_cid: []view_column_id,  
        eid_to_ptr: []view_record_id, // currently its actually eid_to_rid, might be changed to eid_to_ptr in future
        
        rows: []byte,  // tail swap, order doesn't matter here
        one_record_size: int, 
        records_size: int,
        tables_len: int, 

        cap: int,

        bits: Uni_Bits,
        exclude_bits: Uni_Bits, // tables whose entities must NOT be in this view
        suspended: bool,

        // Whole-view summary of the per-column states, refreshed by view__dense_resolve
        // (iterator init/reset). Aligned only when every Table column is aligned.
        dense_state: View_Dense_State,

        // Per-column dense-alignment state and constants, indexed by cid. base/stride are
        // valid for the view's lifetime: a Table's rows array is allocated once at
        // table_init (fixed cap) and never reallocates. stride == 0 marks columns that
        // never take part in the dense fast path (Compact_Table/Tiny_Table/Tag_Table).
        dense_cols: []View_Dense_Col,

        filter: proc(row: ^View_Row, user_data: rawptr)->bool, 
        user_data: rawptr, 
        temp_row: ^View_Row_Raw, // used to filter, pointed to reserved row at the end of rows array
    }

    // Is view valid and ready to use (initialized and everything is ok)
    view__is_valid :: proc(self: ^View) -> bool {
        if self == nil do return false 
        if self.id < 0 do return false 
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if !oc.dense_arr__is_valid(&self.tables) do return false 
        if self.tid_to_cid == nil do return false 
        if self.eid_to_ptr == nil do return false
        if self.rows == nil do return false
        if self.one_record_size <= 0 do return false 
        if self.cap <= 0 do return false 

        return true
    }

    // `includes` — an entity must have a component in every one of these tables to be
    // in the view; they become the view's columns.
    // `excludes` — an entity must have a component in none of these tables; they are
    // not columns (no component data is read from them), membership only. Cheaper and
    // auto-maintained, unlike a `filter` proc doing the same check.
    view__init :: proc(
        self: ^View,
        db: ^Database,
        includes: []^Shared_Table,
        filter: proc(row: ^View_Row, user_data: rawptr = nil)->bool = nil,
        excludes: []^Shared_Table = nil,
        loc := #caller_location
    ) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
        }

        if includes == nil || len(includes) <= 0 do return API_Error.Tables_Array_Should_Not_Be_Empty

        // A re-init'd struct (issue #8) may carry bits/suspended/excludes from its
        // previous life; terminate does not reset them.
        uni_bits__clear(&self.bits)
        uni_bits__clear(&self.exclude_bits)
        self.excludes = {}
        self.suspended = false

        self.db = db

        // Store filter
        self.filter = filter

        // Make sure we do not have repeating columns (copmonent typse/tables).
        // Sort a copy — the caller's slice must not be mutated.
        sorted_includes := slice.clone(includes, db.allocator) or_return
        defer delete(sorted_includes, db.allocator)
        slice.sort(sorted_includes)
        uniq_tables := slice.unique(sorted_includes)
        self.tables_len = len(uniq_tables)

        // Dedupe + validate excludes before anything below allocates, so an error
        // here leaves nothing to free.
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

        oc.dense_arr__init(&self.tables, self.tables_len, db.allocator) or_return

        // max table id
        max_table_id: int = -1
        for table in uniq_tables {
            if int(table.id) > max_table_id do max_table_id = int(table.id)
        }

        //
        // tid_to_cid
        //
        self.tid_to_cid = make([]view_column_id, max_table_id + 1, db.allocator) or_return
        for i := 0; i < len(self.tid_to_cid); i+=1 do self.tid_to_cid[i] = DELETED_INDEX

        // by definition cap of view is limited by the smallest table capacity
        self.cap = max(int)
        for table, index in uniq_tables {
            when VALIDATIONS {
                assert(shared_table__is_valid(table), loc = loc)
            }

            oc.dense_arr__add(&self.tables, cast(^Shared_Table) table)

            if shared_table__cap(table) < self.cap {
                self.cap = shared_table__cap(table)
            }

            self.tid_to_cid[table.id] = cast(view_column_id)index

            uni_bits__add(&self.bits, table.id)
        }

        //
        // excludes (not columns — membership only, so cap/tid_to_cid/rows are untouched)
        //
        if len(uniq_excludes) > 0 {
            oc.dense_arr__init(&self.excludes, len(uniq_excludes), db.allocator) or_return

            for table in uniq_excludes {
                oc.dense_arr__add(&self.excludes, cast(^Shared_Table) table)
                uni_bits__add(&self.exclude_bits, table.id)
            }
        }

        //
        // dense_cols
        //
        self.dense_cols = make([]View_Dense_Col, self.tables_len, db.allocator) or_return
        for table, index in uniq_tables {
            if table.type == Table_Type.Table {
                tr := cast(^Table_Raw) table
                self.dense_cols[index] = { base = uintptr(raw_data(tr.rows)), stride = uintptr(tr.type_info.size) }
            }
        }

        //
        // eid_to_ptr
        //
        self.eid_to_ptr = make([]view_record_id, db.id_factory.cap, db.allocator) or_return
        
        //
        // rows
        //
        self.one_record_size = size_of(View_Row_Raw) + (self.tables_len - 1) * size_of(rawptr)  // -1 because one is already in struct
        self.records_size = (self.cap + 1) * self.one_record_size // +1 so we can use cap index row as temp row for filter match

        raw := (^runtime.Raw_Slice)(&self.rows)

        raw.data = mem.alloc(self.records_size, allocator = db.allocator) or_return
        raw.len = 0

        // Temp row is the last row in rows array
        self.temp_row = view__get_row_private(self, self.cap) // remember we allocated cap + 1 rows

        // State
        self.state = Object_State.Normal

        // Clear 
        view__clear(self) or_return

        //
        // Attach to db
        //
        self.id = database__attach_view(db, self) or_return

        //
        // Subscribe to tables
        //
        for table in uniq_tables do shared_table__attach_subscriber(table, self) or_return
        for table in self.excludes.items do shared_table__attach_exclude_subscriber(table, self) or_return

        return nil
    }
    
    view__terminate :: proc(self: ^View) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

        //
        // Unsubscribe from tables first, so a failure here doesn't strand a
        // half-freed view. Tables that were already terminated dropped their
        // subscriber lists (type is reset to Unknown) — skip them.
        //
        for table in self.tables.items {
            if table == nil || table.type == Table_Type.Unknown do continue
            derr := shared_table__detach_subscriber(table, self)
            if derr != nil && derr != oc.Core_Error.Not_Found do return derr
        }

        for table in self.excludes.items {
            if table == nil || table.type == Table_Type.Unknown do continue
            derr := shared_table__detach_exclude_subscriber(table, self)
            if derr != nil && derr != oc.Core_Error.Not_Found do return derr
        }

        // rows was allocated as one records_size block; its slice len holds the
        // row count, so delete() would free with the wrong size.
        if self.rows != nil {
            mem.free_with_size((^runtime.Raw_Slice)(&self.rows).data, self.records_size, self.db.allocator) or_return
            self.rows = nil
        }
        delete(self.eid_to_ptr, self.db.allocator) or_return
        delete(self.tid_to_cid, self.db.allocator) or_return
        delete(self.dense_cols, self.db.allocator) or_return
        self.dense_cols = nil

        oc.dense_arr__terminate(&self.tables, self.db.allocator) or_return
        if self.excludes.items != nil do oc.dense_arr__terminate(&self.excludes, self.db.allocator) or_return

        //
        // Detach from db
        //
        database__detach_view(self.db, self)

        // Leave the view in Not_Initialized state (not Terminated) so the same
        // struct can be re-init'd without zeroing it first. See issue #8.
        self.state = Object_State.Not_Initialized
        return nil
    }

    view__clear :: proc(self: ^View) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.eid_to_ptr != nil {
            for i := 0; i < len(self.eid_to_ptr); i+=1 do self.eid_to_ptr[i] = DELETED_INDEX
        }

        if len(self.rows) > 0 {
            mem.zero((^runtime.Raw_Slice)(&self.rows).data, len(self.rows) * self.one_record_size)
            (^runtime.Raw_Slice)(&self.rows).len = 0
        }

        // empty view is trivially aligned; non-Table columns never align
        for &col in self.dense_cols {
            col.state = col.stride != 0 ? View_Dense_State.Aligned : View_Dense_State.Misaligned
        }
        self.dense_state = View_Dense_State.Aligned

        return nil
    }

    // Rebuild view and fill it with entities matching view's tables
    view__rebuild :: proc(self: ^View) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.tables.items != nil)
        }
        
        view__clear(self) or_return 

        min_records_count: int = max(int)
        min_table: ^Shared_Table
        for table in self.tables.items {
            if shared_table__len(table) < min_records_count {
                min_table = table
                min_records_count = shared_table__len(table)
            }
        }

        eid: entity_id
        min_table_col_ix := self.tid_to_cid[min_table.id]
        assert(self.cap >= shared_table__len(min_table))

        for i:= 0; i < shared_table__len(min_table); i+=1 {
            eid = shared_table__get_entity_by_row_number(min_table, i)
            if is_deleted(eid) do continue // hole (removal while tail swap was paused)

            // check if view bits is subset of entity bits
            if view_entity_match(self, eid) {
                view__add_record(self, eid) or_return
            }
        }

        return nil
    }
    
    // Number of records(rows) in view
    view__len :: #force_inline proc "contextless" (self: ^View) -> int {
        return (^runtime.Raw_Slice)(&self.rows).len
    }
   
    // Maximum number of records of view
    view__cap :: #force_inline proc "contextless" (self: ^View) -> int { return self.cap }

    // View memory usage in bytes
    view__memory_usage :: proc (self: ^View) -> int { 
        total := size_of(self^)

        total += oc.dense_arr__memory_usage(&self.tables)
        total += oc.dense_arr__memory_usage(&self.excludes)

        if self.tid_to_cid != nil {
            total += size_of(self.tid_to_cid[0]) * len(self.tid_to_cid)
        }

        if self.eid_to_ptr != nil {
            total += size_of(self.eid_to_ptr[0]) * len(self.eid_to_ptr)
        }

        if self.rows != nil {
            total += self.one_record_size * (self.cap + 1) // +1 reserved temp row, see view__init
        }

        if self.dense_cols != nil {
            total += size_of(self.dense_cols[0]) * len(self.dense_cols)
        }

        return total
    }

    // Returns true if entity has components that would match this view (all included
    // tables, no excluded table), doesn't check filter
    view__components_match :: #force_inline proc (self: ^View, eid: entity_id) -> bool {
        return uni_bits__is_subset(&self.bits, &self.db.eid_to_bits[eid.ix]) &&
               uni_bits__no_intersection(&self.exclude_bits, &self.db.eid_to_bits[eid.ix])
    }

    view__filter_match :: proc(self: ^View, eid: entity_id) -> bool {
        if self == nil do return false
        if self.filter == nil do return true

        rid := self.eid_to_ptr[eid.ix]
        if rid == DELETED_INDEX {
            if self.temp_row == nil do return false // something is wrong, should not happen 
            view_row_raw__fill(self.temp_row, self, eid)
            return view__filter_match_private(self, self.temp_row)

        } else {
            row_raw := view__get_row(self, rid)
            if row_raw == nil do return false // something is wrong, should not happen

            return view__filter_match_private(self, row_raw)
        }

        return false
    }

    // Rerun filter for an entity
    view__rerun_filter :: proc(self: ^View, eid: entity_id) -> Error {
        if !view__components_match(self, eid) do return nil // do not consider it an error
                                                            // if components do not match, row had been removed in other way

        return view__rerun_filter_private(self, eid)
    }

    // Re-evaluate the filter for every entity the view could contain, in one sweep:
    // removes rows that stopped matching, adds candidates that now match. Use after
    // bulk component mutations instead of per-entity rerun_views_filters. Unlike
    // rebuild it does not clear the view, so surviving rows keep their positions
    // (and their dense alignment, unless a removal actually moves rows).
    // No-op for a view without a filter — membership is already exact.
    view__refilter :: proc(self: ^View) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.filter == nil do return nil

        // Removals first, backwards: remove_record tail-swaps, so sweeping from the
        // tail never moves an unvisited row into visited territory.
        for i := view_len(self) - 1; i >= 0; i -= 1 {
            record := view__get_row_private(self, i)
            if !view__filter_match_private(self, record) {
                view__remove_record_by_row(self, i, record)
            }
        }

        // Additions: scan the smallest included table (as view__rebuild does) for
        // entities that match components but were previously rejected by the filter.
        min_records_count: int = max(int)
        min_table: ^Shared_Table
        for table in self.tables.items {
            if shared_table__len(table) < min_records_count {
                min_table = table
                min_records_count = shared_table__len(table)
            }
        }

        eid: entity_id
        for i := 0; i < shared_table__len(min_table); i += 1 {
            eid = shared_table__get_entity_by_row_number(min_table, i)
            if is_deleted(eid) do continue // hole (removal while tail swap was paused)
            if self.eid_to_ptr[eid.ix] != DELETED_INDEX do continue // already a member
            if !view_entity_match(self, eid) do continue

            view_row_raw__fill(self.temp_row, self, eid)
            if view__filter_match_private(self, self.temp_row) {
                view__add_record_prefilled(self, eid, self.temp_row) or_return
            }
        }

        return nil
    }

    // Stop updating view when entities are created/destroyed or components/tags are added/removed  
    view__suspend :: proc(self: ^View) {
        when VALIDATIONS {
            assert(self != nil)
        }

        self.suspended = true
    }

    // Resume updating view after calling suspend 
    view__resume :: proc(self: ^View) {
        when VALIDATIONS {
            assert(self != nil)
        }

        self.suspended = false

        // Notifications were skipped while suspended, so alignment can no longer be trusted.
        view__dense_degrade_to_unknown(self)
    }

    view__get_row :: #force_inline proc "contextless" (self: ^View, #any_int index: int) -> ^View_Row_Raw { 
        if index < 0 || index >= view_len(self) do return nil
        return view__get_row_private(self, index)
    }

    view__get_record :: view__get_row // for compatibility, use view__get_row instead, might be removed in future

    // Batch (dense) access: when `table`'s column is dense-aligned, returns
    // `table.rows[:view_len]` — the components of `table` in view-row order, as one contiguous
    // slice. Returns nil when that column is not aligned (or the view is suspended, or `table`
    // is not part of the view); in that case iterate with Iterator as usual. Alignment is per
    // column, so one table of a view may be sliceable while another is not.
    //
    // Slices for different tables of the same view share indexing: slice_a[i] and slice_b[i]
    // belong to the same entity (the entity of view row i). This is the fastest possible way
    // to iterate — a plain loop over these slices compiles to a raw SoA sweep.
    //
    // The slice is invalidated by any structural change (add/remove component, create/destroy
    // entity); do not hold on to it across such changes.
    view__dense_slice :: proc "contextless" (self: ^View, table: ^Table($T)) -> []T {
        if self == nil || table == nil do return nil
        if self.state != Object_State.Normal do return nil
        if int(table.id) < 0 || int(table.id) >= len(self.tid_to_cid) do return nil

        cid := self.tid_to_cid[table.id]
        if cid == DELETED_INDEX do return nil // table is not part of this view

        if !view__dense_resolve_col(self, cid) do return nil

        #no_bounds_check {
            return table.rows[:view_len(self)]
        }
    }

    view__get_component_for_table :: #force_inline proc "contextless" (self: ^View, rec: ^View_Row_Raw, table: ^Table($T)) -> ^T {
        #no_bounds_check {
            return (^T)(rec.refs[self.tid_to_cid[table.id]])
        }
    }

    view__get_component_for_compact_table :: #force_inline proc "contextless" (self: ^View, rec: ^View_Row_Raw, table: ^Compact_Table($T)) -> ^T {
        #no_bounds_check {
            return (^T)(rec.refs[self.tid_to_cid[table.id]])
        }
    }

    view__get_component_for_tiny_table :: #force_inline proc "contextless" (self: ^View, rec: ^View_Row_Raw, table: ^Tiny_Table($T)) -> ^T {
        #no_bounds_check {
            return (^T)(rec.refs[self.tid_to_cid[table.id]])
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    // Verify one view row against each still-aligned column's dense invariant
    // (refs[cid] must be exactly &table.rows[row_ix]) and degrade columns that no
    // longer hold. Non-Table columns are never Aligned, so they are skipped implicitly.
    view__dense_check_row_degrade :: proc "contextless" (self: ^View, record: ^View_Row_Raw, row_ix: int) {
        #no_bounds_check {
            for &col, cid in self.dense_cols {
                if col.state != View_Dense_State.Aligned do continue
                if uintptr(record.refs[cid]) != col.base + uintptr(row_ix) * col.stride {
                    col.state = View_Dense_State.Misaligned
                }
            }
        }
    }

    @(private)
    // A row moved (or notifications were skipped): still-aligned columns can no longer be
    // trusted and need a rescan; Misaligned columns stay sticky.
    view__dense_degrade_to_unknown :: #force_inline proc "contextless" (self: ^View) {
        for &col in self.dense_cols {
            if col.state == View_Dense_State.Aligned do col.state = View_Dense_State.Unknown
        }
    }

    @(private)
    // One column's alignment rescan, aborts on first mismatch. Called lazily
    // (iterator init/reset, view__dense_slice) when the column's state is Unknown.
    view__dense_col_rescan :: proc "contextless" (self: ^View, #any_int cid: int) -> bool {
        col := self.dense_cols[cid]
        if col.stride == 0 do return false

        n := view_len(self)
        addr := col.base
        #no_bounds_check {
            for r := 0; r < n; r += 1 {
                record := view__get_row_private(self, r)
                if uintptr(record.refs[cid]) != addr do return false
                addr += col.stride
            }
        }
        return true
    }

    @(private)
    // Resolve one column's Unknown into Aligned/Misaligned; returns true if that column's
    // dense fast path may be used.
    view__dense_resolve_col :: proc "contextless" (self: ^View, #any_int cid: int) -> bool {
        col := &self.dense_cols[cid]
        if col.state == View_Dense_State.Unknown {
            col.state = view__dense_col_rescan(self, cid) ? View_Dense_State.Aligned : View_Dense_State.Misaligned
        }

        return col.state == View_Dense_State.Aligned && !self.suspended
    }

    @(private)
    // Resolve every column and refresh the aggregate dense_state; returns true when all
    // Table columns are aligned (the whole-view dense fast path may be used).
    view__dense_resolve :: proc "contextless" (self: ^View) -> bool {
        all_aligned := true
        for &col, cid in self.dense_cols {
            if col.stride == 0 do continue
            if col.state == View_Dense_State.Unknown {
                col.state = view__dense_col_rescan(self, cid) ? View_Dense_State.Aligned : View_Dense_State.Misaligned
            }
            if col.state != View_Dense_State.Aligned do all_aligned = false
        }

        self.dense_state = all_aligned ? View_Dense_State.Aligned : View_Dense_State.Misaligned

        return all_aligned && !self.suspended
    }

    @(private)
    view__filter_match_private :: proc(self: ^View, row_raw: ^View_Row_Raw) -> bool {
        if self.filter == nil do return true
        return self.filter(&View_Row{ view = self, raw = row_raw }, self.user_data)
    }

    @(private)
    // Adds record (row), checks filter if any
    // #no_bounds_check: eid validated upstream, len(eid_to_ptr) == db.id_factory.cap
    view__add_record :: proc(self: ^View, eid: entity_id, use_filter:= true) -> Error #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        // Should never happen because view is capped at table cap
        if raw.len >= self.cap do return API_Error.Cannot_Add_Record_To_View_Container_Is_Full
        if self.eid_to_ptr[eid.ix] != DELETED_INDEX do return oc.Core_Error.Already_Exists

        self.eid_to_ptr[eid.ix] = cast(view_record_id)raw.len

        record := view__get_row_private(self, raw.len)
        record.eid = eid

        view_row_raw__fill(record, self, eid)

        if !use_filter { // no filter, just add
            view__dense_check_row_degrade(self, record, raw.len)
            raw.len += 1
            return nil
        }

        if view__filter_match_private(self, record) == false {
            // doesn't match filter, rollback
            self.eid_to_ptr[eid.ix] = DELETED_INDEX
            view_row_raw__clear(record, self)
        } else {
            view__dense_check_row_degrade(self, record, raw.len)
            raw.len += 1
        }

        return nil
    }

    @(private)
    // Adds a record whose refs are already filled in `src` (the view's temp row):
    // copies the prepared row instead of re-deriving every component address
    // (view_row_raw__fill costs a lookup per column — a map probe for Compact_Table).
    // #no_bounds_check: eid validated upstream, len(eid_to_ptr) == db.id_factory.cap
    view__add_record_prefilled :: proc(self: ^View, eid: entity_id, src: ^View_Row_Raw) -> Error #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        // Should never happen because view is capped at table cap
        if raw.len >= self.cap do return API_Error.Cannot_Add_Record_To_View_Container_Is_Full
        if self.eid_to_ptr[eid.ix] != DELETED_INDEX do return oc.Core_Error.Already_Exists

        self.eid_to_ptr[eid.ix] = cast(view_record_id)raw.len

        record := view__get_row_private(self, raw.len)
        mem.copy(record, src, self.one_record_size)
        record.eid = eid

        view__dense_check_row_degrade(self, record, raw.len)
        raw.len += 1

        return nil
    }

    @(private)
    // #no_bounds_check: eid validated upstream, len(eid_to_ptr) == db.id_factory.cap
    view__remove_record :: proc(self: ^View, eid: entity_id) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)
        if raw.len <= 0 do return // no rows
        
        dest_row_ix :=  int(self.eid_to_ptr[eid.ix])
        if dest_row_ix < 0 do return // already deleted or this view doesn't match entity

        src_row_ix := raw.len - 1

        src_record:= view__get_row_private(self, src_row_ix)
    
        // check if record is not tail
        if dest_row_ix != src_row_ix {
            dst_record := view__get_row_private(self, dest_row_ix)

            mem.copy(dst_record, src_record, self.one_record_size)

            self.eid_to_ptr[src_record.eid.ix] = self.eid_to_ptr[eid.ix]

            // The moved row's alignment cannot be verified yet (subscribed tables swap
            // their own rows after this notification) — rescan lazily on next iteration.
            view__dense_degrade_to_unknown(self)
        }

        view_row_raw__clear(src_record, self)

        self.eid_to_ptr[eid.ix] = DELETED_INDEX
        raw.len -= 1 
    }

    @(private)
    // Rerun filter for an entity. The row is filled at most once: for a non-member
    // the row prepared for the filter test is copied into the view instead of
    // being filled a second time.
    view__rerun_filter_private :: proc(self: ^View, eid: entity_id) -> Error {
        rid := self.eid_to_ptr[eid.ix]

        if rid == DELETED_INDEX { // not a member yet
            if self.temp_row == nil do return nil // something is wrong, should not happen
            view_row_raw__fill(self.temp_row, self, eid)
            if view__filter_match_private(self, self.temp_row) { // matches, add it
                view__add_record_prefilled(self, eid, self.temp_row) or_return
            } // else doesn't match, nothing to do
        } else { // already a member
            row_raw := view__get_row(self, rid)
            if row_raw == nil do return nil // something is wrong, should not happen
            if !view__filter_match_private(self, row_raw) { // doesn't match anymore, remove it
                view__remove_record(self, eid)
            } // else still matches, nothing to do
        }

        return nil
    }

    @(private)
    view__remove_record_by_row :: proc(self: ^View, dest_row_ix: int, dest_record: ^View_Row_Raw) {
        raw := (^runtime.Raw_Slice)(&self.rows)

        src_row_ix := raw.len - 1
        src_record:= view__get_row_private(self, src_row_ix)
    
        dest_eid := dest_record.eid
        src_eid := src_record.eid

        // check if record is not tail
        if dest_row_ix != src_row_ix {
            mem.copy(dest_record, src_record, self.one_record_size)

            self.eid_to_ptr[src_eid.ix] = self.eid_to_ptr[dest_eid.ix]

            view__dense_degrade_to_unknown(self)
        }

        mem.zero(src_record, self.one_record_size)
        src_record.eid.ix = DELETED_INDEX

        self.eid_to_ptr[dest_eid.ix] = DELETED_INDEX
        raw.len -= 1
    }

    @(private)
    // Update component address in view when component is updated in table
    view__update_component_address :: proc(self: ^View, table: ^Shared_Table, eid: entity_id, addr: rawptr) -> Error  {
        cid := self.tid_to_cid[table.id]
        assert(cid != DELETED_INDEX)

        // record must exist
        if self.eid_to_ptr[eid.ix] == DELETED_INDEX do return oc.Core_Error.Not_Found   // it is possible when removal of other component
                                                                                        // removed enity from the view      
        row_ix := int(self.eid_to_ptr[eid.ix])
        record := view__get_row_private(self, row_ix)
        #no_bounds_check {
            record.refs[cid] = addr
        }

        // Safety net: a component moving to an address other than &rows[row_ix] breaks
        // that column's dense alignment. (While truly aligned this should not trigger —
        // removals that move members degrade the state to Unknown before this
        // notification arrives.)
        #no_bounds_check {
            col := &self.dense_cols[cid]
            if col.state == View_Dense_State.Aligned && uintptr(addr) != col.base + uintptr(row_ix) * col.stride {
                col.state = View_Dense_State.Misaligned
            }
        }

        return nil
    }

    @(private)
    view__get_row_private :: #force_inline proc "contextless" (self: ^View, #any_int index: int) -> ^View_Row_Raw { 
        #no_bounds_check {
            return (^View_Row_Raw)(&self.rows[index * self.one_record_size])
        }
    }


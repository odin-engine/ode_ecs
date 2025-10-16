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
    view_row_raw__fill :: proc (self: ^View_Row_Raw, view: ^View, eid: entity_id) {
        self.eid = eid

        table: ^Shared_Table
        cid: view_column_id
        for table in view.tables.items {
            cid = view.tid_to_cid[table.id]
            #no_bounds_check {
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

    View :: struct {
        id: view_id, 
        state: Object_State,
        db: ^Database, 
        tables: oc.Dense_Arr(^Shared_Table), // includes tables, removing table invalidates View

        tid_to_cid: []view_column_id,  
        eid_to_ptr: []view_record_id, // currently its actually eid_to_rid, might be changed to eid_to_ptr in future
        
        rows: []byte,  // tail swap, order doesn't matter here
        one_record_size: int, 
        records_size: int,
        tables_len: int, 

        cap: int,

        bits: Uni_Bits,
        suspended: bool,

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

    view__init :: proc(
        self: ^View, 
        db: ^Database, 
        includes: []^Shared_Table, 
        filter: proc(row: ^View_Row, user_data: rawptr = nil)->bool = nil, 
        loc := #caller_location
    ) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
        }

        if includes == nil || len(includes) <= 0 do return API_Error.Tables_Array_Should_Not_Be_Empty

        self.db = db

        // Store filter
        self.filter = filter

        // Make sure we do not have repeating columns (copmonent typse/tables)
        slice.sort(includes)
        uniq_tables := slice.unique(includes)
        self.tables_len = len(uniq_tables)

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

        return nil
    }
    
    view__terminate :: proc(self: ^View) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

        delete(self.rows, self.db.allocator) or_return
        delete(self.eid_to_ptr, self.db.allocator) or_return
        delete(self.tid_to_cid, self.db.allocator) or_return

        //
        // Unsubscribe from tables
        //
        for table in self.tables.items do shared_table__detach_subscriber(table, self) or_return

        oc.dense_arr__terminate(&self.tables, self.db.allocator) or_return

        //
        // Detach from db
        //
        database__detach_view(self.db, self)

        self.state = Object_State.Terminated
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
        min_table, table: ^Shared_Table
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
            assert(eid.ix >= 0)

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

        if self.tid_to_cid != nil {
            total += size_of(self.tid_to_cid[0]) * len(self.tid_to_cid)
        }

        if self.eid_to_ptr != nil {
            total += size_of(self.eid_to_ptr[0]) * len(self.eid_to_ptr)
        }

        if self.rows != nil {
            total += size_of(self.rows[0]) * self.cap
        }

        return total
    }

    // Returns true if entity has components that would match this view, doesn't check filter
    view__components_match :: #force_inline proc "contextless" (self: ^View, eid: entity_id) -> bool {
        return uni_bits__is_subset(&self.bits, &self.db.eid_to_bits[eid.ix]) 
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
    }

    view__get_row :: #force_inline proc "contextless" (self: ^View, #any_int index: int) -> ^View_Row_Raw { 
        if index < 0 || index >= view_len(self) do return nil
        return view__get_row_private(self, index)
    }

    view__get_record :: view__get_row // for compatibility, use view__get_row instead, might be removed in future

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
    view__filter_match_private :: proc(self: ^View, row_raw: ^View_Row_Raw) -> bool {
        if self.filter == nil do return true
        return self.filter(&View_Row{ view = self, raw = row_raw }, self.user_data)
    }

    @(private)
    // Adds record (row), checks filter if any
    view__add_record :: proc(self: ^View, eid: entity_id, use_filter:= true) -> Error {
        raw := (^runtime.Raw_Slice)(&self.rows)

        // Should never happen because view is capped at table cap
        if raw.len >= self.cap do return API_Error.Cannot_Add_Record_To_View_Container_Is_Full
        if self.eid_to_ptr[eid.ix] != DELETED_INDEX do return oc.Core_Error.Already_Exists

        self.eid_to_ptr[eid.ix] = cast(view_record_id)raw.len

        record := view__get_row_private(self, raw.len)
        record.eid = eid

        view_row_raw__fill(record, self, eid) 

        if !use_filter { // no filter, just add
            raw.len += 1
            return nil
        }   

        if view__filter_match_private(self, record) == false {
            // doesn't match filter, rollback
            self.eid_to_ptr[eid.ix] = DELETED_INDEX
            view_row_raw__clear(record, self)
        } else {
            raw.len += 1
        }

        return nil
    }

    @(private)
    view__remove_record :: proc(self: ^View, eid: entity_id) {
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
        }

        view_row_raw__clear(src_record, self)

        self.eid_to_ptr[eid.ix] = DELETED_INDEX
        raw.len -= 1 
    }

    // Rerun components match and filter for a row when component data is updated
    view__rerun_filter :: proc(self: ^View, eid: entity_id) -> Error {
        if view__filter_match(self, eid) {
            if self.eid_to_ptr[eid.ix] == DELETED_INDEX { // doesn't exist, add it
                view__add_record(self, eid, false) or_return // add without filter test because we already know it matches
            } // else already exists, nothing to do
        } else { // doesn't match
            if self.eid_to_ptr[eid.ix] != DELETED_INDEX { // exists, remove it
                view__remove_record(self, eid)
            } // else doesn't exist, nothing to do
        }

        return nil
    }

    @(private)
    view__remove_record_by_row :: proc(self: ^View, dest_row_ix: int, dest_record: ^View_Row_Raw) {
        raw := (^runtime.Raw_Slice)(&self.rows)

        src_row_ix := raw.len - 1
        src_record:= view__get_row_private(self, src_row_ix)
    
        // check if record is not tail
        if dest_row_ix != src_row_ix {
            mem.copy(dest_record, src_record, self.one_record_size)

            self.eid_to_ptr[src_record.eid.ix] = self.eid_to_ptr[dest_record.eid.ix]
        }

        mem.zero(src_record, self.one_record_size)
        src_record.eid.ix = DELETED_INDEX

        self.eid_to_ptr[src_record.eid.ix] = DELETED_INDEX
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
        
        return nil
    }

    @(private)
    view__get_row_private :: #force_inline proc "contextless" (self: ^View, #any_int index: int) -> ^View_Row_Raw { 
        #no_bounds_check {
            return (^View_Row_Raw)(&self.rows[index * self.one_record_size])
        }
    }


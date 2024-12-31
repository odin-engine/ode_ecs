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
// View
// 
    View_Record :: struct {
        eid: entity_id,
        refs: [1] rawptr, // at least one component
    }

    View :: struct {
        id: view_id, 
        state: Object_State,
        ecs: ^Database, 
        tables: oc.Dense_Arr(^Table_Raw), // includes tables, removing table invalidates View

        tid_to_cid: []view_column_id,  
        eid_to_rid: []view_record_id, 
        
        records: []byte,  // tail swap, order doesn't matter here
        one_record_size: int, 
        records_size: int,
        tables_len: int, 

        cap: int,

        bits: Uni_Bits,
        suspended: bool,
    }

    view_init :: proc(self: ^View, ecs: ^Database, includes: []^Table_Base) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(ecs != nil)
            assert(ecs.state == Object_State.Normal)
            assert(self.state == Object_State.Not_Initialized)
        }

        self.ecs = ecs

        if includes == nil || len(includes) <= 0 do return API_Error.Tables_Array_Should_Not_Be_Empty

        // Make sure we do not have repeating columns (copmonent typse/tables)
        slice.sort(includes)
        uniq_tables := slice.unique(includes)
        self.tables_len = len(uniq_tables)

        oc.dense_arr__init(&self.tables, self.tables_len, ecs.allocator) or_return

        // max table id
        max_table_id: int = -1
        for table in uniq_tables {
            if int(table.id) > max_table_id do max_table_id = int(table.id)
        }

        //
        // tid_to_cid
        //
        self.tid_to_cid = make([]view_column_id, max_table_id + 1, ecs.allocator) or_return
        for i := 0; i < len(self.tid_to_cid); i+=1 do self.tid_to_cid[i] = DELETED_INDEX

        self.cap = max(int)
        for table, index in uniq_tables {
            when VALIDATIONS {
                assert(table.state == Object_State.Normal)
            }

            oc.dense_arr__add(&self.tables, cast(^Table_Raw) table)

            if table.cap < self.cap {
                self.cap = table.cap
            }

            self.tid_to_cid[table.id] = cast(view_column_id)index 

            uni_bits__add(&self.bits, table.id)
        }

        //
        // eid_to_rid
        //
        self.eid_to_rid = make([]view_record_id, ecs.id_factory.cap, ecs.allocator) or_return
        
        //
        // records
        //
        self.one_record_size = size_of(View_Record) + (self.tables_len - 1) * size_of(rawptr)  // -1 because one is already in struct
        self.records_size = self.cap * self.one_record_size

        raw := (^runtime.Raw_Slice)(&self.records)

        raw.data = mem.alloc(self.records_size, allocator = ecs.allocator) or_return
        raw.len = 0

        self.state = Object_State.Normal

        // Clear 
        view_clear(self) or_return

        //
        // Attach to ecs
        //
        self.id = db__attach_view(ecs, self) or_return

        //
        // Subscribe to tables
        //
        for table in uniq_tables do table__attach_subscriber(table, self)

        return nil
    }

    view_terminate :: proc(self: ^View) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.ecs != nil)
        }

        delete(self.records, self.ecs.allocator) or_return
        delete(self.eid_to_rid, self.ecs.allocator) or_return
        delete(self.tid_to_cid, self.ecs.allocator) or_return

        //
        // Unsubscribe from tables
        //
        for table in self.tables.items do table__detach_subscriber(table, self) or_return

        oc.dense_arr__terminate(&self.tables, self.ecs.allocator) or_return

        //
        // Detach from ecs
        //
        db__detach_view(self.ecs, self)

        self.state = Object_State.Terminated
        return nil
    }

    view_clear :: proc(self: ^View) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.eid_to_rid != nil {
            for i := 0; i < len(self.eid_to_rid); i+=1 do self.eid_to_rid[i] = DELETED_INDEX
        }

        if len(self.records) > 0 {
            mem.zero((^runtime.Raw_Slice)(&self.records).data, self.records_size)
            (^runtime.Raw_Slice)(&self.records).len = 0
        }

        return nil
    }

    rebuild :: proc(self: ^View) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.tables.items != nil)
        }
        
        view_clear(self) or_return 

        min_records_count: int = max(int)
        min_table, table: ^Table_Raw
        for table in self.tables.items {
            if table_raw__len(table) < min_records_count {
                min_table = table
                min_records_count = table_raw__len(table)
            }
        }

        eid: entity_id
        min_table_col_ix := self.tid_to_cid[min_table.id]
        assert(self.cap >= table_raw__len(min_table))

        for i:= 0; i < table_raw__len(min_table); i+=1 {
            eid = min_table.rid_to_eid[i]
            assert(eid.ix >= 0)

            // check if view bits is subset of entity bits
            if view_entity_match(self, eid) {
                view__add_record(self, eid) or_return
            }
        }

        return nil
    }
    
    view_len :: #force_inline proc "contextless" (self: ^View) -> int {
        return (^runtime.Raw_Slice)(&self.records).len
    }

    view_cap :: #force_inline proc "contextless" (self: ^View) -> int { return self.cap }

    view_memory_usage :: proc (self: ^View) -> int { 
        total := size_of(self^)

        total += oc.dense_arr__memory_usage(&self.tables)

        if self.tid_to_cid != nil {
            total += size_of(self.tid_to_cid[0]) * len(self.tid_to_cid)
        }

        if self.eid_to_rid != nil {
            total += size_of(self.eid_to_rid[0]) * len(self.eid_to_rid)
        }

        if self.records != nil {
            total += size_of(self.records[0]) * self.cap
        }

        return total
    }

    // returns true if entity has components that would match this view
    view_entity_match :: #force_inline proc "contextless" (self: ^View, eid: entity_id) -> bool {
        return uni_bits__is_subset(&self.bits, &self.ecs.eid_to_bits[eid.ix]) 
    }

    suspend :: proc(self: ^View) {
        when VALIDATIONS {
            assert(self != nil)
        }

        self.suspended = true
    }

    resume :: proc(self: ^View) {
        when VALIDATIONS {
            assert(self != nil)
        }

        self.suspended = false
    }

    view__get_record :: #force_inline proc "contextless" (self: ^View, index: int) -> ^View_Record { 
        if index < 0 || index >= view_len(self) do return nil
        return view__get_record_private(self, index)
    }

    view__get_component_for_record :: #force_inline proc "contextless" (self: ^View, rec: ^View_Record, table: ^Table($T)) -> ^T {
        #no_bounds_check {
            return (^T)(rec.refs[self.tid_to_cid[table.id]])
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    view__add_record :: proc(self: ^View, eid: entity_id) -> Error {
        raw := (^runtime.Raw_Slice)(&self.records)

        // Should never happen because view is capped at table cap
        if raw.len >= self.cap do return API_Error.Cannot_Add_Record_To_View_Container_Is_Full
        if self.eid_to_rid[eid.ix] != DELETED_INDEX do return oc.Core_Error.Already_Exists

        self.eid_to_rid[eid.ix] = cast(view_record_id)raw.len

        record := view__get_record_private(self, raw.len)
        record.eid = eid

        table: ^Table_Raw
        cid: view_column_id
        rid: table_record_id
        for table in self.tables.items {
            cid = self.tid_to_cid[table.id]
            #no_bounds_check {
                record.refs[cid] = table_raw__get_component(table, eid)
            }
        }

        raw.len += 1

        return nil
    }

    @(private)
    view__remove_record :: proc(self: ^View, eid: entity_id) {
        raw := (^runtime.Raw_Slice)(&self.records)
        if raw.len <= 0 do return // no records
        
        dest_row_ix :=  int(self.eid_to_rid[eid.ix])
        if dest_row_ix < 0 do return // already deleted or this view doesn't match entity

        src_row_ix := raw.len - 1

        src_record:= view__get_record_private(self, src_row_ix)
    
        // check if record is not tail
        if dest_row_ix != src_row_ix {
            dst_record := view__get_record_private(self, dest_row_ix)    
            
            mem.copy(dst_record, src_record, self.one_record_size)

            self.eid_to_rid[src_record.eid.ix] = self.eid_to_rid[eid.ix]
        }

        mem.zero(src_record, self.one_record_size)
        src_record.eid.ix = DELETED_INDEX

        self.eid_to_rid[eid.ix] = DELETED_INDEX
        raw.len -= 1 
    }

    @(private)
    view__update_component :: proc(self: ^View, table: ^Table_Raw, eid: entity_id, addr: rawptr) -> Error  {
        cid := self.tid_to_cid[table.id]
        assert(cid != DELETED_INDEX)

        // record must exist
        if self.eid_to_rid[eid.ix] == DELETED_INDEX do return oc.Core_Error.Not_Found   // it is possible when removal of other component
                                                                                        // removed enity from the view      
        row_ix := int(self.eid_to_rid[eid.ix])
        record := view__get_record_private(self, row_ix)
        #no_bounds_check {
            record.refs[cid] = addr
        }
        
        return nil
    }

    @(private)
    view__get_record_private :: #force_inline proc "contextless" (self: ^View, index: int) -> ^View_Record { 
        #no_bounds_check {
            return (^View_Record)(&self.records[index * self.one_record_size])
        }
    }


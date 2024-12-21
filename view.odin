/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"
// Core
    import "core:slice"
    import "core:log"
    import "core:fmt"
// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// View
// 
    View :: struct {
        id: view_id, 
        state: Object_State,
        ecs: ^Database, 
        tables: oc.Dense_Arr(^Table_Raw), // includes tables, removing table invalidates View
        excludes: oc.Dense_Arr(^Table_Raw),

        tid_to_cid: []view_column_id,  
        eid_to_rid: []view_record_id, 
        
        records: []int,  // tail swap, order doesn't matter here
        columns_count: int, 

        cap: int,

        bits: Uni_Bits,
        suspended: bool,
    }

    view__init :: proc(self: ^View, ecs: ^Database, includes: []^Table_Base, excludes: []^Table_Base = nil) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(ecs != nil)
            assert(ecs.state == Object_State.Normal)
            assert(self.state == Object_State.Not_Initialized)
        }

        self.ecs = ecs

        if includes == nil || len(includes) <= 0 do return API_Error.Tables_Array_Should_Not_Be_Empty

        // Make sure we do not have repeating columns
        slice.sort(includes)
        uniq_tables := slice.unique(includes)
        len_uniq_tables := len(uniq_tables)

        oc.dense_arr__init(&self.tables, len_uniq_tables, ecs.allocator) or_return

        // excludes
        if len(excludes) > 0 {
            slice.sort(excludes)
            uniq_excludes := slice.unique(excludes)
            len_uniq_excludes := len(uniq_excludes)
    
            oc.dense_arr__init(&self.excludes, len_uniq_excludes, ecs.allocator) or_return
        }

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

            // Plus 1 because the first column is reserverd for entity_id
            self.tid_to_cid[table.id] = cast(view_column_id)index + 1 

            uni_bits__add(&self.bits, table.id)
        }

        // first column is entity_id
        self.columns_count = 1 + len_uniq_tables
    
        //
        // eid_to_rid
        //
        self.eid_to_rid = make([]view_record_id, ecs.id_factory.cap, ecs.allocator) or_return
        
        //
        // records
        //
        total_count := self.cap * self.columns_count
        self.records = make([]int, total_count, ecs.allocator) or_return

        self.state = Object_State.Normal

        // Clear 
        view__clear(self) or_return

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

    view__terminate :: proc(self: ^View) -> Error {
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

        oc.dense_arr__terminate(&self.excludes, self.ecs.allocator) or_return
        oc.dense_arr__terminate(&self.tables, self.ecs.allocator) or_return

        //
        // Detach from ecs
        //
        db__detach_view(self.ecs, self)

        self.state = Object_State.Terminated
        return nil
    }

    view__clear :: proc(self: ^View) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.eid_to_rid != nil {
            for i := 0; i < len(self.eid_to_rid); i+=1 do self.eid_to_rid[i] = DELETED_INDEX
        }

        if self.cap > 0 && self.records != nil {
            total_count := self.cap * self.columns_count
            #no_bounds_check {
                for i := 0; i < total_count; i+=1 do self.records[i] = DELETED_INDEX
            }
            (^runtime.Raw_Slice)(&self.records).len = 0
        }

        return nil
    }

    view__rebuild :: proc(self: ^View) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.tables.items != nil)
        }
        
        view__clear(self) or_return 

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
            if view__entity_match(self, eid) {
                view__add_record(self, eid) or_return
            }
        }

        return nil
    }
    
    view__len :: #force_inline proc "contextless" (self: ^View) -> int {
        return (^runtime.Raw_Slice)(&self.records).len
    }

    view__cap :: #force_inline proc "contextless" (self: ^View) -> int { return self.cap }

    view__memory_usage :: proc (self: ^View) -> int { 
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
    view__entity_match :: #force_inline proc "contextless" (self: ^View, eid: entity_id) -> bool {
        return uni_bits__is_subset(&self.bits, &self.ecs.eid_to_bits[eid.ix]) 
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
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    view__add_record :: proc(self: ^View, eid: entity_id) -> Error {
        raw := (^runtime.Raw_Slice)(&self.records)

        // Should never happen because view is capped at table cap
        if raw.len >= self.cap do return API_Error.Cannot_Add_Record_To_View_Container_Is_Full
        if self.eid_to_rid[eid.ix] != DELETED_INDEX do return oc.Core_Error.Already_Exists

        row_ix := raw.len * self.columns_count
        self.eid_to_rid[eid.ix] = cast(view_record_id)raw.len

        // first column
        #no_bounds_check {
            self.records[row_ix] = int(eid)
        }

        table: ^Table_Raw
        cid: view_column_id
        rid: table_record_id
        for table in self.tables.items {
            cid = self.tid_to_cid[table.id]
            rid = table.eid_to_rid[eid.ix]
            #no_bounds_check {
                self.records[row_ix + cid] = int(rid)
            }
        }

        raw.len += 1

        return nil
    }

    @(private)
    view__remove_record :: proc(self: ^View, eid: entity_id) {
        raw := (^runtime.Raw_Slice)(&self.records)
        if raw.len <= 0 do return // no records
        if self.eid_to_rid[eid.ix] == DELETED_INDEX do return // already deleted or this view doesn't match entity

        dest_row_ix :=  int(self.eid_to_rid[eid.ix]) * self.columns_count
        src_row_ix := (raw.len - 1) * self.columns_count

        // check if record is tail
        if dest_row_ix != src_row_ix {
            src_eid: int = DELETED_INDEX
            #no_bounds_check {
                src_eid = self.records[src_row_ix]

                // COPY
                for j:= 0; j < self.columns_count; j += 1 {
                    self.records[dest_row_ix + j] = self.records[src_row_ix + j]
                }
            }
           
            self.eid_to_rid[src_eid] = self.eid_to_rid[eid.ix]
        }

        #no_bounds_check {
            // Reset tail
            for i:= 0; i < self.columns_count; i += 1 {
                self.records[src_row_ix + i] = DELETED_INDEX
            }
        }

        self.eid_to_rid[eid.ix] = DELETED_INDEX
        raw.len -= 1 
    }

    @(private)
    view__update_component :: proc(self: ^View, table: ^Table_Raw, eid: entity_id, rid: table_record_id) -> Error  {
        cid := self.tid_to_cid[table.id]
        assert(cid != DELETED_INDEX)

        // record must exist
        if self.eid_to_rid[eid.ix] == DELETED_INDEX do return oc.Core_Error.Not_Found   // it is possible when removal of other component
                                                                                        // removed enity from the view      
        
        row_ix := int(self.eid_to_rid[eid.ix]) * self.columns_count
        
        #no_bounds_check {
            assert(self.records[row_ix + cid] != int(rid))
            self.records[row_ix + cid] = int(rid)
        }

        return nil
    }

    @(private)
    view__get_record :: #force_inline proc "contextless" (self: ^View, index: int) -> []int {
        low := self.columns_count *  index 
        return self.records[low : low + self.columns_count]
    }
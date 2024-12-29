/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"
    import "core:fmt"


// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Table_Base

    @(private)
    Table_Base :: struct {
        state: Object_State,
        id: table_id, 
        type_info: ^runtime.Type_Info,

        ecs: ^Database, 

        rid_to_eid: []entity_id,
        eid_to_rid: []table_record_id,

        cap: int,

        subscribers: oc.Dense_Arr(^View),
    }

    @(private)
    table_base__init :: proc(self: ^Table_Base, ecs: ^Database, cap: int) -> Error {
        self.ecs = ecs
        self.id = DELETED_INDEX
        self.cap = cap

        self.rid_to_eid = make([]entity_id, cap, ecs.allocator) or_return
        self.eid_to_rid = make([]table_record_id, ecs.id_factory.cap, ecs.allocator) or_return

        oc.dense_arr__init(&self.subscribers, VIEWS_CAP, ecs.allocator) or_return

        return nil
    }

    @(private)
    table_base__terminate :: proc(self: ^Table_Base) -> Error {
        oc.dense_arr__terminate(&self.subscribers, self.ecs.allocator) or_return

        delete(self.rid_to_eid, self.ecs.allocator) or_return
        delete(self.eid_to_rid, self.ecs.allocator) or_return
       
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Table_Raw

    @(private)
    Table_Raw :: struct {
        using base: Table_Base,
        records: []byte,
    }

    @(private)
    table_raw__terminate :: proc(self: ^Table_Raw) -> Error {
        for view in self.subscribers.items do view.state = Object_State.Invalid

        db__detach_table(self.ecs, self)

        if self.records != nil do delete(self.records, self.ecs.allocator) or_return

        table_base__terminate(self) or_return

        self.ecs = nil 
        self.id = DELETED_INDEX
        self.state = Object_State.Terminated

        return nil
    }

    @(private)
    table_raw__len :: #force_inline proc "contextless" (self: ^Table_Raw) -> int {
        return (^runtime.Raw_Slice)(&self.records).len
    }

    @(private)
    table_raw__remove_component :: proc(self: ^Table_Raw, target_eid: entity_id) -> (err: Error) {
        raw := (^runtime.Raw_Slice)(&self.records)

        if raw.len <= 0 do return oc.Core_Error.Not_Found 

        target_rid := self.eid_to_rid[target_eid.ix]

        // Check if component exists
        if target_rid == DELETED_INDEX do return oc.Core_Error.Not_Found
        
        T_size := self.type_info.size
        records := raw_data(self.records)

        tail_rid := cast(table_record_id) raw.len - 1
        tail := &records[cast(int)tail_rid * T_size]
        
        // Replace removed component with tail
        if target_rid == tail_rid {
            // Remove indexes
            self.eid_to_rid[target_eid.ix] = DELETED_INDEX
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for i := 0; i < oc.dense_arr__len(&self.subscribers); i += 1 {
                view := self.subscribers.items[i]
                if view != nil do view__remove_record(view, target_eid)
            }
        }
        else {
            tail_eid := self.rid_to_eid[tail_rid]
            assert(tail_eid.ix != DELETED_INDEX)

            // DATA COPY
            dst := &records[cast(int)target_rid * T_size]
            mem.copy(dst, tail, T_size)

            // Update tail indexes
            self.eid_to_rid[tail_eid.ix] = target_rid
            self.eid_to_rid[target_eid.ix] = DELETED_INDEX

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            // Notify subscribed views
            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component(view, self, tail_eid, target_rid)
                }
            }
        }

        // Zero tail
        mem.zero(tail, T_size)
        raw.len -= 1

        // Update eid_to_bits in ecs
        db__remove_component(self.ecs, target_eid, self.id)

        return
    }

    // clear data, nothing else
    table_raw__clear :: proc (self: ^Table_Raw, zero_components := true) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.rid_to_eid != nil {
            for i := 0; i < len(self.rid_to_eid); i+=1 do self.rid_to_eid[i].ix = DELETED_INDEX
        }

        if self.eid_to_rid != nil {
            for i := 0; i < len(self.eid_to_rid); i+=1 do self.eid_to_rid[i] = DELETED_INDEX
        }

        if zero_components && self.cap > 0 && self.records != nil {
            mem.zero(raw_data(self.records), self.type_info.size * self.cap)
        }
        (^runtime.Raw_Slice)(&self.records).len = 0

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Table

    // Components table
    Table :: struct($T: typeid) {
        using base: Table_Base,
        // table_record_id => component
        records: []T,     
    }

    table_init :: proc(self: ^Table($T), ecs: ^Database, cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(ecs != nil, loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // table should be NOT_INITIALIZED
            assert(ecs.state == Object_State.Normal, loc = loc) // ecs should be initialized
            assert(cap <= ecs.id_factory.cap, loc = loc) // cannot be larger than entities_cap
        }

        self.type_info = type_info_of(typeid_of(T))

        table_base__init(&self.base, ecs, cap) or_return 

        self.records = make([]T, cap, ecs.allocator) or_return
        
        self.id = db__attach_table(ecs, self) or_return

        self.state = Object_State.Normal

        table_raw__clear(cast(^Table_Raw)self) or_return 

        return nil
    }

    table_terminate :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.type_info.id == typeid_of(T))
            assert(self.ecs != nil)
        }

        table_raw__terminate(cast(^Table_Raw) self) or_return

        return nil
    }

    add_component :: proc(self: ^Table($T), eid: entity_id) -> (component: ^T, err: Error) {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Normal)
            assert(self.type_info.id == typeid_of(T))
        }

        err = db__is_entity_correct(self.ecs, eid)
        if err != nil do return nil, err

        raw := (^runtime.Raw_Slice)(&self.records)

        if raw.len >= self.cap do return nil, oc.Core_Error.Container_Is_Full 

        // Check if component already exist
        if  self.eid_to_rid[eid.ix] == DELETED_INDEX {
            // Update eid_to_rid
            self.eid_to_rid[eid.ix] = cast(table_record_id) raw.len

            // Update rid_to_eid
            self.rid_to_eid[raw.len] = eid

            // Update eid_to_bits in ecs
            db__add_component(self.ecs, eid, self.id)

            // Get component
            #no_bounds_check {
                component = &self.records[raw.len]
            }
            
            raw.len += 1
        } else {
            component = &self.records[self.eid_to_rid[eid.ix]]
            err = API_Error.Component_Already_Exist
        }

        // Notify subscribed views
        for view in self.subscribers.items {
            if !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }

        return 
    }

    remove_component :: proc(self: ^Table($T), eid: entity_id) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Normal)
            assert(self.type_info.id == typeid_of(T))
            assert(eid < cast(entity_id)self.ecs.id_factory.cap)
        }
        
        db__is_entity_correct(self.ecs, eid) or_return
       
        return table_raw__remove_component(cast(^Table_Raw) self, eid)
    }

    table_len :: #force_inline proc "contextless" (self: ^Table($T)) -> int {
        return (^runtime.Raw_Slice)(&self.records).len
    }

    table_cap :: #force_inline proc "contextless" (self: ^Table($T)) -> int {
        return self.cap
    }

    @(require_results)
    get_component_by_entity :: proc (self: ^Table($T), eid: entity_id) -> (^T, Error) {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := db__is_entity_correct(self.ecs, eid)
        if err != nil do return nil, err

        rid := self.eid_to_rid[eid.ix]

        if rid == DELETED_INDEX do return nil, oc.Core_Error.Not_Found

        return &self.records[rid], nil
    }

    @(require_results)
    has_component :: proc (self: ^Table($T), eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := db__is_entity_correct(self.ecs, eid)
        if err != nil do return false

        return self.eid_to_rid[eid.ix] != DELETED_INDEX
    }

    get_entity_from_table :: #force_inline proc "contextless" (self: ^Table($T), #any_int record_index: int) -> entity_id {
        return self.rid_to_eid[record_index]
    }

    table_memory_usage :: proc (self: ^Table_Base) -> int {    
        total := size_of(self^)

        if self.rid_to_eid != nil {
            total += size_of(self.rid_to_eid[0]) * len(self.rid_to_eid)
        }

        if self.eid_to_rid != nil {
            total += size_of(self.eid_to_rid[0]) * len(self.eid_to_rid)
        }

        // records
        total += self.type_info.size * self.cap

        total += oc.dense_arr__memory_usage(&self.subscribers)

        return total
    }
    

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    table__attach_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        _, err := oc.dense_arr__add(&self.subscribers, view)
        return err
    }

    @(private)
    table__detach_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        err := oc.dense_arr__remove_by_value(&self.subscribers, view)
        return err
    }




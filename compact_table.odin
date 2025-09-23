/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:slice"
    import "core:math"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Compact_Table_Base

    // Base for Compact_Table
    @(private)
    Compact_Table_Base :: struct {
        using shared: Shared_Table,

        type_info: ^runtime.Type_Info,
        rid_to_eid: []entity_id,
        eid_to_ptr: oc_maps.Rh_Map(rawptr),

        cap: int,

        subscribers: oc.Dense_Arr(^View),
    }

    @(private)
    compact_table_base__init :: proc(self: ^Compact_Table_Base, db: ^Database, cap: int) -> Error {
        shared_table__init(&self.shared, Table_Type.Compact_Table, db)

        self.cap = cap

        self.rid_to_eid = make([]entity_id, self.cap, db.allocator) or_return

        // load factor 0.5 and make it power of two
        oc_maps.rh_map__init(&self.eid_to_ptr, math.next_power_of_two(self.cap * 2), db.allocator) or_return

        oc.dense_arr__init(&self.subscribers, VIEWS_CAP, db.allocator) or_return

        return nil
    }

    @(private)
    compact_table_base__terminate :: proc(self: ^Compact_Table_Base) -> Error {
        oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return

        delete(self.rid_to_eid, self.db.allocator) or_return
        oc_maps.rh_map__terminate(&self.eid_to_ptr, self.db.allocator) or_return
       
        return nil
    }

    @(private)
    compact_table_base__cap :: proc(self: ^Compact_Table_Base) -> int {
        return self.cap
    }

    @(private)
    compact_table_base__attach_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        _, err := oc.dense_arr__add(&self.subscribers, view)
        return err
    }

    @(private)
    compact_table_base__detach_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        err := oc.dense_arr__remove_by_value(&self.subscribers, view)
        return err
    }

    @(private)
    compact_table_base__memory_usage :: proc (self: ^Compact_Table_Base) -> int {    
        total := size_of(self^)

        if self.rid_to_eid != nil {
            total += size_of(self.rid_to_eid[0]) * len(self.rid_to_eid)
        }

        total += oc_maps.rh_map__memory_usage(&self.eid_to_ptr)

        // rows
        total += self.type_info.size * self.cap

        total += oc.dense_arr__memory_usage(&self.subscribers)

        return total
    }

    @(private)
    compact_table_base__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Compact_Table_Base, #any_int row_number: int) -> entity_id {
        return self.rid_to_eid[row_number]
    }

    @(private)
    compact_table_base__get_component_by_entity :: proc (self: ^Compact_Table_Base, eid: entity_id) -> rawptr {
        return oc_maps.rh_map__get(&self.eid_to_ptr, eid.ix)
    }

///////////////////////////////////////////////////////////////////////////////
// Compact_Table_Raw

    @(private)
    Compact_Table_Raw :: struct {
        using base: Compact_Table_Base,
        rows: []byte,
    }

    @(private)
    compact_table_raw__terminate :: proc(self: ^Compact_Table_Raw) -> Error {
        for view in self.subscribers.items do view.state = Object_State.Invalid

        database__detach_table(self.db, self)

        if self.rows != nil do delete(self.rows, self.db.allocator) or_return

        compact_table_base__terminate(self) or_return

        self.db = nil 
        self.id = DELETED_INDEX
        self.state = Object_State.Terminated

        return nil
    }

    @(private)
    compact_table_raw__remove_component :: proc(self: ^Compact_Table_Raw, target_eid: entity_id, loc:= #caller_location) -> (err: Error) {
        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found 

        target := oc_maps.rh_map__get(&self.eid_to_ptr, target_eid.ix) 
        
        // Check if component exists
        if target == nil do return oc.Core_Error.Not_Found
        
        T_size := self.type_info.size
        rows := raw_data(self.rows)

        tail_rid := raw.len - 1
        tail_eid := self.rid_to_eid[tail_rid] 

        assert(tail_eid.ix != DELETED_INDEX)

        tail := oc_maps.rh_map__get(&self.eid_to_ptr, tail_eid.ix)
        assert(tail != nil)
        
        target_rid := int(uintptr(target) - uintptr(&self.rows[0])) / T_size

        // Replace removed component with tail
        if target == tail {
            // Remove indexes
            oc_maps.rh_map__remove(&self.eid_to_ptr, target_eid.ix)

            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
            }
        }
        else {
            tail_eid := self.rid_to_eid[tail_rid]
            assert(tail_eid.ix != DELETED_INDEX)

            // DATA COPY
            mem.copy(target, tail, T_size)

            // Update tail indexes
            oc_maps.rh_map__update(&self.eid_to_ptr, tail_eid.ix, target)
            oc_maps.rh_map__remove(&self.eid_to_ptr, target_eid.ix)

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            // Notify subscribed views
            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component(view, self, tail_eid, rawptr(target))
                }
            }
        }

        // Zero tail
        mem.zero(tail, T_size)
        raw.len -= 1

        // Update eid_to_bits in db
        database__remove_component(self.db, target_eid, self.id)

        return
    }

    compact_table_raw__len :: #force_inline proc "contextless" (self: ^Compact_Table_Raw) -> int {
        return (^runtime.Raw_Slice)(&self.rows).len
    }

    // clear data, nothing else
    compact_table_raw__clear :: proc (self: ^Compact_Table_Raw, zero_components := true) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.rid_to_eid != nil {
            for i := 0; i < len(self.rid_to_eid); i+=1 do self.rid_to_eid[i].ix = DELETED_INDEX
        }

        oc_maps.rh_map__clear(&self.eid_to_ptr)
       
        if zero_components && self.cap > 0 && self.rows != nil {
            raw := (^runtime.Raw_Slice)(&self.rows)
            mem.zero(raw_data(self.rows), self.type_info.size * raw.len)
        }
        (^runtime.Raw_Slice)(&self.rows).len = 0

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Compact_Table

    // Components table
    Compact_Table :: struct($T: typeid) {
        using base: Compact_Table_Base,
        // table_record_id => component
        rows: []T,     
    }

    compact_table__init :: proc(self: ^Compact_Table($T), db: ^Database, cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(db != nil, loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // table should be NOT_INITIALIZED
            assert(db.state == Object_State.Normal, loc = loc) // db should be initialized
            assert(cap <= db.id_factory.cap, loc = loc) // cannot be larger than entities_cap
        }

        self.type_info = type_info_of(typeid_of(T))

        compact_table_base__init(&self.base, db, cap) or_return 

        self.rows = make([]T, cap, db.allocator) or_return
        
        self.id = database__attach_table(db, self) or_return

        self.state = Object_State.Normal

        compact_table_raw__clear(cast(^Compact_Table_Raw)self) or_return 

        return nil
    }

    compact_table__terminate :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.type_info.id == typeid_of(T))
            assert(self.db != nil)
        }

        compact_table_raw__terminate(cast(^Compact_Table_Raw) self) or_return

        return nil
    }
    
    compact_table__add_component :: proc(self: ^Compact_Table($T), eid: entity_id) -> (component: ^T, err: Error) {
        err = database__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len >= self.cap do return nil, oc.Core_Error.Container_Is_Full 

        component = cast(^T) oc_maps.rh_map__get(&self.eid_to_ptr, eid.ix)

        // Check if component already exist
        if component == nil {
            // Get component
            #no_bounds_check {
                component = &self.rows[raw.len]
            }
                        
            // Add eid_to_ptr
            oc_maps.rh_map__add(&self.eid_to_ptr, eid.ix, component) or_return

            // Update rid_to_eid
            self.rid_to_eid[raw.len] = eid

            // Update eid_to_bits in db
            database__add_component(self.db, eid, self.id)

            raw.len += 1
        } else {
            err = API_Error.Component_Already_Exist
        }

        // Notify subscribed views
        for view in self.subscribers.items {
            if !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }

        return 
    }

    compact_table__remove_component :: proc(self: ^Compact_Table($T), eid: entity_id, loc:= #caller_location) -> Error {
        database__is_entity_correct(self.db, eid) or_return
       
        return compact_table_raw__remove_component(cast(^Compact_Table_Raw) self, eid, loc)
    }

    compact_table__len :: #force_inline proc "contextless" (self: ^Compact_Table($T)) -> int {
        return compact_table_raw__len(cast(^Compact_Table_Raw) self)
    }

    compact_table__cap :: #force_inline proc "contextless" (self: ^Compact_Table($T)) -> int {
        return compact_table_base__cap(self)
    }

    @(require_results)
    compact_table__get_component_by_entity :: proc (self: ^Compact_Table($T), eid: entity_id) -> ^T {
        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        return cast(^T) oc_maps.rh_map__get(&self.eid_to_ptr, eid.ix)
    }

    @(require_results)
    compact_table__has_component :: proc (self: ^Compact_Table($T), eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return oc_maps.rh_map__get(&self.eid_to_ptr, eid.ix) != nil
    }

    compact_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Compact_Table($T), #any_int row_number: int) -> entity_id {
        return compact_table_base__get_entity_by_row_number(self, row_number)
    }

    compact_table__memory_usage :: proc (self: ^Compact_Table($T)) -> int {    
       return compact_table_base__memory_usage(cast(^Compact_Table_Base) self)
    }
 
    // Component data for entity `eid`` is copied into `dest` table from `src` table and linked to enitity `eid`
    compact_table__copy_component :: proc(dest: ^Compact_Table($T), src: ^Compact_Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        src_component = compact_table__get_component_by_entity(src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found // component not found

        dest_component = compact_table__get_component_by_entity(dest, eid) // if it exists we will overwrite data
        if dest_component == nil {
            dest_component = add_component(dest, eid) or_return 
        }

        // copy data
        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    // Component data for entity `eid`` is moved into `dest` table from `src` table and linked to enitity `eid`
    compact_table__move_component :: proc(dest: ^Compact_Table($T), src: ^Compact_Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = copy_component(dest, src, eid) or_return

        remove_component(src, eid) or_return

        return dest_component, nil
    }

    compact_table__clear :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        compact_table_raw__clear((^Compact_Table_Raw)(self), true) or_return

        return nil
    }

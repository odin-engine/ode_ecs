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
// Table_Base

    // Base for Table
    @(private)
    Table_Base :: struct {
        using shared: Shared_Table,

        type_info: ^runtime.Type_Info,
        rid_to_eid: []entity_id,
        eid_to_ptr: []rawptr,

        cap: int,

        subscribers: oc.Dense_Arr(^View),
    }

    @(private)
    table_base__init :: proc(self: ^Table_Base, db: ^Database, cap: int) -> Error {
        shared_table__init(&self.shared, Table_Type.Table, db)

        self.cap = cap

        self.rid_to_eid = make([]entity_id, cap, db.allocator) or_return

        // if you need to optimize memory usage, use Tiny_Table if your table cap is less than 11, 
        // and use Small_Table if your table cap is less than db.id_factory.cap / 2 but greater than 11
        // in other cases or if you do not care about memory usage, use Table
        // db.id_factory.cap is database entities cap
        self.eid_to_ptr = make([]rawptr, db.id_factory.cap, db.allocator) or_return

        oc.dense_arr__init(&self.subscribers, VIEWS_CAP, db.allocator) or_return

        return nil
    }

    @(private)
    table_base__terminate :: proc(self: ^Table_Base) -> Error {
        oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return

        delete(self.rid_to_eid, self.db.allocator) or_return
        delete(self.eid_to_ptr, self.db.allocator) or_return
       
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Table_Raw

    @(private)
    Table_Raw :: struct {
        using base: Table_Base,
        rows: []byte,
    }

    @(private)
    table_raw__terminate :: proc(self: ^Table_Raw) -> Error {
        for view in self.subscribers.items do view.state = Object_State.Invalid

        db__detach_table(self.db, self)

        if self.rows != nil do delete(self.rows, self.db.allocator) or_return

        table_base__terminate(self) or_return

        self.db = nil 
        self.id = DELETED_INDEX
        self.state = Object_State.Terminated

        return nil
    }

    @(private)
    table_raw__get_component :: proc (self: ^Table_Raw, eid: entity_id) -> rawptr {
        return self.eid_to_ptr[eid.ix]
    }

    @(private)
    table_raw__len :: #force_inline proc "contextless" (self: ^Table_Raw) -> int {
        return (^runtime.Raw_Slice)(&self.rows).len
    }

    @(private)
    table_raw__remove_component :: proc(self: ^Table_Raw, target_eid: entity_id, loc:= #caller_location) -> (err: Error) {
        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found 

        target := self.eid_to_ptr[target_eid.ix]

        // Check if component exists
        if target == nil do return oc.Core_Error.Not_Found
        
        T_size := self.type_info.size
        rows := raw_data(self.rows)

        tail_rid := raw.len - 1
        tail_eid := self.rid_to_eid[tail_rid] 

        assert(tail_eid.ix != DELETED_INDEX)

        tail := self.eid_to_ptr[tail_eid.ix]
        assert(tail != nil)
        
        target_rid := int(uintptr(target) - uintptr(&self.rows[0])) / T_size

        // Replace removed component with tail
        if target == tail {
            // Remove indexes
            self.eid_to_ptr[target_eid.ix] = nil
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
            mem.copy(target, tail, T_size)

            // Update tail indexes
            self.eid_to_ptr[tail_eid.ix] = target
            self.eid_to_ptr[target_eid.ix] = nil

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
        db__remove_component(self.db, target_eid, self.id)

        return
    }

    // clear data, nothing else
    table_raw__clear :: proc (self: ^Table_Raw, zero_components := true) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.rid_to_eid != nil {
            for i := 0; i < len(self.rid_to_eid); i+=1 do self.rid_to_eid[i].ix = DELETED_INDEX
        }

        slice.zero(self.eid_to_ptr)
       
        if zero_components && self.cap > 0 && self.rows != nil {
            raw := (^runtime.Raw_Slice)(&self.rows)
            mem.zero(raw_data(self.rows), self.type_info.size * raw.len)
        }
        (^runtime.Raw_Slice)(&self.rows).len = 0

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Table

    // Components table
    Table :: struct($T: typeid) {
        using base: Table_Base,
        // table_record_id => component
        rows: []T,     
    }

    table_init :: proc(self: ^Table($T), db: ^Database, cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(db != nil, loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // table should be NOT_INITIALIZED
            assert(db.state == Object_State.Normal, loc = loc) // db should be initialized
            assert(cap <= db.id_factory.cap, loc = loc) // cannot be larger than entities_cap
        }

        self.type_info = type_info_of(typeid_of(T))

        table_base__init(&self.base, db, cap) or_return 

        self.rows = make([]T, cap, db.allocator) or_return
        
        self.id = db__attach_table(db, self) or_return

        self.state = Object_State.Normal

        table_raw__clear(cast(^Table_Raw)self) or_return 

        return nil
    }

    table_terminate :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.type_info.id == typeid_of(T))
            assert(self.db != nil)
        }

        table_raw__terminate(cast(^Table_Raw) self) or_return

        return nil
    }

    table__add_component :: proc(self: ^Table($T), eid: entity_id) -> (component: ^T, err: Error) {
        err = db__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len >= self.cap do return nil, oc.Core_Error.Container_Is_Full 

        component = cast(^T) self.eid_to_ptr[eid.ix]

        // Check if component already exist
        if component == nil {
            // Get component
            #no_bounds_check {
                component = &self.rows[raw.len]
            }
                        
            // Update eid_to_ptr
            self.eid_to_ptr[eid.ix] = component

            // Update rid_to_eid
            self.rid_to_eid[raw.len] = eid

            // Update eid_to_bits in db
            db__add_component(self.db, eid, self.id)

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

    remove_component :: proc(self: ^Table($T), eid: entity_id, loc:= #caller_location) -> Error {
        db__is_entity_correct(self.db, eid) or_return
       
        return table_raw__remove_component(cast(^Table_Raw) self, eid, loc)
    }

    table_len :: #force_inline proc "contextless" (self: ^Table($T)) -> int {
        return (^runtime.Raw_Slice)(&self.rows).len
    }

    table_cap :: #force_inline proc "contextless" (self: ^Table($T)) -> int {
        return self.cap
    }

    @(require_results)
    get_component_by_entity :: proc (self: ^Table($T), eid: entity_id) -> ^T {
        err := db__is_entity_correct(self.db, eid)
        if err != nil do return nil

        return cast(^T) self.eid_to_ptr[eid.ix]
    }

    @(require_results)
    has_component :: proc (self: ^Table($T), eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := db__is_entity_correct(self.db, eid)
        if err != nil do return false

        return self.eid_to_ptr[eid.ix] != nil
    }

    get_entity_from_table :: #force_inline proc "contextless" (self: ^Table($T), #any_int record_index: int) -> entity_id {
        return self.rid_to_eid[record_index]
    }

    table_memory_usage :: proc (self: ^Table_Base) -> int {    
        total := size_of(self^)

        if self.rid_to_eid != nil {
            total += size_of(self.rid_to_eid[0]) * len(self.rid_to_eid)
        }

        if self.eid_to_ptr != nil {
            total += size_of(self.eid_to_ptr[0]) * len(self.eid_to_ptr)
        }

        // rows
        total += self.type_info.size * self.cap

        total += oc.dense_arr__memory_usage(&self.subscribers)

        return total
    }
 
    // Component data for entity `eid`` is copied into `dest` table from `src` table and linked to enitity `eid`
    copy_component :: proc(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        src_component = get_component_by_entity(src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found // component not found

        dest_component = get_component_by_entity(dest, eid) // if it exists we will overwrite data
        if dest_component == nil {
            dest_component = add_component(dest, eid) or_return 
        }

        // copy data
        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    // Component data for entity `eid`` is moved into `dest` table from `src` table and linked to enitity `eid`
    move_component :: proc(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = copy_component(dest, src, eid) or_return

        remove_component(src, eid) or_return

        return dest_component, nil
    }

    table_clear :: proc(self: ^Table($T)) {
        when VALIDATIONS {
            assert(self != nil)
        }
        table_raw__clear((^Table_Raw)(self), true)
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



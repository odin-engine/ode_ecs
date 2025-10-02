/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:log"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table_Base 

    @(private)
    Tiny_Table_Base :: struct {
        using shared: Shared_Table,

        type_info: ^runtime.Type_Info,
        rid_to_eid: [TINY_TABLE__ROW_CAP]entity_id,
        eid_to_ptr: oc_maps.Tt_Map(TINY_TABLE__MAP_CAP, rawptr),
        subscribers: [TINY_TABLE__VIEWS_CAP]^View,
        len: int,
    }

    @(private)
    tiny_table_base__is_valid :: proc (self: ^Tiny_Table_Base) -> bool {
        if self == nil do return false 
        if !shared_table__is_valid_internal(&self.shared) do return false 
        if self.type_info == nil do return false 

        return true 
    }

    @(private)
    tiny_table_base__init :: proc(self: ^Tiny_Table_Base, db: ^Database) -> Error {
        shared_table__init(&self.shared, Table_Type.Tiny_Table, db)

        self.id = database__attach_table(db, self) or_return
        self.state = Object_State.Normal

        return nil
    }

    @(private)
    tiny_table_base__terminate :: proc(self: ^Tiny_Table_Base) ->Error {

        database__detach_table(self.db, self)

        shared_table__clear_state(&self.shared)

        return nil
    }

    @(private)
    tiny_table_base__attach_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if self.subscribers[i] == nil {
                self.subscribers[i] = view
                return nil 
            }
        }

        return oc.Core_Error.Container_Is_Full
    }

    @(private)
    tiny_table_base__detach_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if self.subscribers[i] == view {
                self.subscribers[i] = nil
                return nil 
            }
        }

        return oc.Core_Error.Not_Found
    }

    @(private)
    tiny_table_base__len :: #force_inline proc "contextless" (self: ^Tiny_Table_Base) -> int {
        return self.len
    }

    tiny_table_base__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Tiny_Table_Base, #any_int row_number: int) -> entity_id {
        return self.rid_to_eid[row_number]
    }

    tiny_table_base__get_component_by_entity :: proc (self: ^Tiny_Table_Base, eid: entity_id) -> rawptr {
        return oc_maps.tt_map__get(&self.eid_to_ptr, eid.ix)
    }

    tiny_table_base__memory_usage :: proc (self: ^Tiny_Table_Base) -> int { 
        if self == nil || self.type_info == nil do return DELETED_INDEX
        return size_of(self^) + self.type_info.size * TINY_TABLE__ROW_CAP
    }

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table_Raw

    @(private)
    Tiny_Table_Raw :: struct {
        using base: Tiny_Table_Base,
        rows: [1]byte,
    }

    @(private)
    tiny_table_raw__remove_component :: proc(self: ^Tiny_Table_Raw, target_eid: entity_id) -> (err: Error) {
        if self.len <= 0 do return oc.Core_Error.Not_Found 

        target := oc_maps.tt_map__get(&self.eid_to_ptr,  target_eid.ix)

        // Check if component exists
        if target == nil do return oc.Core_Error.Not_Found
        
        T_size := self.type_info.size

        tail_rid := self.len - 1
        tail_eid := self.rid_to_eid[tail_rid] 

        assert(tail_eid.ix != DELETED_INDEX)

        tail :=oc_maps.tt_map__get(&self.eid_to_ptr, tail_eid.ix)
        assert(tail != nil)
        
        target_rid := int(uintptr(target) - uintptr(&self.rows[0])) / T_size

        // Replace removed component with tail
        if target == tail {
            // Remove indexes
            oc_maps.tt_map__remove(&self.eid_to_ptr, target_eid.ix)
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                view := self.subscribers[i]
                if view != nil do view__remove_record(view, target_eid)
            }
        }
        else {
            tail_eid := self.rid_to_eid[tail_rid]
            assert(tail_eid.ix != DELETED_INDEX)

            // DATA COPY
            mem.copy(target, tail, T_size)

            // Update tail indexes
            oc_maps.tt_map__add(&self.eid_to_ptr, tail_eid.ix, target)
            oc_maps.tt_map__remove(&self.eid_to_ptr, target_eid.ix)

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            // Notify subscribed views
            for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                view := self.subscribers[i]
                if view != nil && !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component(view, self, tail_eid, rawptr(target))
                }
            }
        }

        // Zero tail
        mem.zero(tail, T_size)
        self.len -= 1

        // Update eid_to_bits in db
        database__remove_component(self.db, target_eid, self.id)

        return
    }

    // clear data, nothing else
    tiny_table_raw__clear :: proc (self: ^Tiny_Table_Raw, zero_components := true) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        for i := 0; i < TINY_TABLE__ROW_CAP; i+=1 do self.rid_to_eid[i].ix = DELETED_INDEX

        oc_maps.tt_map__clear(&self.eid_to_ptr)
        
        if zero_components {
            mem.zero(&self.rows, self.type_info.size * self.len)
        }
        self.len = 0

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table

    Tiny_Table :: struct($T: typeid) {
        using base: Tiny_Table_Base, 
        rows: [TINY_TABLE__ROW_CAP]T,       
    }

    tiny_table__is_valid :: proc (self: ^Tiny_Table($T)) -> bool {
        if self == nil do return false 
        if !tiny_table_base__is_valid(&self.base) do return false

        return true
    }

    tiny_table__init :: proc(self: ^Tiny_Table($T), db: ^Database, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // table should be NOT_INITIALIZED
        }

        if size_of(T) == 0 do return API_Error.Component_Size_Cannot_Be_Zero

        self.type_info = type_info_of(typeid_of(T))
        tiny_table_base__init(cast(^Tiny_Table_Base) self, db) or_return
        tiny_table_raw__clear(cast(^Tiny_Table_Raw) self, false) or_return

        return nil
    }

    tiny_table__terminate :: proc(self: ^Tiny_Table($T), loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc) // table should be Normal
            assert(self.db.state == Object_State.Normal, loc = loc) // db should be Normal
        }

        tiny_table_base__terminate(cast(^Tiny_Table_Base) self) or_return

        return nil
    }

    tiny_table__add_component :: proc(self: ^Tiny_Table($T), eid: entity_id) -> (component: ^T, err: Error) {
        err = database__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        if self.len >= TINY_TABLE__ROW_CAP do return nil, oc.Core_Error.Container_Is_Full 

        component = cast(^T) oc_maps.tt_map__get(&self.eid_to_ptr, eid.ix)

        // Check if component already exist
        if component == nil {
            // Get component
            component = &self.rows[self.len]
            
            // Update eid_to_ptr
            err = oc_maps.tt_map__add(&self.eid_to_ptr, eid.ix, cast(rawptr) component)
            if err != nil do return nil, err

            // Update rid_to_eid
            self.rid_to_eid[self.len] = eid

            // Update eid_to_bits in db
            database__add_component(self.db, eid, self.id)

            self.len += 1
        } else {
            err = API_Error.Component_Already_Exist
        }

        // Notify subscribed views
        for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
            view := self.subscribers[i]
            if view != nil && !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }

        return 
    }

    tiny_table__remove_component :: proc(self: ^Tiny_Table($T), eid: entity_id) -> (err: Error) {
        database__is_entity_correct(self.db, eid) or_return

        return tiny_table_raw__remove_component(cast(^Tiny_Table_Raw) self, eid)
    }

    @(require_results)
    tiny_table__get_component_by_entity :: proc (self: ^Tiny_Table($T), eid: entity_id) -> ^T {
        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        return cast(^T) tiny_table_base__get_component_by_entity(self, eid)
    }

    tiny_table__len :: #force_inline proc "contextless" (self: ^Tiny_Table($T)) -> int {
        return tiny_table_base__len(cast(^Tiny_Table_Base) self)
    }

    tiny_table__cap :: #force_inline proc "contextless" (self: ^Shared_Table) -> int {
        return TINY_TABLE__ROW_CAP
    }

    @(require_results)
    tiny_table__has_component :: proc (self: ^Tiny_Table($T), eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return oc_maps.tt_map__get(&self.eid_to_ptr, eid.ix) != nil
    }

    tiny_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Tiny_Table($T), #any_int row_number: int) -> entity_id {
        return tiny_table_base__get_entity_by_row_number(self, row_number)
    }

    tiny_table__memory_usage :: proc (self: ^Tiny_Table($T)) -> int {    
        return tiny_table_base__memory_usage(cast(^Tiny_Table_Base) self)
    }
 
    // Component data for entity `eid`` is copied into `dest` table from `src` table and linked to enitity `eid`
    tiny_table__copy_component :: proc(dest: ^Tiny_Table($T), src: ^Tiny_Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        src_component = tiny_table__get_component_by_entity(src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found // component not found

        dest_component = tiny_table__get_component_by_entity(dest, eid) // if it exists we will overwrite data
        if dest_component == nil {
            dest_component = tiny_table__add_component(dest, eid) or_return 
        }

        // copy data
        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    // Component data for entity `eid`` is moved into `dest` table from `src` table and linked to enitity `eid`
    tiny_table__move_component :: proc(dest: ^Tiny_Table($T), src: ^Tiny_Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = tiny_table__copy_component(dest, src, eid) or_return

        tiny_table__remove_component(src, eid) or_return

        return dest_component, nil
    }

    tiny_table__clear :: proc(self: ^Tiny_Table($T)) {
        when VALIDATIONS {
            assert(self != nil)
        }
        tiny_table_raw__clear((^Tiny_Table_Raw)(self), true)
    }


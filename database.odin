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

///////////////////////////////////////////////////////////////////////////////
// Database

    Database :: struct {
        allocator: runtime.Allocator,
        state: Object_State, 

        id_factory: oc.Ix_Gen_Factory,
        
        tables: oc.Sparce_Arr(Shared_Table),

        views: oc.Sparce_Arr(View), 

        eid_to_bits: []Uni_Bits, 
    }

    database__init :: proc(self: ^Database, entities_cap: int, allocator := context.allocator) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Not_Initialized)
            assert(TABLES_CAP > 1)
            assert(VIEWS_CAP > 1)
        }

        if entities_cap <= 0 do return API_Error.Entities_Cap_Should_Be_Greater_Than_Zero
        
        self.allocator = allocator

        oc.ix_gen_factory__init(&self.id_factory, entities_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.tables, TABLES_CAP, self.allocator) or_return
        oc.sparse_arr__init(&self.views, VIEWS_CAP, self.allocator) or_return

        self.eid_to_bits = make([]Uni_Bits, entities_cap, self.allocator) or_return

        self.state = Object_State.Normal

        return nil
    }

    database__terminate :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.eid_to_bits != nil do delete(self.eid_to_bits, self.allocator) or_return

        // Views
        for view in self.views.items {
            if view == nil do continue 
            if view.state == Object_State.Normal do view_terminate(view) or_return
        }
        oc.sparse_arr__terminate(&self.views, self.allocator) or_return

        // Shared Tables
        for table in self.tables.items {
            if table == nil do continue 
            if table.state == Object_State.Normal {
                shared_table__terminate(table)
            } 
        }
        oc.sparse_arr__terminate(&self.tables, self.allocator) or_return 

        oc.ix_gen_factory__terminate(&self.id_factory, self.allocator) or_return

        self.state = Object_State.Terminated
        return nil
    }

    database__clear :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.eid_to_bits != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        slice.zero(self.eid_to_bits)

        for view in self.views.items {
            if view != nil {
                view__clear(view) or_return
            }
        }

        for table in self.tables.items {
            if table != nil {
                shared_table__clear(table) or_return 
            }
        } 

        oc.ix_gen_factory__clear(&self.id_factory)

        return nil
    }

    @(require_results)
    database__create_entity :: proc(self: ^Database) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        
        return oc.ix_gen_factory__new_id(&self.id_factory)
    }

    database__destroy_entity :: proc(self: ^Database, eid: entity_id) -> Error  {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }
        
        database__is_entity_correct(self, eid) or_return

        err: Error = nil 

        table: ^Table_Base
        bits := self.eid_to_bits[eid.ix]

        for table in self.tables.items {  
            if table == nil do continue
            if int(table.id) not_in bits  do continue

            shared_table__remove_component(table, eid) or_return
        } 

        // clean bit_sets
        uni_bits__clear(&self.eid_to_bits[eid.ix])

        oc.ix_gen_factory__free_id(&self.id_factory, eid) or_return

        return err
    }

    @(require_results)
    database__get_entity :: #force_inline proc "contextless" (self: ^Database, #any_int index: int, loc := #caller_location) -> entity_id {
        return oc.ix_gen_factory__get_id(&self.id_factory, index, loc)
    }

    @(require_results)
    database__entities_len :: #force_inline proc "contextless" (self: ^Database) -> int {
        return oc.ix_gen_factory__len(&self.id_factory)
    }

    @(require_results)
    database__is_entity_expired :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> bool {
        // Happens when eid.gen do not match. It means eid expired (was deleted)
        return oc.ix_gen_factory__is_expired(&self.id_factory, eid)
    }

    database__memory_usage :: proc (self: ^Database) -> int {
        total := size_of(self^)

        total += oc.ix_gen_factory__memory_usage(&self.id_factory)
        for table in self.tables.items {
            if table != nil do total += shared_table__memory_usage(table)
        }

        for view in self.views.items {
            if view != nil do total += view__memory_usage(view)
        }

        return total
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    // Returns index of table in self.tables
    @(private)
    database__attach_table :: proc(self: ^Database, table: ^Shared_Table) -> (table_id, Error) {
        id, err := oc.sparse_arr__add(&self.tables, table)
        if err != oc.Core_Error.None do return DELETED_INDEX, err

        return cast(table_id) id, nil
    }

    @(private)
    database__detach_table :: proc(self: ^Database, table: ^Shared_Table) {
        oc.sparse_arr__remove_by_index(&self.tables, cast(int) table.id)
    }

    @(private)
    database__attach_view :: proc(self: ^Database, view: ^View) -> (view_id, Error) {
        id, err := oc.sparse_arr__add(&self.views, view)
        if err != oc.Core_Error.None do return DELETED_INDEX, err

        return cast(view_id) id, nil
    }

    @(private)
    database__detach_view :: proc(self: ^Database, view: ^View) {
        oc.sparse_arr__remove_by_index(&self.views, cast(int) view.id)
    }

    @(private)
    database__add_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) {
        uni_bits__add(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    database__remove_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) {
        uni_bits__remove(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    database__is_entity_correct :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> Error {
        if eid.ix < 0 || eid.ix >= self.id_factory.cap do return API_Error.Entity_Id_Out_of_Bounds
        if database__is_entity_expired(self, eid) do return API_Error.Entity_Id_Expired
        return nil
    }
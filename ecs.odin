/*
    What is ECS?  

    ECS is esentially a simple database in memory.
    Entity = id
    Component instance = a record in a table
    Component Type = table 

    entity_id = id of Entity
    table_id = table index (internal table name)
    table_record_id = record id (index) in table
    
    System - is just a business logic that processes database queries.
*/
package ode_ecs

// Base
    import "base:runtime"
    
// Core
    import "core:log"
    import "core:fmt"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Defines

    // If true, procedures validate parameters and their states using asserts.
    // Set it to false if you 100% know what you are doing and want a slight speed 
    // increase.
    VALIDATIONS :: #config(ecs_validations, true)
   
    BIT_SET_VALUES_CAP :: 128

    // Like in other ECSs we use bit_set to store info about what components an entity has.
    // By default one bit_set can store info about 128 types of components, 
    // if you increase TABLES_BIT_SET_COUNT number to 2,
    // ODE ECS will store info about 256 types of components, if 3 then 384, 4 = 512, etc. 
    // You can have unlimited number of types of components (as long as you have memory). 
    TABLES_BIT_SET_COUNT :: #config(ecs_tables_bit_set_count, 1)
    
    // Maximum number of tables (component types)
    TABLES_CAP :: BIT_SET_VALUES_CAP * TABLES_BIT_SET_COUNT

    // Maximum number of views
    VIEWS_CAP :: #config(ecs_views_cap, TABLES_CAP)

    DELETED_INDEX :: oc.DELETED_INDEX

///////////////////////////////////////////////////////////////////////////////
// Public API 
//
//  API proc name        | Internal proc name   

    // Database
    init                :: db__init
    terminate           :: db__terminate
    clear               :: db__clear
    create_entity       :: db__create_entity
    destroy_entity      :: db__destroy_entity
    is_expired          :: db__is_expired               // to check if entity expired
    memory_usage        :: proc {
        db__memory_usage,
        table__memory_usage,
        view__memory_usage,
    }

    // Table
    table_init          :: table__init
    table_terminate     :: table__terminate
    add_component       :: table__add_component
    remove_component    :: table__remove_component
    get_component       :: proc {
        table__get_component_by_entity_id,
        iterator__get_component, 
    }
    table_len           :: table__len
    table_cap           :: table__len
    get_entity          :: proc {
        table__get_entity,
        iterator__get_entity,
    }

    // View 
    view_init           :: view__init
    view_terminate      :: view__terminate
    rebuild             :: view__rebuild
    view_len            :: view__len
    view_cap            :: view__cap
    view_clear          :: view__clear
    view_entity_match   :: view__entity_match

    // Iterator
    iterator_init       :: iterator__init
    iterator_reset      :: iterator__init // same as init
    iterator_next       :: iterator__next

///////////////////////////////////////////////////////////////////////////////
// Types

    //
    // IDs
    //

        entity_id ::        oc.ix_gen
        table_id ::         distinct int 
        table_record_id ::  distinct int
        view_id ::          distinct int
        view_record_id ::   distinct int
        view_column_id ::   int

    //
    // Enums
    //

        Object_State :: enum {
            Not_Initialized = 0,
            Normal,
            Invalid,                // when related object (Table) is terminated, current object(View) could become invalid
            Terminated,
        }

        // ECS specific errors
        API_Error :: enum {
            None = 0,
            Entities_Cap_Should_Be_Greater_Than_Zero,
            Component_Already_Exist,
            Tables_Array_Should_Not_Be_Empty,
            Unexpected_Error,
            Entity_Id_Out_of_Bounds,
            Entity_Id_Expired, // generations do not match
            Cannot_Add_Record_To_View_Container_Is_Full,
            Object_Invalid,
        }

        Error :: union #shared_nil {
            API_Error,
            oc.Core_Error,
            runtime.Allocator_Error
        }

///////////////////////////////////////////////////////////////////////////////
// Database

    Database :: struct {
        allocator: runtime.Allocator,
        state: Object_State, 

        id_factory: oc.Ix_Gen_Factory,
        
        tables: oc.Sparce_Arr(Table_Base),
        views: oc.Sparce_Arr(View), 

        eid_to_bits: []Uni_Bits, 
    }

    db__init :: proc(self: ^Database, entities_cap: int, allocator := context.allocator) -> Error {
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

    db__terminate :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.eid_to_bits != nil do delete(self.eid_to_bits, self.allocator) or_return

        view: ^View
        for view in self.views.items {
            if view == nil do continue 
            if view.state == Object_State.Normal do view__terminate(view) or_return
        }

        oc.sparse_arr__terminate(&self.views, self.allocator) or_return

        table: ^Table_Base
        for table in self.tables.items {
            if table == nil do continue 
            if table.state == Object_State.Normal do table_raw__terminate(cast(^Table_Raw)table) or_return
        }
        
        oc.sparse_arr__terminate(&self.tables, self.allocator) or_return
        oc.ix_gen_factory__terminate(&self.id_factory, self.allocator) or_return

        self.state = Object_State.Terminated
        return nil
    }

    db__clear :: proc(self: ^Database) {
        // TODO: implement
    }

    @(require_results)
    db__create_entity :: proc(self: ^Database) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        
        return oc.ix_gen_factory__new_id(&self.id_factory)
    }

    db__destroy_entity :: proc(self: ^Database, eid: entity_id) -> Error  {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }
        
        db__is_entity_correct(self, eid) or_return

        err: Error = nil 

        table: ^Table_Base
        for table in self.tables.items {  
            if table == nil do continue

            err = table_raw__remove_component(cast(^Table_Raw)table, eid)
            if err != nil {
                log.error("Unable to remove component from", table, ". Error: ", err)
                return err
            }
        } 

        // clean bit_sets
        bits__clear(&self.eid_to_bits[eid.ix])

        oc.ix_gen_factory__free_id(&self.id_factory, eid) or_return

        return err
    }

    @(require_results)
    db__is_expired :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> bool {
        // Happens when eid.gen do not match. It means eid expired (was deleted)
        return oc.ix_gen_factory__is_expired(&self.id_factory, eid)
    }

    db__memory_usage :: proc (self: ^Database) -> int {
        total := size_of(self^)

        total += oc.ix_gen_factory__memory_usage(&self.id_factory)
        for table in self.tables.items {
            if table != nil do total += table__memory_usage(table)
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
    db__attach_table :: proc(self: ^Database, table: ^Table_Base) -> (table_id, Error) {
        id, err := oc.sparse_arr__add(&self.tables, table)
        if err != oc.Core_Error.None do return DELETED_INDEX, err

        return cast(table_id) id, nil
    }
    
    @(private)
    db__detach_table :: proc(self: ^Database, table: ^Table_Base) {
        oc.sparse_arr__remove_by_index(&self.tables, cast(int) table.id)
    }

    @(private)
    db__attach_view :: proc(self: ^Database, view: ^View) -> (view_id, Error) {
        id, err := oc.sparse_arr__add(&self.views, view)
        if err != oc.Core_Error.None do return DELETED_INDEX, err

        return cast(view_id) id, nil
    }
    
    @(private)
    db__detach_view :: proc(self: ^Database, view: ^View) {
        oc.sparse_arr__remove_by_index(&self.views, cast(int) view.id)
    }

    @(private)
    db__add_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) {
        uni_bits__add(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    db__remove_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) {
        uni_bits__remove(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    db__is_entity_correct :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> Error {
        if eid >= cast(entity_id)self.id_factory.cap do return API_Error.Entity_Id_Out_of_Bounds
        if db__is_expired(self, eid) do return API_Error.Entity_Id_Expired
        return nil
    }
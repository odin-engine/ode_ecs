/*
    2025 (c) Oleh, https://github.com/zm69

    ODE_ECS is an fast sparse/dense ECS with tail swap, written in Odin.  
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
//  API proc name        | Internal proc name (grouped by file name) 

    //
    // Database (db)
    //
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

    //
    // Table
    //
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
    table_clear         :: table_raw__clear

    //
    // View 
    //
    view_init           :: view__init
    view_terminate      :: view__terminate
    rebuild             :: view__rebuild
    view_len            :: view__len
    view_cap            :: view__cap
    view_clear          :: view__clear
    view_entity_match   :: view__entity_match
    suspend             :: view__suspend
    resume              :: view__resume

    //
    // Iterator
    //
    iterator_init       :: iterator__init
    iterator_reset      :: iterator__init // same as init
    iterator_next       :: iterator__next

///////////////////////////////////////////////////////////////////////////////
// Basic types

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


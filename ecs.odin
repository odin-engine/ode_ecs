/*
    2025 (c) Oleh, https://github.com/zm69

    ODE_ECS is an fast sparse/dense ECS with tail swap, written in Odin.  
*/
package ode_ecs

// Base
    import "base:runtime"
    
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
    // if you increase TABLES_MULT number to 2,
    // ODE ECS will store info about 256 types of components, if 3 then 384, 4 = 512, etc. 
    // You can have unlimited number of types of components (as long as you have memory). 
    TABLES_MULT :: #config(ecs_tables_mult, 1)
    
    // Maximum number of tables (component types)
    TABLES_CAP :: BIT_SET_VALUES_CAP * TABLES_MULT

    // Maximum number of views
    VIEWS_CAP :: #config(ecs_views_cap, TABLES_CAP)

    DELETED_INDEX :: oc.DELETED_INDEX

///////////////////////////////////////////////////////////////////////////////
// Proc groups and aliases
//

    clear               :: proc {  // only data clear
        db_clear,                    
        table_clear,
        view_clear,
    }

    get_entity          :: proc {
        get_entity_from_db,
        get_entity_from_table,
        get_entity_by_iterator,
    }

    entities_count      :: entities_len
 
    memory_usage        :: proc {
        db_memory_usage,
        table_memory_usage,
        view_memory_usage,
    }

    get_component       :: proc {
        get_component_by_entity,
        get_component_by_iterator, 
    }
 
    table_clear         :: table_raw__clear // clear all data from table
    iterator_reset      :: iterator_init // same as init
    
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


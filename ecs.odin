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
    VALIDATIONS :: #config(ECS_VALIDATIONS, true)
   
    BIT_SET_VALUES_CAP :: 128 // don't change this unless Odin changes how many bits can be stored in a bit_set

    // Like in other ECSs we use bit_set to store info about what components an entity has.
    // By default one bit_set can store info about 128 types of components, 
    // if you increase TABLES_MULT number to 2,
    // ODE ECS will store info about 256 types of components, if 3 then 384, 4 = 512, etc. 
    // You can have unlimited number of types of components (as long as you have memory). 
    TABLES_MULT :: #config(ECS_TABLES_MULT, 1)
    
    // Maximum number of tables (component types)
    TABLES_CAP :: BIT_SET_VALUES_CAP * TABLES_MULT

    // Maximum number of views
    VIEWS_CAP :: #config(ECS_VIEWS_CAP, TABLES_CAP)

    // -1 by default, just to see if index is not used or incorrect
    DELETED_INDEX :: oc.DELETED_INDEX

    //
    // Tiny_Table
    //

        // You can change this if you want but remember that rows are not dynamically allocated for Tiny_Table and
        // are just a part of Tiny_Table struct.
        TINY_TABLE__ROW_CAP :: 8        // Tiny_Table can contain maximum TINY_TABLE__ROW_CAP number of components
        TINY_TABLE__VIEWS_CAP :: 8      // Only maximum TINY_TABLE__VIEWS_CAP number of Views can subsribe to Tiny_Table 
        TINY_TABLE__MAP_CAP :: 32       // Should be power of 2

///////////////////////////////////////////////////////////////////////////////
// Aliases
// 

    //
    // Database
    //
        init                    :: database__init
        terminate               :: database__terminate
        entities_len            :: database__entities_len               
        create_entity           :: database__create_entity
        destroy_entity          :: database__destroy_entity
        is_entity_expired       :: database__is_entity_expired      // Generation of entity in database does not match the one in provided entity_id

    //
    // Table 
    //
        table_init              :: table__init
        table_terminate         :: table__terminate

    //
    // View
    //
        view_init               :: view__init
        view_terminate          :: view__terminate
        view_len                :: view__len                        // Number of rows in view
        view_cap                :: view__cap                        // Maximum number of rows of view
        rebuild                 :: view__rebuild                    // Rebuild view and fill it with entities matching view's tables
        view_components_match   :: view__components_match           // Returns true if entity has components that would match this view, doesn't check filter
        suspend                 :: view__suspend                    // Stop updating view when entities are created/destroyed or components/tags are added/removed     
        resume                  :: view__resume                     // Resume updating view after calling suspend 
    
    //
    // Iterator
    //
        iterator_init       :: iterator__init
        iterator_next       :: iterator__next   
        iterator_reset      :: iterator__reset

    //
    // Outdated aliases (will be removed in future)
    // 
        view_entity_match   :: view__components_match               // outdated, use view_components_match instead

    //
    // Proc groups
    // 

        //
        // Entity
        //

        // Get entity_id from different objects
        get_entity          :: proc {
            database__get_entity,
            table__get_entity_by_row_number,
            compact_table__get_entity_by_row_number,
            tiny_table_base__get_entity_by_row_number,
            iterator__get_entity,
            view_row__get_entity,
        }

        // Get entity_id by row number from different tables
        get_entity_by_row_number :: proc {
            table__get_entity_by_row_number, 
            compact_table__get_entity_by_row_number, 
            tiny_table__get_entity_by_row_number,
        }

        //
        // Component
        //

        // Add component to different tables
        add_component       :: proc {
            table__add_component,
            compact_table__add_component,
            tiny_table__add_component,
        }

        // Remove component from different tables
        remove_component    :: proc {
            table__remove_component,
            compact_table__remove_component,
            tiny_table__remove_component,
        }

        // Get component from different tables or iterator or view_row
        get_component       :: proc {
            table__get_component_by_entity,
            compact_table__get_component_by_entity,
            iterator__get_component_for_table, 
            iterator__get_component_for_small_table, 
            iterator__get_component_for_tiny_table,
            tiny_table__get_component_by_entity,
            view_row__get_component_for_table,
            view_row__get_component_for_small_table,
            view_row__get_component_for_tiny_table,
        }

        // Check if entity has component in different tables
        has_component       :: proc {
            table__has_component,
            compact_table__has_component,
            tiny_table__has_component,
        }

        // Copy components between tables of the same type
        copy_component      :: proc {
            table__copy_component,
            compact_table__copy_component,
            tiny_table__copy_component,
        }

        // Move components between tables of the same type
        move_component      :: proc {
            table__move_component,
            compact_table__move_component,
            tiny_table__move_component,
        }

        //
        // Tags
        //

        add_tag :: proc {
            tag_table__add_tag,
        }
        tag :: add_tag

        remove_tag :: proc {
            tag_table__remove_tag,
        }
        untag :: remove_tag

        //
        // Other
        //

        // Clear all data but do not terminate object
        clear               :: proc {  // only data clear
            database__clear,                    
            table__clear,
            compact_table__clear,
            view__clear,
            table_raw__clear,
            tiny_table__clear,
            tag_table__clear,
        }

        table_len           :: proc {
            table__len,
            compact_table__len,
            tiny_table__len,
            tag_table__len,
        }

        table_cap           :: proc {
            table__cap,
            compact_table__cap,
            tiny_table__cap, 
            tag_table__cap,
        }
 
        // Memory in bytes
        memory_usage        :: proc {
            database__memory_usage,
            table__memory_usage,
            compact_table__memory_usage,
            view__memory_usage,
            tiny_table__memory_usage,
            tag_table__memory_usage,
        }

        // Is object valid (initialized and everything is ok)
        is_valid            :: proc {
            database__is_valid,
            table__is_valid,
            compact_table__is_valid,
            view__is_valid,
            tiny_table__is_valid,
            tag_table__is_valid,
        }

///////////////////////////////////////////////////////////////////////////////
// Basic types

    //
    // IDs
    //
    
        entity_id ::        oc.ix_gen           // index + generation
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

        Table_Type :: enum {
            Unknown = 0,
            Table,
            Tiny_Table,
            Compact_Table,
            Tag_Table,
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
            Component_Size_Cannot_Be_Zero,
        }

        Error :: union #shared_nil {
            API_Error,
            oc.Core_Error,
            oc.Error, 
            runtime.Allocator_Error
        }
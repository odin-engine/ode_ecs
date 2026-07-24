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
        pause_tail_swap         :: database__pause_packing
        resume_tail_swap        :: database__resume_packing

    //
    // Overbase (shared entity ID space, see overbase.odin). Attach a Database
    // to one with init_from_overbase instead of init to share entities across
    // Databases; create_entity/destroy_entity/is_expired/entities_len/get_entity
    // below all accept either a ^Database or a ^Overbase.
    //
        overbase_init           :: overbase__init
        overbase_terminate      :: overbase__terminate
        init_from_overbase      :: database__init_from_overbase

        entities_len :: proc {
            database__entities_len,
            overbase__entities_len,
        }

        create_entity :: proc {
            database__create_entity,
            overbase__create_entity,
        }

        // Generation of entity does not match the one in provided entity_id
        destroy_entity :: proc {
            database__destroy_entity,
            overbase__destroy_entity,
        }

        is_expired :: proc {
            database__is_entity_expired,
            overbase__is_entity_expired,
        }

    //
    // Serialization (binary snapshot of a whole Database, see serialization.odin)
    //
        serialized_size         :: database__serialized_size    // Exact buffer size serialize will need for the current state
        serialize               :: database__serialize          // Write a snapshot into a caller-provided buffer (zero allocations)
        deserialize             :: database__deserialize        // Load a snapshot into an initialized database with a matching schema
        save_to_file            :: database__save_to_file       // serialize + write to a file
        load_from_file          :: database__load_from_file     // read a file + deserialize

    //
    // Overbase serialization (binary snapshot of just the shared entity-id
    // space, see overbase_serialization.odin). Use this to save/restore the
    // id-space of an Overbase shared by multiple Databases — a Database's own
    // serialize/deserialize never touches a shared Overbase's id-space.
    //
        overbase_serialized_size :: overbase__serialized_size
        overbase_serialize       :: overbase__serialize
        overbase_deserialize     :: overbase__deserialize
        overbase_save_to_file    :: overbase__save_to_file
        overbase_load_from_file  :: overbase__load_from_file

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
        refilter                :: view__refilter                   // Re-evaluate the view's filter for all rows and candidates in one sweep (after bulk mutations)
        rerun_filter            :: view__rerun_filter               // Rerun filter for one entity
        view_components_match   :: view__components_match           // Returns true if entity has components that would match this view (includes AND excludes), doesn't check filter
        suspend                 :: view__suspend                    // Stop updating view when entities are created/destroyed or components/tags are added/removed
        resume                  :: view__resume                     // Resume updating view after calling suspend
        view_dense_slice        :: view__dense_slice                // Components in view-row order as one contiguous slice (nil if view is not dense-aligned)
    
    //
    // Group (owned group — enforced dense alignment, see group.odin)
    //
        group_init          :: group__init                          // Take exclusive ownership of tables; members stay in an aligned prefix
        group_terminate     :: group__terminate
        group_len           :: group__len                           // Number of entities in the group
        group_dense_slice   :: group__dense_slice                   // Members' components of one owned table as a contiguous slice, always aligned
        group_rebuild       :: group__rebuild                       // Rebuild membership from scratch (normally maintained incrementally)

    //
    // Iterator
    //
        iterator_init       :: iterator__init
        iterator_next       :: iterator__next
        iterator_reset      :: iterator__reset
        iterate             :: proc{iterator__iterate1, iterator__iterate2, iterator__iterate3, iterator__iterate4} // for-in sugar: for v1, v2 in iterate(&it, &t1, &t2) { ... }; Table($T) columns only

    //
    // Command_Buffer (deferred structural operations, see command_buffer.odin)
    //
        command_buffer_init      :: command_buffer__init          // Preallocate a buffer bound to a Database (commands_cap records, payload_cap bytes)
        command_buffer_terminate :: command_buffer__terminate
        command_buffer_len       :: command_buffer__len           // Number of recorded (not yet replayed) commands
        command_buffer_cap       :: command_buffer__cap
        replay                   :: command_buffer__replay        // Apply all commands in recorded order, then clear the buffer

        cmd_destroy_entity  :: command_buffer__destroy_entity     // Record: destroy entity (optionally with children)
        cmd_add_tag         :: command_buffer__add_tag            // Record: tag entity
        cmd_tag             :: command_buffer__add_tag
        cmd_remove_tag      :: command_buffer__remove_tag         // Record: untag entity
        cmd_untag           :: command_buffer__remove_tag

        // Record: add component with its value (copied into the buffer now,
        // written into the table at replay; overwrites if it already exists)
        cmd_add_component   :: proc {
            command_buffer__add_component_for_table,
            command_buffer__add_component_for_compact_table,
            command_buffer__add_component_for_tiny_table,
        }

        // Record: remove component
        cmd_remove_component :: proc {
            command_buffer__remove_component_for_table,
            command_buffer__remove_component_for_compact_table,
            command_buffer__remove_component_for_tiny_table,
        }

        cmd_set_parent      :: command_buffer__set_parent         // Record: make one entity the parent of another
        cmd_remove_parent   :: command_buffer__remove_parent      // Record: remove entity's parent link
        cmd_unparent        :: command_buffer__remove_parent

    //
    // Relations (parent/child), require a Relations_Table on the database,
    // see relations_table__init
    //
        relations_init      :: relations_table__init                // Attach a Relations_Table to a Database (one per Database)
        relations_terminate :: relations_table__terminate

        set_parent          :: database__set_parent                 // Make one entity the parent of another (replaces previous parent)
        remove_parent       :: database__remove_parent              // Remove entity's parent link
        unparent            :: database__remove_parent
        parent_of           :: database__parent_of                  // Entity's parent id, or id with ix == DELETED_INDEX if none
        children_of         :: database__children_of                // Entity's children as a slice of an internal buffer — use immediately
        children_count      :: database__children_count
        is_child_of         :: database__is_child_of                // Is `a` a child of `b`?
        is_parent_of        :: database__is_parent_of               // Is `a` the parent of `b`?
        has_relations       :: database__has_relations              // Does entity have a parent or children?
        is_relation_of      :: database__is_relation_of             // Does `e` relate to `target` directly (as child or parent)?

    //
    // Outdated aliases (will be removed in future)
    // 
        view_entity_match   :: view__components_match               // outdated, use view_components_match instead
        is_entity_expired   :: database__is_entity_expired          // outdated, use is_expired instead
        is_deleted          :: is_not_set                           // outdated, use is_not_set instead
        iterator__get_component_for_small_table :: iterator__get_component_for_compact_table // outdated, "small" renamed to "compact"

    //
    // Proc groups
    // 

        //
        // Entity
        //

        // Get entity_id from different objects
        get_entity          :: proc {
            database__get_entity,
            overbase__get_entity,
            table__get_entity_by_row_number,
            compact_table__get_entity_by_row_number,
            tiny_table__get_entity_by_row_number,
            tag_table__get_entity_by_row_number,
            iterator__get_entity,
            view_row__get_entity,
        }

        // Get entity_id by row number from different tables
        get_entity_by_row_number :: proc {
            table__get_entity_by_row_number,
            compact_table__get_entity_by_row_number,
            tiny_table__get_entity_by_row_number,
            tag_table__get_entity_by_row_number,
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

        // Rerun filters of views subscribed to a table, for one entity — call after
        // mutating component data a view filter depends on (or use refilter for bulk)
        rerun_views_filters :: proc {
            table__rerun_views_filters,
            compact_table__rerun_views_filters,
            tiny_table__rerun_views_filters,
        }

        // Get component from different tables or iterator or view_row
        get_component       :: proc {
            table__get_component_by_entity,
            compact_table__get_component_by_entity,
            iterator__get_component_for_table,
            iterator__get_component_for_compact_table,
            iterator__get_component_for_tiny_table,
            tiny_table__get_component_by_entity,
            view__get_component_for_table,
            view__get_component_for_compact_table,
            view__get_component_for_tiny_table,
            view_row__get_component_for_table,
            view_row__get_component_for_compact_table,
            view_row__get_component_for_tiny_table,
        }

        // Check if entity has component in different tables
        has_component       :: proc {
            table__has_component,
            compact_table__has_component,
            tiny_table__has_component,
            tag_table__has_tag,
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

        has_tag :: tag_table__has_tag                               // Is entity tagged in this Tag_Table?

        //
        // Other
        //

        // Clear all data but do not terminate object
        clear               :: proc {  // only data clear
            database__clear,
            table__clear,
            compact_table__clear,
            view__clear,
            tiny_table__clear,
            tag_table__clear,
            relations_table__clear,
            command_buffer__clear,
        }

        // Compact holes left by removals made while tail swap was paused,
        // see pause_packing / resume_packing. Callable mid-pause too.
        pack                :: proc {
            table__pack,
            compact_table__pack,
            tiny_table__pack,
            tag_table__pack,
            group__pack,
        }

        // Pause tail swapping — at the Database (all tables + all groups), a
        // single table (rejected with API_Error.Cannot_Pause_Table_Owned_By_Group
        // if owned by a Group), or a Group (all tables it owns, as one atomic
        // unit) level. Table/group-level pause is independent of the
        // database-wide pause — useful to isolate one table or group (e.g. from
        // another thread) without deferring packing everywhere.
        pause_packing       :: proc {
            database__pause_packing,
            table__pause_packing,
            compact_table__pause_packing,
            tiny_table__pause_packing,
            tag_table__pause_packing,
            group__pause_packing,
        }

        // Resume tail swapping and pack whatever holes accumulated at that level.
        resume_packing      :: proc {
            database__resume_packing,
            table__resume_packing,
            compact_table__resume_packing,
            tiny_table__resume_packing,
            tag_table__resume_packing,
            group__resume_packing,
        }

        table_len           :: proc {
            table__len,
            compact_table__len,
            tiny_table__len,
            tag_table__len,
            relations_table__len,
        }

        table_cap           :: proc {
            table__cap,
            compact_table__cap,
            tiny_table__cap,
            tag_table__cap,
            relations_table__cap,
        }
 
        // Memory in bytes
        memory_usage        :: proc {
            database__memory_usage,
            overbase__memory_usage,
            table__memory_usage,
            compact_table__memory_usage,
            view__memory_usage,
            group__memory_usage,
            tiny_table__memory_usage,
            tag_table__memory_usage,
            relations_table__memory_usage,
            command_buffer__memory_usage,
        }

        // Is object valid (initialized and everything is ok)
        is_valid            :: proc {
            database__is_valid,
            overbase__is_valid,
            table__is_valid,
            compact_table__is_valid,
            view__is_valid,
            group__is_valid,
            tiny_table__is_valid,
            tag_table__is_valid,
            relations_table__is_valid,
            command_buffer__is_valid,
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
        view_record_id ::   distinct u32     // view row index; u32 halves the per-view eid_to_rid array
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
            Relations_Table_Already_Exists,   // only one Relations_Table per Database
            Relations_Table_Not_Created,      // relation procs require relations_table__init first
            Relation_Cycle,                   // set_parent would make an entity its own ancestor
            Only_Table_Can_Be_Owned_By_Group, // groups cannot own Compact_Table/Tiny_Table/Tag_Table
            Table_Already_Owned_By_Group,     // a table can have at most one owner group
            Cannot_Pause_Table_Owned_By_Group, // pause/resume_packing reject a table owned by a Group; pause/resume the Group instead
            Table_Cannot_Be_Included_And_Excluded, // view_init got the same table in `includes` and `excludes`
            Snapshot_Invalid,                 // bad magic/endianness, truncated or corrupt snapshot buffer
            Snapshot_Version_Mismatch,        // snapshot was written by an incompatible library version
            Snapshot_Schema_Mismatch,         // tables/types of the target database differ from the saved ones
            Snapshot_Capacity_Too_Small,      // target entities_cap/table cap/relations cap cannot hold the saved data
            Snapshot_Component_Not_POD,       // component contains pointers/slices/strings; pass allow_non_pod to serialize anyway
            Cannot_Serialize_While_Packing_Paused, // resume_packing first so tables hold no holes
            Serialize_Buffer_Too_Small,       // size the buffer with serialized_size
            File_Error,                       // save_to_file/load_from_file could not open/read/write the file
        }

        Error :: union #shared_nil {
            API_Error,
            oc.Core_Error,
            oc.Error, 
            runtime.Allocator_Error
        }

///////////////////////////////////////////////////////////////////////////////
// Globals

    is_not_set :: #force_inline proc "contextless" (e: entity_id) -> bool {
        return e.ix == DELETED_INDEX
    }

/*
    2025 (c) Oleh, https://github.com/zm69

    A high-performance ECS written in Odin.
*/
package ode_ecs

// Base
    import "base:runtime"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Defines

    VALIDATIONS :: #config(ECS_VALIDATIONS, true)

    BIT_SET_VALUES_CAP :: 128

    Bits :: bit_set[0..<BIT_SET_VALUES_CAP]

    TABLES_MULT :: #config(ECS_TABLES_MULT, 1)

    //
    // Initial capacities for various ECS containers (auto-grows if exceeded, outside of the frame loop).
    //

        TABLES_CAP ::  #config(ECS_TABLES_CAP, 16)

        VIEWS_CAP :: #config(ECS_VIEWS_CAP, 16)

        PAIR_TABLES_CAP :: #config(ECS_PAIR_TABLES_CAP, 8)

        COMMAND_BUFFERS_CAP :: #config(ECS_COMMAND_BUFFERS_CAP, 8)

        SUBSCRIBERS_CAP :: #config(ECS_SUBSCRIBERS_CAP, 8)

    //
    // Tiny_Table
    //

        TINY_TABLE__ROW_CAP :: 8
        TINY_TABLE__VIEWS_CAP :: 8
        TINY_TABLE__MAP_CAP :: 32

        TINY_TABLES_CAP :: #config(ECS_TINY_TABLES_CAP, 32)

    //
    // Sync - delta-change replication.
    //

        SYNC_ENABLED :: #config(ECS_SYNC_ENABLED, false)

        SYNC_CHANNELS_CAP :: #config(ECS_SYNC_CHANNELS_CAP, 8)

        TINY_TABLE__SYNC_CHANNELS_CAP :: #config(ECS_TINY_TABLE__SYNC_CHANNELS_CAP, 4)

        SYNC_MAX_FIELDS :: 32

    //
    // Observers- structural-change callbacks.
    //

        OBSERVERS_ENABLED :: #config(ECS_OBSERVERS_ENABLED, false)

        OBSERVERS_CAP :: #config(ECS_OBSERVERS_CAP, 8)

    //
    // Other
    //

        DELETED_INDEX :: oc.DELETED_INDEX

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
    // Overbase
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
            arch_table__create_entity,
        }

        destroy_entity :: proc {
            database__destroy_entity,
            overbase__destroy_entity,
        }

        destroy_entities :: database__destroy_entities

        is_expired :: proc {
            database__is_entity_expired,
            overbase__is_entity_expired,
        }

    //
    // Serialization (binary snapshot of a whole Database)
    //
        serialized_size         :: database__serialized_size
        serialize               :: database__serialize
        deserialize              :: database__deserialize
        save_to_file            :: database__save_to_file
        load_from_file          :: database__load_from_file

    //
    // Overbase serialization
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
    // Compact_Table
    //
        compact_table_init      :: compact_table__init
        compact_table_terminate :: compact_table__terminate

    //
    // Tiny_Table
    //
        tiny_table_init         :: tiny_table__init
        tiny_table_terminate    :: tiny_table__terminate

    //
    // Tag_Table
    //
        tag_table_init          :: tag_table__init
        tag_table_terminate     :: tag_table__terminate

    //
    // Arch_Table
    //
        arch_table_init         :: arch_table__init
        arch_table_terminate    :: arch_table__terminate

    //
    // View
    //

        view_init               :: view__init
        view_terminate          :: view__terminate
        view_len                :: view__len
        view_cap                :: view__cap
        rebuild                 :: view__rebuild
        refilter                :: view__refilter
        rerun_filter            :: view__rerun_filter
        view_components_match   :: view__components_match
        suspend                 :: view__suspend
        resume                  :: view__resume
        view_column_slice       :: view__column_slice
        view_entities_slice     :: view__entities_slice

    //
    // Group (owned group - enforced dense alignment)
    //
        group_init          :: group__init
        group_terminate     :: group__terminate
        group_len           :: group__len
        group_cap           :: group__cap
        group_rebuild       :: group__rebuild

    //
    // Iterator
    //
        iterator_init       :: iterator__init
        iterator_next       :: iterator__next
        iterator_reset      :: iterator__reset
        iterate             :: proc{iterator__iterate1, iterator__iterate2, iterator__iterate3, iterator__iterate4}

    //
    // Arch_Iterator (deprecated, prefer slice(&arch) + slice(&arch, T) instead)
    //
        arch_iterator_init  :: arch_iterator__init
        arch_iterator_reset :: arch_iterator__reset
        next                 :: proc {
            arch_iterator__next,
            arch_iterator__next1,
            arch_iterator__next2,
            arch_iterator__next3,
            arch_iterator__next4,
            arch_iterator__next5,
            arch_iterator__next6,
            arch_iterator__next7,
            iterator__next,
            iterator__next1,
            iterator__next2,
            iterator__next3,
            iterator__next4,
            iterator__next5,
            iterator__next6,
            iterator__next7,
        }

    //
    // Command_Buffer (deferred structural operations)
    //
        command_buffer_init      :: command_buffer__init
        command_buffer_terminate :: command_buffer__terminate
        command_buffer_len       :: command_buffer__len
        command_buffer_cap       :: command_buffer__cap
        replay                   :: command_buffer__replay

        cmd_destroy_entity  :: command_buffer__destroy_entity
        cmd_add_tag         :: proc { command_buffer__add_tag, command_buffer__flag, command_buffer__flag_enum }
        cmd_tag             :: cmd_add_tag
        cmd_remove_tag      :: proc { command_buffer__remove_tag, command_buffer__unflag, command_buffer__unflag_enum }
        cmd_untag           :: cmd_remove_tag
        cmd_flag            :: proc { command_buffer__flag, command_buffer__flag_enum }
        cmd_unflag          :: proc { command_buffer__unflag, command_buffer__unflag_enum }

        cmd_add_component   :: proc {
            command_buffer__add_component_for_table,
            command_buffer__add_component_for_compact_table,
            command_buffer__add_component_for_tiny_table,
        }

        cmd_remove_component :: proc {
            command_buffer__remove_component_for_table,
            command_buffer__remove_component_for_compact_table,
            command_buffer__remove_component_for_tiny_table,
            command_buffer__remove_entity_for_arch_table,
        }

        cmd_arch_add_entity :: proc {
            command_buffer__arch_add_entity1,
            command_buffer__arch_add_entity2,
            command_buffer__arch_add_entity3,
            command_buffer__arch_add_entity4,
        }

        cmd_set_parent      :: command_buffer__set_parent
        cmd_remove_parent   :: command_buffer__remove_parent
        cmd_unparent        :: command_buffer__remove_parent

        cmd_pair_add        :: command_buffer__pair_add
        cmd_pair_remove     :: command_buffer__pair_remove

    //
    // Sync (delta-change replication over an unreliable transport)
    //
        sync_channel_init      :: sync_channel__init
        sync_channel_terminate :: sync_channel__terminate
        sync_decoder_init      :: sync_decoder__init
        sync_decoder_terminate :: sync_decoder__terminate

        sync_register :: proc {
            sync_channel__register_table,
            sync_channel__register_compact_table,
            sync_channel__register_tiny_table,
            sync_channel__register_tag_table,
            sync_channel__register_flags_table,
            sync_channel__register_arch_table,
            sync_decoder__register_table,
            sync_decoder__register_compact_table,
            sync_decoder__register_tiny_table,
            sync_decoder__register_tag_table,
            sync_decoder__register_flags_table,
            sync_decoder__register_arch_table,
        }
        sync_unregister :: sync_channel__unregister_table

        collect_delta  :: sync_collect_delta
        delta_max_size :: sync_delta_max_size
        apply_delta    :: sync_apply_delta
        resync         :: sync_channel__resync

        get_component_mut :: proc {
            table__get_component_mut,
            compact_table__get_component_mut,
            tiny_table__get_component_mut,
        }

        // UNSAFE: skips the generation check.
        get_component_mut_unchecked :: proc {
            table__get_component_mut_unchecked,
            compact_table__get_component_mut_unchecked,
            tiny_table__get_component_mut_unchecked,
        }

    //
    // Observers (structural-change callbacks)
    //
        observer_init      :: observer__init
        observer_terminate :: observer__terminate

    //
    // Relations (parent/child); requires a Relations_Table on the database
    //
        relations_init      :: relations_table__init
        relations_terminate :: relations_table__terminate

        set_parent          :: database__set_parent
        remove_parent       :: database__remove_parent
        unparent            :: database__remove_parent
        parent_of           :: database__parent_of
        children_of         :: database__children_of
        children_count      :: database__children_count
        is_child_of         :: database__is_child_of
        is_parent_of        :: database__is_parent_of
        has_relations       :: database__has_relations
        is_relation_of      :: database__is_relation_of

        is_root             :: database__is_root
        roots               :: database__roots
        walk_subtree        :: database__walk_subtree
        walk_hierarchy      :: database__walk_hierarchy

        ancestors_of        :: database__ancestors_of
        root_of             :: database__root_of
        depth_of            :: database__depth_of
        is_ancestor_of      :: database__is_ancestor_of
        is_descendant_of    :: database__is_descendant_of

    //
    // Inherited lookup (walks the Relations_Table parent chain, nearest first)
    //
        get_component_up :: proc {
            table__get_component_up,
            compact_table__get_component_up,
            tiny_table__get_component_up,
        }

        has_tag_up :: tag_table__has_tag_up

    //
    // Component enable/disable
    //
        disable_component :: proc {
            table__disable_component,
            compact_table__disable_component,
            tiny_table__disable_component,
            tag_table__disable_component,
            arch_table__disable_component,
        }
        enable_component :: proc {
            table__enable_component,
            compact_table__enable_component,
            tiny_table__enable_component,
            tag_table__enable_component,
            arch_table__enable_component,
        }
        is_component_disabled :: proc {
            table__is_component_disabled,
            compact_table__is_component_disabled,
            tiny_table__is_component_disabled,
            tag_table__is_component_disabled,
            arch_table__is_component_disabled,
        }

    //
    // Outdated aliases (will be removed in future)
    //
        view_entity_match   :: view__components_match
        is_entity_expired   :: database__is_entity_expired
        is_deleted          :: is_not_set
        iterator__get_component_for_small_table :: iterator__get_component_for_compact_table

    //
    // Proc groups
    //

        //
        // Entity
        //

        get_entity          :: proc {
            database__get_entity,
            overbase__get_entity,
            table__get_entity_by_row_number,
            compact_table__get_entity_by_row_number,
            tiny_table__get_entity_by_row_number,
            tag_table__get_entity_by_row_number,
            flags_table__get_entity_by_row_number,
            arch_table__get_entity_by_row_number,
            iterator__get_entity,
            view_row__get_entity,
        }

        get_entity_by_row_number :: proc {
            table__get_entity_by_row_number,
            compact_table__get_entity_by_row_number,
            tiny_table__get_entity_by_row_number,
            tag_table__get_entity_by_row_number,
            flags_table__get_entity_by_row_number,
            arch_table__get_entity_by_row_number,
        }

        //
        // Component
        //

        add_component       :: proc {
            table__add_component,
            compact_table__add_component,
            tiny_table__add_component,
        }

        add_entity :: proc {
            arch_table__add_entity,
        }

        remove_component    :: proc {
            table__remove_component,
            compact_table__remove_component,
            tiny_table__remove_component,
            arch_table__remove_entity,
        }

        // Skips invalid/expired/absent eids; Table, Compact_Table, Tiny_Table only.
        remove_components   :: proc {
            table__remove_components,
            compact_table__remove_components,
            tiny_table__remove_components,
        }

        rerun_views_filters :: proc {
            table__rerun_views_filters,
            compact_table__rerun_views_filters,
            tiny_table__rerun_views_filters,
        }

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
            arch_table__get_component,
            arch_table__get_component_by_row,
            iterator__get_component_for_arch_table,
            view__get_component_for_arch_table,
            view_row__get_component_for_arch_table,
        }

        // UNSAFE: skips the generation check.
        get_component_unchecked :: proc {
            table__get_component_unchecked,
            compact_table__get_component_unchecked,
            tiny_table__get_component_unchecked,
            arch_table__get_component_unchecked,
        }

        has_component       :: proc {
            table__has_component,
            compact_table__has_component,
            tiny_table__has_component,
            tag_table__has_tag,
            flags_table__has_any,
            arch_table__has_entity,
        }

        copy_component      :: proc {
            table__copy_component,
            compact_table__copy_component,
            tiny_table__copy_component,
        }

        // Copies a component between two ENTITIES within one table (copy_component crosses two TABLES for one entity).
        clone_component     :: proc {
            table__clone_component,
            compact_table__clone_component,
            tiny_table__clone_component,
        }

        move_component      :: proc {
            table__move_component,
            compact_table__move_component,
            tiny_table__move_component,
        }

        is_in :: proc {
            arch_table__is_in,
        }

        move :: proc {
            arch_table__move_entity,
            table__move_component,
            compact_table__move_component,
            tiny_table__move_component,
        }

        sudo_move :: proc {
            arch_table__sudo_move_entity,
        }

        copy :: proc {
            arch_table__copy_entity,
            table__copy_component,
            compact_table__copy_component,
            tiny_table__copy_component,
        }

        sudo_copy :: proc {
            arch_table__sudo_copy_entity,
        }

        //
        // Tags
        //

        add_tag :: proc {
            tag_table__add_tag,
            flags_table__flag,
            flags_table__flag_enum,
        }
        tag :: add_tag

        remove_tag :: proc {
            tag_table__remove_tag,
            flags_table__unflag,
            flags_table__unflag_enum,
        }
        untag :: remove_tag

        has_tag :: proc {
            tag_table__has_tag,
            flags_table__has_flag,
            flags_table__has_flag_enum,
            flags_table__has_any,
        }

        //
        // Flags_Table
        //

        flags_table_init      :: flags_table__init
        flags_table_terminate :: flags_table__terminate

        flag :: proc {
            flags_table__flag,
            flags_table__flag_enum,
        }

        unflag :: proc {
            flags_table__unflag,
            flags_table__unflag_enum,
        }

        has_flag :: proc {
            flags_table__has_flag,
            flags_table__has_flag_enum,
        }

        has_flags   :: flags_table__has_flags
        get_flags   :: flags_table__get_flags
        set_flags   :: flags_table__set_flags
        clear_flags :: flags_table__clear_flags

        flags_of :: proc {
            flags__of_set,
            flags__of_1,
            flags__of_2,
            flags__of_3,
            flags__of_4,
            flags__of_5,
            flags__of_6,
            flags__of_7,
            flags__of_8,
        }

        //
        // Pairs
        //

        pair_init       :: pair_table__init
        pair_terminate  :: pair_table__terminate
        pair_len        :: pair_table__len
        pair_cap        :: pair_table__cap

        pair_add        :: pair_table__add
        pair_remove     :: pair_table__remove
        pair_remove_all :: pair_table__remove_all

        pair_has_pair   :: pair_table__has_pair
        pair_has_any    :: pair_table__has_any
        pair_first_target :: pair_table__first_target
        pair_first_data   :: pair_table__first_data
        pair_targets_of   :: pair_table__targets_of
        pair_holders_of   :: pair_table__holders_of
        pair_get_data     :: pair_table__get_data
        pair_count_of     :: pair_table__count_of
        pair_count_to     :: pair_table__count_to
        pair_remove_all_to :: pair_table__remove_all_to

        pair_first_row_of :: pair_table__first_row_of
        pair_next_row_of  :: pair_table__next_row_of
        pair_first_row_to :: pair_table__first_row_to
        pair_next_row_to  :: pair_table__next_row_to
        pair_row_holder   :: pair_table__row_holder
        pair_row_target   :: pair_table__row_target
        pair_row_data     :: pair_table__row_data

        //
        // Other
        //

        clear               :: proc {
            database__clear,
            table__clear,
            compact_table__clear,
            view__clear,
            tiny_table__clear,
            tag_table__clear,
            flags_table__clear,
            arch_table__clear,
            relations_table__clear,
            command_buffer__clear,
            sync_channel__clear,
        }

        pack                :: proc {
            table__pack,
            compact_table__pack,
            tiny_table__pack,
            tag_table__pack,
            flags_table__pack,
            arch_table__pack,
            group__pack,
        }

        pause_packing       :: proc {
            database__pause_packing,
            table__pause_packing,
            compact_table__pause_packing,
            tiny_table__pause_packing,
            tag_table__pause_packing,
            flags_table__pause_packing,
            arch_table__pause_packing,
            group__pause_packing,
        }

        resume_packing      :: proc {
            database__resume_packing,
            table__resume_packing,
            compact_table__resume_packing,
            tiny_table__resume_packing,
            tag_table__resume_packing,
            flags_table__resume_packing,
            arch_table__resume_packing,
            group__resume_packing,
        }

        table_len           :: proc {
            table__len,
            compact_table__len,
            tiny_table__len,
            tag_table__len,
            flags_table__len,
            arch_table__len,
            relations_table__len,
        }

        table_cap           :: proc {
            table__cap,
            compact_table__cap,
            tiny_table__cap,
            tag_table__cap,
            flags_table__cap,
            arch_table__cap,
            relations_table__cap,
        }

        entities_slice :: proc {
            view__entities_slice,
            table__entities_slice,
            compact_table__entities_slice,
            tiny_table__entities_slice,
            tag_table__entities_slice,
            flags_table__entities_slice,
            arch_table__entities_slice,
            group__entities_slice,
        }

        slice :: proc {
            table__slice,
            compact_table__slice,
            tiny_table__slice,
            tag_table__slice,
            flags_table__slice,
            view__column_slice,         // slice(&view, T) -> []^T - returns pointers to structs
            view__entities_slice,       // slice(&view) -> []entity_id
            group__slice,
            group__slice_arch,
            arch_table__column_slice,   // slice(&arch, T) -> []T - returns structs not pointers
            arch_table__entities_slice, // slice(&arch) -> []entity_id
            view__try_dense_slice,      // slice(&view, &table) -> []T or nil
        }

        //
        // For backwards compatibility
        //
            dense_slice :: slice
            table__dense_slice :: table__slice
            compact_table__dense_slice :: compact_table__slice
            tiny_table__dense_slice :: tiny_table__slice
            tag_table__dense_slice :: tag_table__slice
            group__dense_slice :: group__slice
            group__dense_slice_arch :: group__slice_arch
            arch_table__dense_slice :: arch_table__column_slice

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
            flags_table__memory_usage,
            arch_table__memory_usage,
            relations_table__memory_usage,
            command_buffer__memory_usage,
            sync_channel__memory_usage,
            sync_decoder__memory_usage,
            pair_table__memory_usage,
            observer__memory_usage,
        }

        is_valid            :: proc {
            database__is_valid,
            overbase__is_valid,
            table__is_valid,
            compact_table__is_valid,
            view__is_valid,
            group__is_valid,
            tiny_table__is_valid,
            tag_table__is_valid,
            flags_table__is_valid,
            arch_table__is_valid,
            relations_table__is_valid,
            command_buffer__is_valid,
            sync_channel__is_valid,
            sync_decoder__is_valid,
            pair_table__is_valid,
            observer__is_valid,
        }

///////////////////////////////////////////////////////////////////////////////
// Basic types

    //
    // IDs
    //

        entity_id ::            oc.ix_gen
        table_id ::             distinct int
        table_record_id ::      distinct int
        view_id ::              distinct int
        view_record_id ::       distinct u32
        view_column_id ::       int
        pair_table_id ::        distinct int
        command_buffer_id ::    distinct int
        observer_id ::          distinct int

    //
    // Enums
    //

        Object_State :: enum {
            Not_Initialized = 0,
            Normal,
            Invalid,
            Terminated,
        }

        Table_Type :: enum {
            Auto = 0,
            Table,
            Tiny_Table,
            Compact_Table,
            Tag_Table,
            Arch_Table,
            Flags_Table,
        }

        // ECS specific errors
        API_Error :: enum {
            None = 0,
            Entities_Cap_Should_Be_Greater_Than_Zero,
            Component_Already_Exist,
            Tables_Array_Should_Not_Be_Empty,
            Unexpected_Error,
            Entity_Id_Out_of_Bounds,
            Entity_Id_Expired,
            Cannot_Add_Record_To_View_Container_Is_Full,
            Object_Invalid,
            Component_Size_Cannot_Be_Zero,
            Relations_Table_Already_Exists,
            Relations_Table_Not_Created,
            Relation_Cycle,
            Only_Table_Can_Be_Owned_By_Group,
            Table_Already_Owned_By_Group,
            Cannot_Pause_Table_Owned_By_Group,
            Table_Cannot_Be_Included_And_Excluded,
            Table_Cannot_Be_Included_And_Any_Of,
            Snapshot_Invalid,
            Snapshot_Version_Mismatch,
            Snapshot_Schema_Mismatch,
            Snapshot_Capacity_Too_Small,
            Snapshot_Component_Not_POD,
            Cannot_Serialize_While_Packing_Paused,
            Serialize_Buffer_Too_Small,
            File_Error,
            Sync_Table_Type_Not_Supported,
            Sync_Too_Many_Fields,
            Sync_Table_Already_Registered,
            Sync_Buffer_Too_Small,
            Sync_Feature_Disabled,
            Tables_Cap_Exceeds_Compile_Time_Limit,
            Observers_Feature_Disabled,
            Entity_Not_In_Table,
            Table_To_Cannot_Contain_Entity,
            Entity_Already_In_Table,
            Table_Type_Not_Supported,
            Flags_Bits_Cannot_Be_Empty,
            View_Includes_Need_A_Table,
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

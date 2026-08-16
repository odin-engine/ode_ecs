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

    // Validates parameters/state via asserts. Set false for a slight speed gain
    // once you're confident everything is correct.
    VALIDATIONS :: #config(ECS_VALIDATIONS, true)

    BIT_SET_VALUES_CAP :: 128   // don't change unless Odin changes bit_set's max bit count

    // A bit_set tracks which components an entity has; one bit_set holds 128
    // component types per TABLES_MULT (2 -> 256, 3 -> 384, etc).
    TABLES_MULT :: #config(ECS_TABLES_MULT, 1)

    // Initial table (component type) capacity; doubles when reached (init-time
    // only). Must stay <= BIT_SET_VALUES_CAP * TABLES_MULT.
    TABLES_CAP ::  #config(ECS_TABLES_CAP, 16)

    VIEWS_CAP :: #config(ECS_VIEWS_CAP, 16)

    // Initial Pair_Table capacity per Database; grows on demand.
    PAIR_TABLES_CAP :: #config(ECS_PAIR_TABLES_CAP, 8)

    // Initial Command_Buffer capacity per Database; grows on demand.
    COMMAND_BUFFERS_CAP :: #config(ECS_COMMAND_BUFFERS_CAP, 8)

    SUBSCRIBERS_CAP :: #config(ECS_SUBSCRIBERS_CAP, 8)

    DELETED_INDEX :: oc.DELETED_INDEX // -1 by default; marks "unused/incorrect index"

    //
    // Tiny_Table
    //

        // Rows live inline in the struct, not dynamically allocated.
        TINY_TABLE__ROW_CAP :: 8
        TINY_TABLE__VIEWS_CAP :: 8      // max Views subscribed to one Tiny_Table
        TINY_TABLE__MAP_CAP :: 32       // must be power of 2

        // Max concurrently-alive Tiny_Tables per Database - their View-subscriber
        // bookkeeping lives in one Database-owned batch pool (Tiny_Table_Subscriber_Slot
        // in tiny_table.odin), so it needs its own cap.
        TINY_TABLES_CAP :: #config(ECS_TINY_TABLES_CAP, 32)

    //
    // Sync - delta-change replication.
    //

        // Off by default; compile in with -define:ECS_SYNC_ENABLED=true.
        SYNC_ENABLED :: #config(ECS_SYNC_ENABLED, false)

        // Max Sync_Channel/Sync_Decoder watching one Table/Compact_Table/Tag_Table at once.
        SYNC_CHANNELS_CAP :: #config(ECS_SYNC_CHANNELS_CAP, 8)

        // Same, but for Tiny_Table's batch-allocated slot.
        TINY_TABLE__SYNC_CHANNELS_CAP :: #config(ECS_TINY_TABLE__SYNC_CHANNELS_CAP, 4)

        // Top-level fields per component a Sync_Channel can diff; wire field-changed mask is a u32.
        SYNC_MAX_FIELDS :: 32

    //
    // Observers- structural-change callbacks.
    //

        // Off by default; compile in with -define:ECS_OBSERVERS_ENABLED=true. Every
        // notify call site is `when OBSERVERS_ENABLED`-gated, so the feature costs
        // nothing in a default build - not even a runtime branch.
        OBSERVERS_ENABLED :: #config(ECS_OBSERVERS_ENABLED, false)

        // Initial Observer capacity per Database; grows on demand.
        OBSERVERS_CAP :: #config(ECS_OBSERVERS_CAP, 8)

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
    // Overbase (shared entity ID space). Attach via
    // init_from_overbase to share entities across Databases; create_entity/
    // destroy_entity/is_expired/entities_len/get_entity below accept either.
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
    // Serialization (binary snapshot of a whole Database)
    //
        serialized_size         :: database__serialized_size    // Exact buffer size serialize will need for the current state
        serialize               :: database__serialize          // Write a snapshot into a caller-provided buffer (zero allocations)
        deserialize             :: database__deserialize        // Load a snapshot into an initialized database with a matching schema
        save_to_file            :: database__save_to_file       // serialize + write to a file
        load_from_file          :: database__load_from_file     // read a file + deserialize

    //
    // Overbase serialization (binary snapshot of just the shared entity-id space) - a Database's own serialize/deserialize
    // never touches a shared Overbase's id-space.
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
        view_len                :: view__len
        view_cap                :: view__cap
        rebuild                 :: view__rebuild                    // full O(n) repopulation from the view's tables
        refilter                :: view__refilter                   // re-evaluate filter for all rows/candidates in one sweep (after bulk mutations)
        rerun_filter            :: view__rerun_filter               // re-evaluate filter for one entity
        view_components_match   :: view__components_match           // true if entity's components match (includes+excludes), ignoring filter
        suspend                 :: view__suspend                    // stop updating on entity/component/tag changes
        resume                  :: view__resume                     // resume after suspend

    //
    // Group (owned group - enforced dense alignment)
    //
        group_init          :: group__init                          // exclusive ownership of tables; members stay in an aligned prefix
        group_terminate     :: group__terminate
        group_len           :: group__len
        group_rebuild       :: group__rebuild                       // rebuild membership from scratch (normally incremental)

    //
    // Iterator
    //
        iterator_init       :: iterator__init
        iterator_next       :: iterator__next
        iterator_reset      :: iterator__reset
        iterate             :: proc{iterator__iterate1, iterator__iterate2, iterator__iterate3, iterator__iterate4} // for-in sugar: for v1, v2 in iterate(&it, &t1, &t2) { ... }; Table($T) columns only

    //
    // Arch_Iterator (dense iterator directly over an Arch_Table's own rows)
    //
        arch_iterator_init  :: arch_iterator__init
        arch_iterator_reset :: arch_iterator__reset
        // for-in sugar: for eid, pos, ai in next(&it, Position, AI) { ... }. Component types
        // are supplied per call (up to 7), not bound at init; next(&it) with no types returns
        // just the entity id. Also covers View-based Iterator (Table($T) columns, like iterate,
        // but with eid and up to arity 7) - preferred over iterate going forward.
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
            command_buffer__remove_entity_for_arch_table,
        }

        // Record: add an Arch_Table row with its values
        cmd_arch_add_entity :: proc {
            command_buffer__arch_add_entity1,
            command_buffer__arch_add_entity2,
            command_buffer__arch_add_entity3,
            command_buffer__arch_add_entity4,
        }

        cmd_set_parent      :: command_buffer__set_parent         // Record: make one entity the parent of another
        cmd_remove_parent   :: command_buffer__remove_parent      // Record: remove entity's parent link
        cmd_unparent        :: command_buffer__remove_parent

        cmd_pair_add        :: command_buffer__pair_add           // Record: add (holder -> target) to a Pair_Table with its payload
        cmd_pair_remove     :: command_buffer__pair_remove        // Record: remove one (holder, target) pair

    //
    // Sync (delta-change replication over an unreliable transport)
    //
        sync_channel_init      :: sync_channel__init
        sync_channel_terminate :: sync_channel__terminate
        sync_decoder_init      :: sync_decoder__init
        sync_decoder_terminate :: sync_decoder__terminate

        // Register a table with a Sync_Channel (sender) or Sync_Decoder (receiver) -
        // resolves by both the channel/decoder's type and the table's type.
        sync_register :: proc {
            sync_channel__register_table,
            sync_channel__register_compact_table,
            sync_channel__register_tiny_table,
            sync_channel__register_tag_table,
            sync_channel__register_arch_table,
            sync_decoder__register_table,
            sync_decoder__register_compact_table,
            sync_decoder__register_tiny_table,
            sync_decoder__register_tag_table,
            sync_decoder__register_arch_table,
        }
        sync_unregister :: sync_channel__unregister_table

        collect_delta  :: sync_collect_delta   // sender: write pending changes into buf (see its doc comment for the partial-fill contract)
        delta_max_size :: sync_delta_max_size  // sender: cheap worst-case upper bound for buf - sizing to this guarantees one collect_delta call fully flushes
        apply_delta    :: sync_apply_delta     // receiver: parse + apply one collect_delta buffer
        resync         :: sync_channel__resync // sender: shadow := live values, drop pending queues - call right after sending a full serialize snapshot

        // Same as get_component, but marks the entity touched in every
        // Sync_Channel watching this table - use this instead of get_component
        // whenever you intend to WRITE through the returned pointer, so the
        // next collect_delta picks up the change.
        get_component_mut :: proc {
            table__get_component_mut,
            compact_table__get_component_mut,
            tiny_table__get_component_mut,
        }

    //
    // Observers (structural-change callbacks)
    //
        observer_init      :: observer__init
        observer_terminate :: observer__terminate

    //
    // Relations (parent/child); requires a Relations_Table on the database, see relations_table__init
    //
        relations_init      :: relations_table__init                // Attach a Relations_Table to a Database (one per Database)
        relations_terminate :: relations_table__terminate

        set_parent          :: database__set_parent                 // Make one entity the parent of another (replaces previous parent)
        remove_parent       :: database__remove_parent              // Remove entity's parent link
        unparent            :: database__remove_parent
        parent_of           :: database__parent_of                  // Entity's parent id, or id with ix == DELETED_INDEX if none
        children_of         :: database__children_of                // Entity's children as a slice of an internal buffer - use immediately
        children_count      :: database__children_count
        is_child_of         :: database__is_child_of                // Is `a` a child of `b`?
        is_parent_of        :: database__is_parent_of               // Is `a` the parent of `b`?
        has_relations       :: database__has_relations              // Does entity have a parent or children?
        is_relation_of      :: database__is_relation_of             // Does `e` relate to `target` directly (as child or parent)?

        is_root             :: database__is_root                    // Has no parent AND at least one child?
        roots               :: database__roots                      // All roots, as a slice of an internal buffer - use immediately
        walk_subtree        :: database__walk_subtree               // root's descendants, breadth-first - use immediately
        walk_hierarchy      :: database__walk_hierarchy              // Whole forest, breadth-first + level boundaries - use immediately

    //
    // Component enable/disable (soft toggle) - component/row stays
    // put, just excluded from (disable_component) or restored to (enable_component) queries.
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

        get_entity          :: proc {
            database__get_entity,
            overbase__get_entity,
            table__get_entity_by_row_number,
            compact_table__get_entity_by_row_number,
            tiny_table__get_entity_by_row_number,
            tag_table__get_entity_by_row_number,
            arch_table__get_entity_by_row_number,
            iterator__get_entity,
            view_row__get_entity,
        }

        get_entity_by_row_number :: proc {
            table__get_entity_by_row_number,
            compact_table__get_entity_by_row_number,
            tiny_table__get_entity_by_row_number,
            tag_table__get_entity_by_row_number,
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

        remove_component    :: proc {
            table__remove_component,
            compact_table__remove_component,
            tiny_table__remove_component,
        }

        // Rerun filters of views subscribed to a table, for one entity - call after
        // mutating component data a view filter depends on (or use refilter for bulk)
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

        has_component       :: proc {
            table__has_component,
            compact_table__has_component,
            tiny_table__has_component,
            tag_table__has_tag,
            arch_table__has_entity,
        }

        copy_component      :: proc {
            table__copy_component,
            compact_table__copy_component,
            tiny_table__copy_component,
        }

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

        has_tag :: tag_table__has_tag

        //
        // Pairs (many-to-many relations) - Pair_Table(T), built on a Tag_Table. 
        // Unlike Relations_Table, a Pair_Table's presence table DOES
        // affect Views: {&some_pairs.presence} is usable in view_init's includes/
        // excludes/any_of. Auto-terminated by database__terminate (same as
        // Relations_Table); destroying a holder OR a target both clean up their pair
        // rows automatically; serialization- and Command_Buffer-aware
        // (cmd_pair_add/cmd_pair_remove). 

        pair_init       :: pair_table__init
        pair_terminate  :: pair_table__terminate

        pair_add        :: pair_table__add            // Adds (holder -> target); no-op on an exact duplicate
        pair_remove     :: pair_table__remove          // Removes one (holder, target) pair
        pair_remove_all :: pair_table__remove_all      // Removes all of holder's pairs

        pair_has_pair   :: pair_table__has_pair
        pair_has_any    :: pair_table__has_any         // == has_tag(&pairs.presence, holder)
        pair_first_target :: pair_table__first_target  // O(1): most-recently-added target, arbitrary among several
        pair_first_data   :: pair_table__first_data
        pair_targets_of   :: pair_table__targets_of    // holder's targets as a slice of an internal buffer - use immediately

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
            arch_table__clear,
            relations_table__clear,
            command_buffer__clear,
            sync_channel__clear,
        }

        // Compact holes left by removals made while tail swap was paused,
        // see pause_packing / resume_packing. Callable mid-pause too.
        pack                :: proc {
            table__pack,
            compact_table__pack,
            tiny_table__pack,
            tag_table__pack,
            arch_table__pack,
            group__pack,
        }

        // Pause tail swapping - at the Database (all tables + all groups), a
        // single table (rejected with API_Error.Cannot_Pause_Table_Owned_By_Group
        // if owned by a Group), or a Group (all tables it owns, as one atomic
        // unit) level. Table/group-level pause is independent of the
        // database-wide pause - useful to isolate one table or group (e.g. from
        // another thread) without deferring packing everywhere.
        pause_packing       :: proc {
            database__pause_packing,
            table__pause_packing,
            compact_table__pause_packing,
            tiny_table__pause_packing,
            tag_table__pause_packing,
            arch_table__pause_packing,
            group__pause_packing,
        }

        // Resume tail swapping and pack whatever holes accumulated at that level.
        resume_packing      :: proc {
            database__resume_packing,
            table__resume_packing,
            compact_table__resume_packing,
            tiny_table__resume_packing,
            tag_table__resume_packing,
            arch_table__resume_packing,
            group__resume_packing,
        }

        table_len           :: proc {
            table__len,
            compact_table__len,
            tiny_table__len,
            tag_table__len,
            arch_table__len,
            relations_table__len,
        }

        table_cap           :: proc {
            table__cap,
            compact_table__cap,
            tiny_table__cap,
            tag_table__cap,
            arch_table__cap,
            relations_table__cap,
        }

        // Live rows as one contiguous slice. Prefer over reading a table's `rows`
        // field directly in a hot loop - see table__slice's doc comment for why.
        slice :: proc {
            table__slice,
            compact_table__slice,
            tiny_table__slice,
            tag_table__slice,
            view__slice,          // slice(&view, &table) - nil if the view isn't dense-aligned
            group__slice,         // slice(&group, &table) - nil while the group is dirty
            group__slice_arch,    // slice(&group, &arch_table, T) - nil while the group is dirty
        }
        
        // For backwards compatibility
        dense_slice :: slice
        table__dense_slice :: table__slice
        compact_table__dense_slice :: compact_table__slice
        tiny_table__dense_slice :: tiny_table__slice
        tag_table__dense_slice :: tag_table__slice
        view__dense_slice :: view__slice
        group__dense_slice :: group__slice     
        group__dense_slice_arch :: group__slice_arch

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

        entity_id ::            oc.ix_gen           // index + generation
        table_id ::             distinct int
        table_record_id ::      distinct int
        view_id ::              distinct int
        view_record_id ::       distinct u32     // view row index; u32 halves the per-view eid_to_rid array
        view_column_id ::       int
        pair_table_id ::        distinct int     // Database.pair_tables registry index 
        command_buffer_id ::    distinct int    // Database.command_buffers registry index 
        observer_id ::          distinct int     // Database.observers registry index 

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
            Arch_Table,
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
            Table_Cannot_Be_Included_And_Any_Of,   // view_init got the same table in `includes` and `any_of` (always redundant - AND already guarantees it)
            Snapshot_Invalid,                 // bad magic/endianness, truncated or corrupt snapshot buffer
            Snapshot_Version_Mismatch,        // snapshot was written by an incompatible library version
            Snapshot_Schema_Mismatch,         // tables/types of the target database differ from the saved ones
            Snapshot_Capacity_Too_Small,      // target entities_cap/table cap/relations cap cannot hold the saved data
            Snapshot_Component_Not_POD,       // component contains pointers/slices/strings; pass allow_non_pod to serialize anyway
            Cannot_Serialize_While_Packing_Paused, // resume_packing first so tables hold no holes
            Serialize_Buffer_Too_Small,       // size the buffer with serialized_size
            File_Error,                       // save_to_file/load_from_file could not open/read/write the file
            Sync_Table_Type_Not_Supported,    // Arch_Table cannot be registered with a Sync_Channel/Sync_Decoder yet
            Sync_Too_Many_Fields,             // component has more top-level fields than SYNC_MAX_FIELDS
            Sync_Table_Already_Registered,    // table is already registered with this channel/decoder
            Sync_Buffer_Too_Small,            // buffer can't even hold the delta header
            Sync_Feature_Disabled,            // built with the default -define:ECS_SYNC_ENABLED=false
            Tables_Cap_Exceeds_Compile_Time_Limit, // database__init's tables_cap was greater than TABLES_CAP - table ids are bit-indexed into Uni_Bits, whose width is fixed at compile time via ECS_TABLES_MULT; raise that to raise TABLES_CAP
            Observers_Feature_Disabled,       // built with the default -define:ECS_OBSERVERS_ENABLED=false
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

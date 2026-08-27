/*
    2026 (c) Oleh, https://github.com/zm69

    Observer — structural-change callbacks (create/destroy entity, add/remove
    component, tag, enable/disable, parent, pair). Off by default; compile in
    with -define:ECS_OBSERVERS_ENABLED=true.

    Every notify call site (in database.odin, table.odin, compact_table.odin,
    tiny_table.odin, tag_table.odin, arch_table.odin, relations_table.odin,
    pair_table.odin) is wrapped in `when OBSERVERS_ENABLED`, so in a default
    build the notify code does not exist in the binary — not a runtime branch,
    exactly like Sync's own table_base__notify_sync_add. Database.observers
    itself is an ordinary, unconditionally-present field (like pair_tables/
    command_buffers) — it costs a few bytes on one per-world struct, not a
    per-entity hot-path cost, so unlike Tiny_Table's SYNC_ENABLED split there
    is no need to duplicate the Database struct to remove it.

    One database-wide registry, not per-table subscriber lists like Views/Sync
    use — an Observer sees every event kind it's interested in (interested_in)
    and the event payload carries enough context (table/pair-table id, related
    entity) for the callback to act on it, without needing a Dense_Arr(^Observer)
    field replicated across every table kind.

    Timing: events that remove/destroy something fire BEFORE the mutation, so
    the callback can still read live state (Entity_Destroyed, Component_Removed,
    Tag_Removed, Parent_Removed, Pair_Removed). Events that add/set something
    fire AFTER, so the new value is already readable (Entity_Created,
    Component_Added, Tag_Added, Component_Enabled/Disabled, Parent_Set,
    Pair_Added). Observer_Event.data (where present) is valid only for the
    duration of the callback — do not store the pointer.

    Command_Buffer replay fires the same events as the immediate API for free:
    every hook below lives in the lowest-level shared proc (table_raw__*_sized,
    pair_table_base__add_raw/unlink_row, relations_table__set_parent/remove_parent,
    database__destroy_entity_local), which is exactly what command_buffer__replay
    itself calls — no separate replay-time hook needed. create_entity has no
    Command_Buffer command at all (by design),
    and neither does enable/disable_component — both fire only via their one
    immediate-API call path.
*/
package ode_ecs

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Observer

    Observer_Event_Kind :: enum {
        Entity_Created,
        Entity_Destroyed,
        Component_Added,
        Component_Removed,
        Tag_Added,
        Tag_Removed,
        Component_Enabled,
        Component_Disabled,
        Parent_Set,
        Parent_Removed,
        Pair_Added,
        Pair_Removed,
        Arch_Entity_Added,
        Arch_Entity_Removed,
    }

    Observer_Event :: struct {
        kind:          Observer_Event_Kind,
        eid:           entity_id,          // primary entity (child for Parent_*, holder for Pair_*)
        table_id:      table_id,           // Component_*/Tag_*/Component_Enabled/Disabled/Arch_Entity_*; DELETED_INDEX sentinel otherwise
        pair_table_id: pair_table_id,      // Pair_Added/Removed; DELETED_INDEX sentinel otherwise
        related:       entity_id,          // Parent_*: parent; Pair_*: target; {ix = DELETED_INDEX} otherwise
        data:          rawptr,             // Component_*/Pair_* payload ptr where applicable; valid only during the callback — do not store
    }

    Observer :: struct {
        state: Object_State,
        db:    ^Database,
        id:    observer_id,

        callback:      proc(event: ^Observer_Event, user_data: rawptr),
        user_data:     rawptr,
        interested_in: bit_set[Observer_Event_Kind], // which kinds this observer wants; ~{} (default) = every kind
    }

    observer__is_valid :: proc(self: ^Observer) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if self.callback == nil do return false

        return true
    }

    observer__init :: proc(self: ^Observer, db: ^Database, callback: proc(event: ^Observer_Event, user_data: rawptr), interested_in: bit_set[Observer_Event_Kind] = ~{}, user_data: rawptr = nil, loc := #caller_location) -> Error {
        when !OBSERVERS_ENABLED do return API_Error.Observers_Feature_Disabled

        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(callback != nil, loc = loc)
        }

        self.db = db
        self.callback = callback
        self.user_data = user_data
        self.interested_in = interested_in

        self.id = database__attach_observer(db, self) or_return

        self.state = Object_State.Normal

        return nil
    }

    observer__terminate :: proc(self: ^Observer) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        database__detach_observer(self.db, self)

        self.callback = nil
        self.user_data = nil
        self.db = nil

        // Leave in Not_Initialized state (not Terminated) so the same struct can be re-init'd without zeroing it first.
        self.state = Object_State.Not_Initialized

        return nil
    }

    observer__memory_usage :: proc(self: ^Observer) -> int {
        return size_of(self^) // no sub-allocations, unlike Pair_Table/Command_Buffer
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    database__attach_observer :: proc(self: ^Database, o: ^Observer) -> (observer_id, Error) {
        id, err := oc.sparse_arr__add_growing(&self.observers, o, self.allocator)
        if err != nil do return DELETED_INDEX, err

        return cast(observer_id) id, nil
    }

    @(private)
    database__detach_observer :: proc(self: ^Database, o: ^Observer) {
        oc.sparse_arr__remove_by_index(&self.observers, cast(int) o.id)
    }

    // Fires `kind` to every attached Observer interested in it, via scalar args (not a pre-built Observer_Event) so a disabled build still costs nothing at -o:none.
    @(private)
    database__notify_observers :: #force_inline proc(
        self: ^Database, kind: Observer_Event_Kind, eid: entity_id,
        table_id: table_id = table_id(DELETED_INDEX), pair_table_id: pair_table_id = pair_table_id(DELETED_INDEX),
        related: entity_id = {ix = DELETED_INDEX}, data: rawptr = nil,
    ) {
        when OBSERVERS_ENABLED {
            if len(self.observers.items) == 0 do return

            ev := Observer_Event{
                kind = kind, eid = eid, table_id = table_id,
                pair_table_id = pair_table_id, related = related, data = data,
            }

            for o in self.observers.items {
                if o == nil do continue
                if kind not_in o.interested_in do continue
                o.callback(&ev, o.user_data)
            }
        }
    }

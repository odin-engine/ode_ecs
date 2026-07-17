/*
    2025 (c) Oleh, https://github.com/zm69
*/

// Everything is private here
#+private 

package ode_ecs

///////////////////////////////////////////////////////////////////////////////
// Shared_Table - data shared between all tables

    // Shared between all tables
    Shared_Table :: struct {
        state: Object_State,
        type: Table_Type,
        id: table_id,
        db: ^Database,

        // Deferred tail swap for this table only, independent of
        // db.tail_swap_paused. See shared_table__is_packing_paused,
        // table__pause_packing/compact_table__pause_packing/etc.
        pause_packing: bool,
    }

    @(private)
    shared_table__is_valid_internal :: proc(self: ^Shared_Table) -> bool {
        if self == nil do return false 
        if self.state != Object_State.Normal do return false 
        if self.type == Table_Type.Unknown do return false 
        if self.id < 0 do return false 
        if self.db == nil do return false 

        return true
    }

    shared_table__init :: proc(self: ^Shared_Table, type: Table_Type, db: ^Database) {

        shared_table__clear_state(self)

        self.type = type
        self.db = db
    }

    shared_table__terminate :: proc(self: ^Shared_Table) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                table_raw__terminate(cast(^Table_Raw)self) or_return
            case Table_Type.Tiny_Table:
                tiny_table_base__terminate(cast(^Tiny_Table_Base)self) or_return
            case Table_Type.Compact_Table:
                compact_table_raw__terminate(cast(^Compact_Table_Raw)self) or_return
            case Table_Type.Tag_Table:
                tag_table__terminate(cast(^Tag_Table)self) or_return
        }

        //shared_table__clear_state(self)

        return nil
    }

    shared_table__clear_state :: proc(self: ^Shared_Table) {
        // Not_Initialized (not Invalid) so a terminated table can be re-init'd
        // on the same struct without zeroing it first. See issue #8.
        self.state = Object_State.Not_Initialized
        self.type = Table_Type.Unknown
        self.id  = DELETED_INDEX
        self.db = nil
        self.pause_packing = false
    }

    shared_table__is_valid :: proc(self: ^Shared_Table) -> bool {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__is_valid(cast(^Table_Base) self)
            case Table_Type.Tiny_Table:
                return tiny_table_base__is_valid(cast(^Tiny_Table_Base) self)
            case Table_Type.Compact_Table:
                return compact_table_base__is_valid(cast(^Compact_Table_Base) self)
            case Table_Type.Tag_Table:
                return tag_table__is_valid(cast(^Tag_Table)self)
        } 

        assert(false) // should not happen
        return true
    }

    shared_table__memory_usage :: proc(self: ^Shared_Table) -> int {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__memory_usage(cast(^Table_Base) self)
            case Table_Type.Tiny_Table:
                return tiny_table_base__memory_usage(cast(^Tiny_Table_Base) self)
            case Table_Type.Compact_Table:
                return compact_table_base__memory_usage(cast(^Compact_Table_Base) self)
            case Table_Type.Tag_Table:
                return tag_table__memory_usage(cast(^Tag_Table)self)
        } 

        assert(false) // should not happen
        return DELETED_INDEX
    }

    shared_table__len :: proc(self: ^Shared_Table) -> int {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_raw__len(cast(^Table_Raw)self)
            case Table_Type.Tiny_Table:
                return tiny_table_base__len(cast(^Tiny_Table_Base) self)
            case Table_Type.Compact_Table:
                return compact_table_raw__len(cast(^Compact_Table_Raw)self)
            case Table_Type.Tag_Table:
                return tag_table__len(cast(^Tag_Table)self)
        } 

        assert(false) // should not happen
        return DELETED_INDEX
    }

    shared_table__cap :: proc(self: ^Shared_Table) -> int {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__cap(cast(^Table_Base)self)
            case Table_Type.Tiny_Table:
                return tiny_table__cap(self)
            case Table_Type.Compact_Table:
                return compact_table_base__cap(cast(^Compact_Table_Base)self)
            case Table_Type.Tag_Table:
                return tag_table__cap(cast(^Tag_Table)self)
        } 

        assert(false) // should not happen
        return DELETED_INDEX
    }

    shared_table__get_entity_by_row_number :: proc (self: ^Shared_Table, #any_int row_number: int) -> entity_id {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__get_entity_by_row_number(cast(^Table_Base) self, row_number)
            case Table_Type.Tiny_Table: 
                return tiny_table_base__get_entity_by_row_number(cast(^Tiny_Table_Base) self, row_number)
            case Table_Type.Compact_Table:
                return compact_table_base__get_entity_by_row_number(cast(^Compact_Table_Base) self, row_number)
            case Table_Type.Tag_Table:
               return tag_table__get_entity_by_row_number(cast(^Tag_Table) self, row_number)
        } 

        assert(false) // should not happen
        return entity_id{ix = DELETED_INDEX}
    }

    shared_table__get_component :: proc (self: ^Shared_Table, eid: entity_id) -> rawptr {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_raw__get_component_by_entity(cast(^Table_Raw) self, eid)
            case Table_Type.Tiny_Table: 
                return tiny_table_base__get_component_by_entity(cast(^Tiny_Table_Base) self, eid)
            case Table_Type.Compact_Table:
                return compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, eid)
            case Table_Type.Tag_Table:
                return nil // no component for tag_table
        } 

        assert(false) // should not happen
        return nil
    } 

    shared_table__remove_component :: proc (self: ^Shared_Table, eid: entity_id) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_raw__remove_component(cast(^Table_Raw) self, eid)
            case Table_Type.Tiny_Table: 
                return tiny_table_raw__remove_component(cast(^Tiny_Table_Raw) self, eid)
            case Table_Type.Compact_Table:
                return compact_table_raw__remove_component(cast(^Compact_Table_Raw) self, eid)
            case Table_Type.Tag_Table:
                // No component data, but the tag entry itself must be removed so
                // destroying a tagged entity doesn't leave a stale tag behind.
                return tag_table__remove_tag(cast(^Tag_Table) self, eid)
        }

        assert(false) // should not happen
        return API_Error.Unexpected_Error
    }

    // Compact holes left by removals made while tail swap was paused,
    // see database__resume_packing
    shared_table__pack :: proc (self: ^Shared_Table) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_raw__pack(cast(^Table_Raw) self)
            case Table_Type.Tiny_Table:
                return tiny_table_raw__pack(cast(^Tiny_Table_Raw) self)
            case Table_Type.Compact_Table:
                return compact_table_raw__pack(cast(^Compact_Table_Raw) self)
            case Table_Type.Tag_Table:
                return tag_table__pack(cast(^Tag_Table) self)
        }

        assert(false) // should not happen
        return API_Error.Unexpected_Error
    }

    // Is packing (tail swap) currently deferred for this table — either by a
    // database-wide pause or by this table's own pause_packing.
    shared_table__is_packing_paused :: #force_inline proc "contextless" (self: ^Shared_Table) -> bool {
        return self.db.tail_swap_paused || self.pause_packing
    }

    shared_table__clear :: proc (self: ^Shared_Table) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_raw__clear(cast(^Table_Raw) self)
            case Table_Type.Tiny_Table: 
                return tiny_table_raw__clear(cast(^Tiny_Table_Raw) self)
            case Table_Type.Compact_Table:
                return compact_table_raw__clear(cast(^Compact_Table_Raw) self)
            case Table_Type.Tag_Table:
                return tag_table__clear(cast(^Tag_Table)self)
        } 

        return API_Error.Unexpected_Error
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    shared_table__attach_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error { 
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__attach_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__attach_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__attach_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__attach_subscriber(cast(^Tag_Table)self, view)
        } 

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__detach_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__detach_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__detach_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__detach_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__detach_subscriber(cast(^Tag_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    // A view that excludes this table subscribes here (not to `subscribers` — the
    // table is not a view column, only membership notifications are needed).
    shared_table__attach_exclude_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__attach_exclude_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__attach_exclude_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__attach_exclude_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__attach_exclude_subscriber(cast(^Tag_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__detach_exclude_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__detach_exclude_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__detach_exclude_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__detach_exclude_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__detach_exclude_subscriber(cast(^Tag_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }


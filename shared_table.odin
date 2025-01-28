/*
    2025 (c) Oleh, https://github.com/zm69
*/
#+private 
package ode_ecs

///////////////////////////////////////////////////////////////////////////////
// Shared_Table - data shared between all tables

    Table_Type :: enum {
        Unknown = 0,
        Table,
        Tiny_Table,
        Small_Table,
    }

    // Shared between all tables
    Shared_Table :: struct {
        state: Object_State,
        type: Table_Type,
        id: table_id, 
        db: ^Database, 
    }

    shared_table__init :: proc(self: ^Shared_Table, type: Table_Type, db: ^Database) {
        self.state = Object_State.Invalid
        self.type = type
        self.id  = DELETED_INDEX
        self.db = db
    }

    shared_table__terminate :: proc(self: ^Shared_Table) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                table_raw__terminate(cast(^Table_Raw)self) or_return
            case Table_Type.Tiny_Table:
            case Table_Type.Small_Table:
        }

        self.state = Object_State.Invalid
        self.type = Table_Type.Unknown
        self.id  = DELETED_INDEX
        self.db = nil

        return nil
    }

    shared_table__memory_usage :: proc(self: ^Shared_Table) -> int {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__memory_usage(cast(^Table_Base) self)
            case Table_Type.Tiny_Table:
                return tiny_table_base__memory_usage(cast(^Tiny_Table_Base) self)
            case Table_Type.Small_Table:
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
            case Table_Type.Small_Table:
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
            case Table_Type.Small_Table:
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
            case Table_Type.Small_Table:
        } 

        assert(false) // should not happen
        return entity_id{ix = DELETED_INDEX}
    }

    shared_table__get_component :: proc (self: ^Shared_Table, eid: entity_id) -> rawptr {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_base__get_component_by_entity(cast(^Table_Raw) self, eid)
            case Table_Type.Tiny_Table: 
                return tiny_table_base__get_component_by_entity(cast(^Tiny_Table_Raw) self, eid)
            case Table_Type.Small_Table:
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
            case Table_Type.Small_Table:
        } 

        assert(false) // should not happen
        return API_Error.Unexpected_Error
    }

    shared_table__clear :: proc (self: ^Shared_Table) -> Error {
        switch self.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                return table_raw__clear(cast(^Table_Raw) self)
            case Table_Type.Tiny_Table: 
                return tiny_table_raw__clear(cast(^Tiny_Table_Raw) self)
            case Table_Type.Small_Table:
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
            case Table_Type.Small_Table:
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
            case Table_Type.Small_Table:
        } 

        return API_Error.Unexpected_Error
    }


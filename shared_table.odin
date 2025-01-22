
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
                return table_memory_usage(cast(^Table_Base)self)
            case Table_Type.Tiny_Table:
            case Table_Type.Small_Table:
        } 

        return DELETED_INDEX
    }
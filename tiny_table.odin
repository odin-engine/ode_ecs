/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// TT_Base (Tiny Table Base)

    @(private)
    TT_Base :: struct {
        state: Object_State,       
        id: table_id, 
        db: ^Database,
        type_info: ^runtime.Type_Info,
    }

    @(private)
    tt_base__init :: proc(self: ^TT_Base, db: ^Database) {
        self.db = db
        self.id = DELETED_INDEX
    }

    @(private)
    tt_base__terminate :: proc(self: ^TT_Base) {

    }

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table

    Tiny_Table :: struct($ROW_CAP: int, $VIEWS_CAP: int, $T: typeid) where ROW_CAP < 11 && VIEWS_CAP < 11 {
        using base: TT_Base(ROW_CAP), 

        rid_to_eid: [ROW_CAP]entity_id,
        eid_to_ptr: oc.Toa_Map(ROW_CAP * 2.5, rawptr),
        subscribers: [VIEWS_CAP]^View,
        records: [ROW_CAP]T,
    }

    tiny_table__init :: proc(self: ^Tiny_Table($ROW_CAP, $VIEWS_CAP, $T), db: ^Database) -> Error {
        self.db = db
        self.id = DELETED_INDEX
        return nil
    }

    tiny_table__terminate :: proc(self: ^Tiny_Table($ROW_CAP, $VIEWS_CAP, $T)) -> Error {
        return nil
    }
     
///////////////////////////////////////////////////////////////////////////////
// TT_Raw





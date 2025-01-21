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
    tt_base__init :: proc(self: ^TT_Base, db: ^Database) -> Error {
        self.db = db
        self.id = db__attach_tiny_table(db, self) or_return
        self.state = Object_State.Normal

        return nil
    }

    @(private)
    tt_base__terminate :: proc(self: ^TT_Base) ->Error {

        db__detach_tiny_table(self.db, self)

        self.state = Object_State.Terminated
        self.id = DELETED_INDEX
        self.db = nil

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table

    Tiny_Table :: struct($ROW_CAP: int, $VIEWS_CAP: int, $T: typeid) where ROW_CAP < 11 && VIEWS_CAP < 11 {
        using base: TT_Base, 

        rid_to_eid: [ROW_CAP]entity_id,
        eid_to_ptr: oc.Toa_Map(ROW_CAP * 2, rawptr),
        subscribers: [VIEWS_CAP]^View,
        rows: [ROW_CAP]T,
    }

    tiny_table__init :: proc(self: ^Tiny_Table($ROW_CAP, $VIEWS_CAP, $T), db: ^Database, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(db != nil, loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // table should be NOT_INITIALIZED
            assert(db.state == Object_State.Normal, loc = loc) // db should be initialized
        }

        tt_base__init(cast(^TT_Base) self, db) or_return

        return nil
    }

    tiny_table__terminate :: proc(self: ^Tiny_Table($ROW_CAP, $VIEWS_CAP, $T), loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc) // table should be Normal
            assert(self.db.state == Object_State.Normal, loc = loc) // db should be Normal
        }

        tt_base__terminate(cast(^TT_Base) self) or_return

        return nil
    }

    tiny_table__add_component :: proc(self: ^Tiny_Table($ROW_CAP, $VIEWS_CAP, $T), eid: entity_id) -> (component: ^T, err: Error) {
        err = db__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        return nil, nil
    }

     
///////////////////////////////////////////////////////////////////////////////
// TT_Raw





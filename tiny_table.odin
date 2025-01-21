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
        eid_to_ptr: oc.Toa_Map(ROW_CAP * 2, ^T),
        subscribers: [VIEWS_CAP]^View,
        rows: [ROW_CAP]T,
        len: int,
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

        if self.len >= ROW_CAP do return nil, oc.Core_Error.Container_Is_Full 

        // component = cast(^T) self.eid_to_ptr[eid.ix]
        component = oc.toa_map__get(&self.eid_to_ptr, eid.ix)

        // // Check if component already exist
        // if component == nil {
        //     // Get component
        //     #no_bounds_check {
        //         component = &self.rows[raw.len]
        //     }
                        
        //     // Update eid_to_ptr
        //     self.eid_to_ptr[eid.ix] = component

        //     // Update rid_to_eid
        //     self.rid_to_eid[raw.len] = eid

        //     // Update eid_to_bits in db
        //     db__add_component(self.db, eid, self.id)

        //     raw.len += 1
        // } else {
        //     err = API_Error.Component_Already_Exist
        // }

        // // Notify subscribed views
        // for view in self.subscribers.items {
        //     if !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        // }

        return 
    }

    tiny_table__len :: #force_inline proc "contextless" (self: ^Tiny_Table($ROW_CAP, $VIEWS_CAP, $T)) -> int {
        return ROW_CAP
    }
     
///////////////////////////////////////////////////////////////////////////////
// TT_Raw





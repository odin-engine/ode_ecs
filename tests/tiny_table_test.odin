/*
    2025 (c) Oleh, https://github.com/zm69
*/

package ode_ecs__tests

// 
    import "base:runtime"

// Core
    import "core:testing"
    import "core:fmt"
    import "core:log"
    import "core:slice"
    import "core:mem"
    import "core:time"

// ODE
    import ecs "../src"
    import oc "../src/ode_core"
    import oc_maps "../src/ode_core/maps"


///////////////////////////////////////////////////////////////////////////////
// Tiny_Table

    @(test)
    tiny_table__aattaching_detaching_tables__test :: proc(t: ^testing.T) {
        //
        // Prepare
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ecs_1: ecs.Database
            ais: ecs.Tiny_Table(AI)
            ais2: ecs.Tiny_Table(AI)
            positions: ecs.Tiny_Table(Position)
            pos2: ecs.Tiny_Table(Position)

        //
        // Test
        //
            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.init(&ecs_1, entities_cap=0, allocator=allocator) == ecs.API_Error.Entities_Cap_Should_Be_Greater_Than_Zero)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            testing.expect(t, ecs.tiny_table__init(&ais, &ecs_1) == nil)
            testing.expect(t, ais.id == 0)

            testing.expect(t, ecs.tiny_table__init(&ais2, &ecs_1) == nil)
            defer ecs.tiny_table__terminate(&positions)
            testing.expect(t, ecs.tiny_table__init(&positions, &ecs_1) == nil)

            testing.expect(t, ais.id == 0)
            testing.expect(t, positions.id == 2)

            ecs.tiny_table__terminate(&ais2)

            testing.expect(t, ais2.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[1] == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)

            defer ecs.tiny_table__terminate(&pos2)
            testing.expect(t, ecs.tiny_table__init(&pos2, &ecs_1) == nil)
            testing.expect(t, pos2.id == 1)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == false)

            ecs.tiny_table__terminate(&ais)

            testing.expect(t, ais.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[0] == nil) 
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)
    }

    @(test)
    tiny_table__adding_removing_components__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
            
            ecs_1: ecs.Database
            ais: ecs.Tiny_Table(AI)
            ais_2: ecs.Tiny_Table(AI)
            positions: ecs.Tiny_Table(Position)

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            defer ecs.tiny_table__terminate(&ais)
            testing.expect(t, ecs.tiny_table__init(&ais, &ecs_1) == nil)
            
            defer ecs.tiny_table__terminate(&positions)
            testing.expect(t, ecs.tiny_table__init(&positions, &ecs_1) == nil)

            eid_1, eid_2: ecs.entity_id
            err: ecs.Error

            eid_1, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_1.ix == 0)
            testing.expect(t, err == nil)

            eid_2, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_2.ix == 1)
            testing.expect(t, err == nil)

        //
        // Test
        //

            pos, pos2: ^Position
            ai, ai2: ^AI

            // Boundaries check
            pos, err = ecs.add_component(&positions, ecs.entity_id{ix = 99999})
            testing.expect(t, pos == nil)
            testing.expect(t, err == ecs.API_Error.Entity_Id_Out_of_Bounds)

            pos, err = ecs.add_component(&positions, eid_1)
            testing.expect(t, err == nil)
            testing.expect(t, pos != nil)
            testing.expect(t, pos.x == 0 && pos.y == 0)
            testing.expect(t, ecs.tiny_table__len(&positions) == 1)

            pos2, err = ecs.add_component(&positions, eid_2)
            testing.expect(t, pos2 != nil)
            testing.expect(t, pos2.x == 0 && pos2.y == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table_len(&positions) == 2)

            ai, err = ecs.add_component(&ais, eid_1)
            testing.expect(t, ai != nil)
            testing.expect(t, ai.IQ == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table_len(&ais) == 1)

            ai2, err = ecs.add_component(&ais, eid_2)
            testing.expect(t, ai2 != nil)
            testing.expect(t, ai2.IQ == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table_len(&ais) == 2)

            pos.x = 44
            pos.y = 77

            pos2.x = 55
            pos2.y = 88

            ai.IQ = 66
            ai2.IQ = 42

            // Remove components
            testing.expect(t, oc_maps.tt_map__get(&positions.eid_to_ptr, eid_1.ix) == &positions.rows[0])
            testing.expect(t, oc_maps.tt_map__get(&positions.eid_to_ptr, eid_2.ix) == &positions.rows[1])
            testing.expect(t, positions.rid_to_eid[0] == eid_1)
            testing.expect(t, positions.rid_to_eid[1] == eid_2)
            testing.expect(t, ecs.table_len(&positions) == 2)

            testing.expect(t, ecs.remove_component(&positions, eid_1) == nil)

            testing.expect(t, pos.x == 55)
            testing.expect(t, pos.y == 88)
            
            testing.expect(t, pos2.x == 0)
            testing.expect(t, pos2.y == 0)

            testing.expect(t,  oc_maps.tt_map__get(&positions.eid_to_ptr, eid_1.ix) == nil)
            testing.expect(t,  oc_maps.tt_map__get(&positions.eid_to_ptr, eid_2.ix) == &positions.rows[0])
            testing.expect(t, positions.rid_to_eid[0] == eid_2)
            testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.table_len(&positions) == 1)

            testing.expect(t, ecs.remove_component(&positions, eid_1) == oc.Core_Error.Not_Found)
            testing.expect(t, ecs.remove_component(&positions, eid_2) == nil)

            testing.expect(t, oc_maps.tt_map__get(&positions.eid_to_ptr, eid_1.ix) == nil)
            testing.expect(t, oc_maps.tt_map__get(&positions.eid_to_ptr, eid_2.ix) == nil)
            testing.expect(t, positions.rid_to_eid[0].ix == ecs.DELETED_INDEX)
            testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.table_len(&positions) == 0)

            testing.expect(t, ecs.remove_component(&positions, eid_2) == oc.Core_Error.Not_Found)

            // Get Component
            testing.expect(t, ecs.table_len(&ais) == 2)

            a : ^AI

            a = ecs.get_component(&ais, eid_1)
            testing.expect(t, a != nil)
            testing.expect(t, a == ai)

            a.neurons_count = 111
            
            a = ecs.tiny_table__get_component_by_entity(&ais, eid_2)
            testing.expect(t, a == ai2)

            a.neurons_count = 222

            pos = ecs.tiny_table__get_component_by_entity(&positions, eid_2)
            testing.expect(t, pos == nil)

            //
            // Copy component 
            //

            defer ecs.tiny_table__terminate(&ais_2)
            testing.expect(t, ecs.tiny_table__init(&ais_2, &ecs_1) == nil)

            a, _, err = ecs.copy_component(&ais_2, &ais, eid_2)
            testing.expect(t, err == nil)
            testing.expect(t, a.neurons_count == 222)

            a_2 := ecs.get_component(&ais_2, eid_2)
            testing.expect(t, a.neurons_count == a_2.neurons_count)

            //
            // Move component 
            //

            a, err = ecs.move_component(&ais_2, &ais, eid_1)
            testing.expect(t, err == nil)
            testing.expect(t, a.neurons_count == 111)
            a_2 = ecs.get_component(&ais_2, eid_1)
            testing.expect(t, a == a_2)
            a_2 = ecs.get_component(&ais, eid_1)
            testing.expect(t, a_2 == nil)

            ecs.clear(&ais)
    }


///////////////////////////////////////////////////////////////////////////////
// View

    tiny_table__views_testing :: proc(
        t: ^testing.T,
        ecs_1: ^ecs.Database,
        ais: ^ecs.Tiny_Table(AI),
        positions: ^ecs.Tiny_Table(Position),
        view1: ^ecs.View,
        view2: ^ecs.View,
        view3: ^ecs.View,
        eid_1, eid_2, eid_3: ecs.entity_id
    ) {
        
        err: ecs.Error
        pos: ^Position
        ai: ^AI

        ecs.rebuild(view1)

        testing.expect(t, ecs.view_len(view1) == 2)
        testing.expect(t, ecs.view_len(view3) == 0)

        eids1 := ecs.entities_slice(view1)
        ais1 := ecs.slice(view1, AI)
        pos1 := ecs.slice(view1, Position)
        testing.expect(t, eids1[0] == eid_2)
        testing.expect(t, ais1[0] == ecs.get_component(ais, eid_2))
        testing.expect(t, pos1[0] == ecs.get_component(positions, eid_2))

        testing.expect(t, eids1[1] == eid_1)
        testing.expect(t, ais1[1] == ecs.get_component(ais, eid_1))
        testing.expect(t, pos1[1] == ecs.get_component(positions, eid_1))

        // ADD POS 1
        pos, err = ecs.add_component(positions, eid_3)
        pos.x = 333
        testing.expect(t,  err == nil)
        testing.expect(t, ecs.view_len(view1) == 2)
        testing.expect(t, ecs.view_len(view3) == 1)

        ai, err = ecs.add_component(ais, eid_3)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.view_len(view1) == 3)
        testing.expect(t, ecs.view_len(view3) == 1)

        eids1 = ecs.entities_slice(view1)
        ais1 = ecs.slice(view1, AI)
        pos1 = ecs.slice(view1, Position)
        testing.expect(t, eids1[2] == eid_3)
        testing.expect(t, ais1[2] == ecs.get_component(ais, eid_3))
        testing.expect(t, pos1[2] == ecs.get_component(positions, eid_3))

        ecs.remove_component(ais, eid_1)
        testing.expect(t, ecs.view_len(view1) == 2)
        testing.expect(t, ecs.view_len(view3) == 1)

        eids1 = ecs.entities_slice(view1)
        ais1 = ecs.slice(view1, AI)
        pos1 = ecs.slice(view1, Position)
        testing.expect(t, eids1[0] == eid_2)
        testing.expect(t, ais1[0] == ecs.get_component(ais, eid_2))
        testing.expect(t, pos1[0] == ecs.get_component(positions, eid_2))

        testing.expect(t, eids1[1] == eid_3)
        testing.expect(t, pos1[1] == ecs.get_component(positions, eid_3))

        testing.expect(t, ais1[1] == ecs.get_component(ais, eid_3))

        err = ecs.remove_component(ais, eid_1)
        testing.expect(t, err == oc.Core_Error.Not_Found)
        testing.expect(t, ecs.view_len(view1) == 2)

        ecs.remove_component(ais, eid_3)
        testing.expect(t, ecs.view_len(view1) == 1)

        eids1 = ecs.entities_slice(view1)
        ais1 = ecs.slice(view1, AI)
        pos1 = ecs.slice(view1, Position)
        testing.expect(t, eids1[0] == eid_2)
        testing.expect(t, ais1[0] == ecs.get_component(ais, eid_2))
        testing.expect(t, pos1[0] == ecs.get_component(positions, eid_2))

        ecs.remove_component(ais, eid_2)
        testing.expect(t, ecs.view_len(view1) == 0)

        #no_bounds_check {
            testing.expect(t, view1.rid_to_eid[0].ix == ecs.DELETED_INDEX)
            testing.expect(t, view1.rid_to_eid[0].gen == 0)
            testing.expect(t, view1.columns[0].rows[0] == nil)
            testing.expect(t, view1.columns[1].rows[0] == nil)

            testing.expect(t, view1.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, view1.rid_to_eid[1].gen == 0)
            testing.expect(t, view1.columns[0].rows[1] == nil)
            testing.expect(t, view1.columns[1].rows[1] == nil)
        }

        err = ecs.remove_component(ais, eid_2)
        testing.expect(t, err == oc.Core_Error.Not_Found)
        testing.expect(t, ecs.view_len(view1) == 0)

        testing.expect(t, ecs.view_len(view3) == 1)
        err = ecs.remove_component(positions, eid_2)
        testing.expect(t, ecs.view_len(view3) == 1)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.view_len(view1) == 0)

        ai, err = ecs.add_component(ais, eid_3)
        ai.IQ = 33
        testing.expect(t, err == nil) 
        testing.expect(t, ecs.view_len(view1) == 1)

        eids1 = ecs.entities_slice(view1)
        ais1 = ecs.slice(view1, AI)
        pos1 = ecs.slice(view1, Position)
        testing.expect(t, eids1[0] == eid_3)
        testing.expect(t, ais1[0] == ecs.get_component(ais, eid_3))
        testing.expect(t, pos1[0] == ecs.get_component(positions, eid_3))

        ai, err = ecs.add_component(ais, eid_2)
        ai.IQ = 22
        testing.expect(t, err == nil)
        testing.expect(t, ecs.view_len(view1) == 1)

        ai, err = ecs.add_component(ais, eid_1)
        ai.IQ = 11
        testing.expect(t, err == nil)
        testing.expect(t, ecs.view_len(view1) == 2)

        eids1 = ecs.entities_slice(view1)
        ais1 = ecs.slice(view1, AI)
        pos1 = ecs.slice(view1, Position)
        testing.expect(t, eids1[0] == eid_3)
        testing.expect(t, ais1[0] == ecs.get_component(ais, eid_3))
        testing.expect(t, pos1[0] == ecs.get_component(positions, eid_3))

        testing.expect(t, eids1[1] == eid_1)
        testing.expect(t, ais1[1] == ecs.get_component(ais, eid_1))
        testing.expect(t, pos1[1] == ecs.get_component(positions, eid_1))

        old_cap := view1.cap
        view1.cap = 2

        pos, err = ecs.add_component(positions, eid_2)
        pos.x = 22
        testing.expect(t,  err == nil)
        testing.expect(t, ecs.view_len(view1) == 2)
        testing.expect(t, ecs.view_len(view3) == 2)

        eids3 := ecs.entities_slice(view3)
        pos3 := ecs.slice(view3, Position)
        testing.expect(t, eids3[0] == eid_3)
        testing.expect(t, pos3[0] == ecs.get_component(positions, eid_3))

        testing.expect(t, eids3[1] == eid_2)
        testing.expect(t, pos3[1] == ecs.get_component(positions, eid_2))

        view1.cap = old_cap

        before_error_add_len := ecs.view_len(view1)
        pos, err = ecs.add_component(positions, eid_2)
        pos.x = 222
        testing.expect(t,  err == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, ecs.view_len(view1) == before_error_add_len + 1)

        eids1 = ecs.entities_slice(view1)
        ais1 = ecs.slice(view1, AI)
        pos1 = ecs.slice(view1, Position)
        testing.expect(t, eids1[0] == eid_3)
        testing.expect(t, ais1[0] == ecs.get_component(ais, eid_3))
        testing.expect(t, pos1[0] == ecs.get_component(positions, eid_3))

        testing.expect(t, eids1[1] == eid_1)
        testing.expect(t, ais1[1] == ecs.get_component(ais, eid_1))
        testing.expect(t, pos1[1] == ecs.get_component(positions, eid_1))

        testing.expect(t, eids1[2] == eid_2)
        testing.expect(t, ais1[2] == ecs.get_component(ais, eid_2))
        testing.expect(t, pos1[2] == ecs.get_component(positions, eid_2))

        eids3 = ecs.entities_slice(view3)
        pos3 = ecs.slice(view3, Position)
        testing.expect(t, eids3[0] == eid_3)
        testing.expect(t, pos3[0] == ecs.get_component(positions, eid_3))

        testing.expect(t, eids3[1] == eid_2)
        testing.expect(t, pos3[1] == ecs.get_component(positions, eid_2))

        it: ecs.Iterator
        ecs.iterator_init(&it, view1)

        index: int
        for index = 0; ecs.iterator_next(&it); index+=1 {
            switch index {
                case 0:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 333)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 33)
                case 1:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 111)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 11)
                case 2:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 222)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 22)
                case: 
                    
                    testing.expect(t, false)
            }
        }

        testing.expect(t, index == 3)

        ecs.iterator_init(&it, view1)

        for index=0; ecs.iterator_next(&it); index+=1 {
            switch index {
                case 0:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 333)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 33)
                case 1:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 111)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 11)
                case 2:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 222)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 22)
                case: 
                    testing.expect(t, false)
            }
        }

        testing.expect(t, index == 3)
        testing.expect(t, ecs.view_len(view2) == 3)

        eids2 := ecs.entities_slice(view2)
        ais2 := ecs.slice(view2, AI)
        pos2 := ecs.slice(view2, Position)
        testing.expect(t, eids2[0] == eid_3)
        testing.expect(t, ais2[0] == ecs.get_component(ais, eid_3))
        testing.expect(t, pos2[0] == ecs.get_component(positions, eid_3))
        testing.expect(t, eids2[1] == eid_1)
        testing.expect(t, ais2[1] == ecs.get_component(ais, eid_1))
        testing.expect(t, pos2[1] == ecs.get_component(positions, eid_1))
        testing.expect(t, eids2[2] == eid_2)
        testing.expect(t, ais2[2] == ecs.get_component(ais, eid_2))
        testing.expect(t, pos2[2] == ecs.get_component(positions, eid_2))

        testing.expect(t, ecs.iterator_init(&it, view2) == nil)

        for index = 0; ecs.iterator_next(&it); index += 1 {
            switch index {
                case 0:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 333)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 33)
                case 1:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 111)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 11)
                case 2:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 222)

                    ai = ecs.get_component(ais, &it)
                    testing.expect(t, ai.IQ == 22)
                case: 
                    testing.expect(t, false)
            }
        }

        testing.expect(t, ecs.iterator_init(&it, view3) == nil)

        for index = 0; ecs.iterator_next(&it); index += 1 {
            switch index {
                case 0:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 333)
                case 1:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 222)
                case: 
                    testing.expect(t, false)
            }
        }
        
        err =  ecs.rebuild(view3)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.view_len(view3) == 3)

        testing.expect(t, ecs.iterator_init(&it, view3) == nil)

        for index = 0; ecs.iterator_next(&it); index += 1 {
            switch index {
                case 0:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 333)
                case 1:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 111) 
                case 2:
                    pos = ecs.get_component(positions, &it)
                    testing.expect(t, pos.x == 222)
                case: 
                    testing.expect(t, false)
            }
        }
    }

    tiny_table__create_entities_and_components :: proc (
        t: ^testing.T, 
        ecs_1: ^ecs.Database, 
        positions: ^ecs.Tiny_Table(Position), 
        ais: ^ecs.Tiny_Table(AI)
    ) -> (eid_1, eid_2, eid_3: ecs.entity_id) {
        
        err: ecs.Error
        pos: ^Position
        ai: ^AI

        eid_1, err = ecs.database__create_entity(ecs_1)
        testing.expect(t, eid_1.ix == 0)
        testing.expect(t, err == nil)

        eid_2, err = ecs.database__create_entity(ecs_1)
        testing.expect(t, eid_2.ix == 1)
        testing.expect(t, err == nil)

        eid_3, err = ecs.database__create_entity(ecs_1)
        testing.expect(t, eid_3.ix == 2)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.has_component(positions, eid_2) == false)
        pos, err = ecs.add_component(positions, eid_2)
        testing.expect(t,  err == nil)
        testing.expect(t, ecs.has_component(positions, eid_2) == true)

        ai, err = ecs.add_component(ais, eid_2)
        testing.expect(t, err == nil)

        pos, err = ecs.add_component(positions, eid_1)
        pos.x = 111
        testing.expect(t,  err == nil)

        ai, err = ecs.add_component(ais, eid_1)
        testing.expect(t, err == nil) 

        return 
    }


    @(test)
    tiny_table__views_subscribing_for_updates__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
            
            ecs_1: ecs.Database
            ais: ecs.Tiny_Table(AI)
            positions: ecs.Tiny_Table(Position)
            view1: ecs.View
            view2: ecs.View
            view3: ecs.View
            err: ecs.Error

            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.tiny_table__init(&ais, &ecs_1) == nil)
            testing.expect(t, ecs.tiny_table__init(&positions, &ecs_1) == nil)

        //
        // Test
        //

        eid_1, eid_2, eid_3: ecs.entity_id
        pos: ^Position
        ai: ^AI

        eid_1, eid_2, eid_3 = tiny_table__create_entities_and_components(t, &ecs_1, &positions, &ais)

        testing.expect(t, ecs.view_init(&view1, &ecs_1, {&ais, &positions}) == nil)
        testing.expect(t, ecs.view_len(&view1) == 0)
        testing.expect(t, view1.cap == ecs.TINY_TABLE__ROW_CAP)

        testing.expect(t, ecs.view_init(&view2, &ecs_1, {&ais, &positions}) == nil)
        testing.expect(t, ecs.view_len(&view2) == 0)
        testing.expect(t, view2.cap == ecs.TINY_TABLE__ROW_CAP)

        testing.expect(t, ecs.view_init(&view3, &ecs_1, {&positions}) == nil)
        testing.expect(t, view3.id == 2)
        testing.expect(t, ecs.view_len(&view3) == 0)
        testing.expect(t, view3.cap == ecs.TINY_TABLE__ROW_CAP)

        tiny_table__views_testing(t, &ecs_1, &ais, &positions, &view1, &view2, &view3, eid_1, eid_2, eid_3)

        testing.expect(t, view1.cap == ecs.TINY_TABLE__ROW_CAP)

        testing.expect(t, ecs.clear(&ecs_1) == nil)

        //
        // Repeat after clear to see if everything fine again
        //

        ecs.suspend(&view1)
        ecs.suspend(&view2)
        ecs.suspend(&view3)

        eid_1, eid_2, eid_3 = tiny_table__create_entities_and_components(t, &ecs_1, &positions, &ais)

        ecs.resume(&view1)
        ecs.resume(&view2)
        ecs.resume(&view3)

        //
        // Retest if everything was suspended
        //

        testing.expect(t, ecs.view_len(&view1) == 0)
        testing.expect(t, view1.cap == ecs.TINY_TABLE__ROW_CAP)

        testing.expect(t, ecs.view_len(&view2) == 0)
        testing.expect(t, view2.cap == ecs.TINY_TABLE__ROW_CAP)

        testing.expect(t, view3.id == 2)
        testing.expect(t, ecs.view_len(&view3) == 0)

        testing.expect(t, view3.cap == ecs.TINY_TABLE__ROW_CAP)

        tiny_table__views_testing(t, &ecs_1, &ais, &positions, &view1, &view2, &view3, eid_1, eid_2, eid_3)

        view1.state = ecs.Object_State.Terminated
        testing.expect(t, ecs.clear(&ecs_1) == ecs.API_Error.Object_Invalid)
        view1.state = ecs.Object_State.Normal

        ecs.view_terminate(&view1)

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view1) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.iterator_next(&it) == false)

        testing.expect(t, ecs.view__clear(&view1) == ecs.API_Error.Object_Invalid)

        testing.expect(t, ecs.clear(&ecs_1) == nil)
    }

    @(test)
    tiny_table__filter__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
            
        //
        // Test rerunning filters for entities
        //

            db:     ecs.Database
            view:   ecs.View
            err:    ecs.Error
            eid :   ecs.entity_id
            it:     ecs.Iterator

            human, bird, chair : ecs.entity_id

            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

            human, err = ecs.create_entity(&db)
            testing.expect(t, err == nil) 

            bird, err = ecs.create_entity(&db)
            testing.expect(t, err == nil) 

            chair, err = ecs.create_entity(&db)
            testing.expect(t, err == nil) 

            Character_State :: enum {
                Idle = 0,
                Walking,
                Running,
                Jumping,
                Flying,
                Sliding,
            }

            Movement :: struct {
                speed: f32,
                direction: f32,
                state: Character_State,
            }

            movement_table : ecs.Tiny_Table(Movement)

            err = ecs.tiny_table__init(&movement_table, &db)
            testing.expect(t, err == nil)

            movement: ^Movement

            movement, err = ecs.tiny_table__add_component(&movement_table, human)
            testing.expect(t, err == nil) 

            movement.speed = 5.0
            movement.direction = 180.0  
            movement.state = Character_State.Walking

            movement, err = ecs.tiny_table__add_component(&movement_table, bird)
            testing.expect(t, err == nil)

            movement.speed = 20.0
            movement.direction = 90.0
            movement.state = Character_State.Flying

            movement, err = ecs.tiny_table__add_component(&movement_table, chair)
            testing.expect(t, err == nil)

            movement.speed = 0.0
            movement.direction = 0.0    
            movement.state = Character_State.Idle

            Movement_User_Data :: struct {
                movement_table: ^ecs.Tiny_Table(Movement),
            }

            user_data : Movement_User_Data = Movement_User_Data{ 
                movement_table = &movement_table,
            }

            not_idle_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil)->bool {
                eid := ecs.get_entity(row)
                movement_table := (^Movement_User_Data)(user_data).movement_table

                movement := ecs.get_component(movement_table, row)

                if movement == nil do return false
                if movement.state == Character_State.Idle do return false

                return true
            }

            err = ecs.view_init(&view, &db, {&movement_table}, filter = not_idle_filter)
            testing.expect(t, err == nil)

            view.user_data = &user_data

            err = ecs.rebuild(&view)
            testing.expect(t, err == nil)

            err = ecs.iterator_init(&it, &view)
            testing.expect(t, err == nil)

            human_present := false
            bird_present := false
            chair_present := false

            for ecs.iterator_next(&it) {
                eid = ecs.get_entity(&it)

                movement := ecs.get_component(&movement_table, &it)

                switch eid {
                    case human: human_present = true
                    case bird:  bird_present = true
                    case chair: chair_present = true
                }
            }

            testing.expect(t, human_present == true)
            testing.expect(t, bird_present == true)
            testing.expect(t, chair_present == false)

            movement = ecs.tiny_table__get_component_by_entity(&movement_table, human)
            movement.state = Character_State.Idle

            movement = ecs.tiny_table__get_component_by_entity(&movement_table, chair)
            movement.state = Character_State.Sliding

            human_present = false
            bird_present = false
            chair_present = false

            ecs.iterator_reset(&it)
            for ecs.iterator_next(&it) {
                eid = ecs.get_entity(&it)

                movement := ecs.get_component(&movement_table, &it)

                switch eid {
                    case human: human_present = true
                    case bird:  bird_present = true
                    case chair: chair_present = true
                }
            }

            testing.expect(t, human_present == true)
            testing.expect(t, bird_present == true)
            testing.expect(t, chair_present == false)

            ecs.view__rerun_filter(&view, human)

            ecs.tiny_table__rerun_views_filters(&movement_table, chair)

            human_present = false
            bird_present = false
            chair_present = false

            ecs.iterator_reset(&it)
            for ecs.iterator_next(&it) {
                eid = ecs.get_entity(&it)

                movement := ecs.get_component(&movement_table, &it)

                switch eid {
                    case human: human_present = true
                    case bird:  bird_present = true
                    case chair: chair_present = true
                }
            }

            testing.expect(t, human_present == false)
            testing.expect(t, bird_present == true)
            testing.expect(t, chair_present == true)
    }

///////////////////////////////////////////////////////////////////////////////
// Deferred tail swap (pause_packing / resume_packing / pack)

    @(test)
    tiny_table__pause_packing__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Tiny_Table(Position)
        view: ecs.View

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.tiny_table__init(&positions, &db) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        eids: [5]ecs.entity_id
        for i in 0..<5 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            p, aerr := ecs.add_component(&positions, eid)
            testing.expect(t, aerr == nil)
            p.x = i + 1
            eids[i] = eid
        }

        testing.expect(t, ecs.table_len(&positions) == 5)
        testing.expect(t, ecs.view_len(&view) == 5)

        ecs.pause_packing(&db)

        p1 := ecs.get_component(&positions, eids[1])
        p4 := ecs.get_component(&positions, eids[4])

        testing.expect(t, ecs.remove_component(&positions, eids[2]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 5)
        testing.expect(t, positions.holes_count == 1)
        testing.expect(t, ecs.has_component(&positions, eids[2]) == false)
        testing.expect(t, ecs.get_entity(&positions, 2).ix == ecs.DELETED_INDEX)
        testing.expect(t, ecs.get_component(&positions, eids[1]) == p1)
        testing.expect(t, ecs.get_component(&positions, eids[4]) == p4)
        testing.expect(t, p4.x == 5)
        testing.expect(t, ecs.view_len(&view) == 4)

        testing.expect(t, ecs.remove_component(&positions, eids[4]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 4)
        testing.expect(t, positions.holes_count == 1)

        testing.expect(t, ecs.remove_component(&positions, eids[3]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 2)
        testing.expect(t, positions.holes_count == 0)

        testing.expect(t, ecs.remove_component(&positions, eids[0]) == nil)
        testing.expect(t, positions.holes_count == 1)

        testing.expect(t, ecs.pack(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 1)
        testing.expect(t, ecs.get_entity(&positions, 0) == eids[1])
        testing.expect(t, ecs.get_component(&positions, eids[1]).x == 2)
        testing.expect(t, ecs.view_len(&view) == 1)

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        for ecs.iterator_next(&it) {
            testing.expect(t, ecs.get_entity(&it) == eids[1])
            testing.expect(t, ecs.get_component(&positions, &it) == ecs.get_component(&positions, eids[1]))
        }

        testing.expect(t, ecs.resume_packing(&db) == nil)
        testing.expect(t, ecs.remove_component(&positions, eids[1]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 0)
    }

    @(test)
    tiny_table__pause_packing_standalone__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Tiny_Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.tiny_table__init(&positions, &db) == nil)

        eids: [3]ecs.entity_id
        for i in 0..<3 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            p, aerr := ecs.add_component(&positions, eid)
            testing.expect(t, aerr == nil)
            p.x = i + 1
            eids[i] = eid
        }

        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, db.tail_swap_paused == false)

        testing.expect(t, ecs.remove_component(&positions, eids[1]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 3)
        testing.expect(t, positions.holes_count == 1)
        testing.expect(t, ecs.get_entity(&positions, 1).ix == ecs.DELETED_INDEX)

        testing.expect(t, ecs.resume_packing(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 2)

        testing.expect(t, ecs.remove_component(&positions, eids[0]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 1)
    }

    @(test)
    tiny_table__add_at_cap_already_exists__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Tiny_Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.tiny_table__init(&positions, &db) == nil)

        eids: [ecs.TINY_TABLE__ROW_CAP]ecs.entity_id
        for i in 0..<ecs.TINY_TABLE__ROW_CAP {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            _, aerr := ecs.add_component(&positions, eid)
            testing.expect(t, aerr == nil)
            eids[i] = eid
        }
        testing.expect(t, ecs.table_len(&positions) == ecs.TINY_TABLE__ROW_CAP)

        extra, eerr := ecs.create_entity(&db)
        testing.expect(t, eerr == nil)

        p: ^Position
        err: ecs.Error
        p, err = ecs.add_component(&positions, eids[0])
        testing.expect(t, err == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, p != nil)

        p, err = ecs.add_component(&positions, extra)
        testing.expect(t, err == oc.Core_Error.Container_Is_Full)
        testing.expect(t, p == nil)
    }

    @(test)
    tiny_table__expired_entity_id__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Tiny_Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.tiny_table__init(&positions, &db) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        _, aerr := ecs.add_component(&positions, eid)
        testing.expect(t, aerr == nil)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)

        _, err2 := ecs.add_component(&positions, eid)
        testing.expect(t, err2 == ecs.API_Error.Entity_Id_Expired)
        testing.expect(t, ecs.remove_component(&positions, eid) == ecs.API_Error.Entity_Id_Expired)
        testing.expect(t, ecs.get_component(&positions, eid) == nil)
        testing.expect(t, ecs.has_component(&positions, eid) == false)
    }

    @(test)
    tiny_table__pause_resume_edge_cases__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Tiny_Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.tiny_table__init(&positions, &db) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        _, aerr := ecs.add_component(&positions, eid)
        testing.expect(t, aerr == nil)

        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, ecs.resume_packing(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 1)
        testing.expect(t, ecs.has_component(&positions, eid))

        testing.expect(t, ecs.tiny_table__terminate(&positions) == nil)
        testing.expect(t, ecs.pause_packing(&positions) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.resume_packing(&positions) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.pack(&positions) == ecs.API_Error.Object_Invalid)
    }

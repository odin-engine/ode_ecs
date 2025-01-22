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
    import ecs ".."
    import oc "../ode_core"


///////////////////////////////////////////////////////////////////////////////
// Tiny_Table

    @(test)
    tiny_table__aattaching_detaching_tables__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Tiny_Table(5, 5, AI)
            ais2: ecs.Tiny_Table(5, 5, AI)
            positions: ecs.Tiny_Table(5, 5, Position)
            pos2: ecs.Tiny_Table(5, 5, Position)

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
            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Tiny_Table(5, 5, AI)
            ais_2: ecs.Tiny_Table(5, 5, AI)
            positions: ecs.Tiny_Table(5, 5, Position)

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            defer ecs.tiny_table__terminate(&ais)
            testing.expect(t, ecs.tiny_table__init(&ais, &ecs_1) == nil)
            
            defer ecs.tiny_table__terminate(&positions)
            testing.expect(t, ecs.tiny_table__init(&positions, &ecs_1) == nil)

            eid_1, eid_2: ecs.entity_id
            err: ecs.Error

            eid_1, err = ecs.create_entity(&ecs_1)
            testing.expect(t, eid_1.ix == 0)
            testing.expect(t, err == nil)

            eid_2, err = ecs.create_entity(&ecs_1)
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
            testing.expect(t, oc.toa_map__get(&positions.eid_to_ptr, eid_1.ix) == &positions.rows[0])
            testing.expect(t, oc.toa_map__get(&positions.eid_to_ptr, eid_2.ix) == &positions.rows[1])
            testing.expect(t, positions.rid_to_eid[0] == eid_1)
            testing.expect(t, positions.rid_to_eid[1] == eid_2)
            testing.expect(t, ecs.table_len(&positions) == 2)

            testing.expect(t, ecs.remove_component(&positions, eid_1) == nil)

            // testing.expect(t, pos.x == 55)
            // testing.expect(t, pos.y == 88)
            
            // testing.expect(t, pos2.x == 0)
            // testing.expect(t, pos2.y == 0)

            // testing.expect(t, positions.eid_to_ptr[eid_1.ix] == ecs.DELETED_INDEX)
            // testing.expect(t, positions.eid_to_ptr[eid_2.ix] == 0)
            // testing.expect(t, positions.rid_to_eid[0] == eid_2)
            // testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            // testing.expect(t, ecs.table_len(&positions) == 1)

            // testing.expect(t, ecs.remove_component(&positions, eid_1) == oc.Core_Error.Not_Found)
            // testing.expect(t, ecs.remove_component(&positions, eid_2) == nil)

            // testing.expect(t, positions.eid_to_ptr[eid_1.ix] == ecs.DELETED_INDEX)
            // testing.expect(t, positions.eid_to_ptr[eid_2.ix] == ecs.DELETED_INDEX)
            // testing.expect(t, positions.rid_to_eid[0].ix == ecs.DELETED_INDEX)
            // testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            // testing.expect(t, ecs.table_len(&positions) == 0)

            // testing.expect(t, ecs.remove_component(&positions, eid_2) == oc.Core_Error.Not_Found)

            // // Get Component
            // testing.expect(t, ecs.table_len(&ais) == 2)

            // a : ^AI

            // a = ecs.get_component(&ais, eid_1)
            // testing.expect(t, a != nil)
            // testing.expect(t, a == ai)

            // a.neurons_count = 111
            
            // a = ecs.get_component_by_entity(&ais, eid_2)
            // testing.expect(t, a == ai2)

            // a.neurons_count = 222

            // pos = ecs.get_component_by_entity(&positions, eid_2)
            // testing.expect(t, pos == nil)

            // //
            // // Copy component 
            // //

            // defer ecs.table_terminate(&ais_2)
            // testing.expect(t, ecs.table_init(&ais_2, &ecs_1, 10) == nil)

            // a, _, err = ecs.copy_component(&ais_2, &ais, eid_2)
            // testing.expect(t, err == nil)
            // testing.expect(t, a.neurons_count == 222)

            // a_2 := ecs.get_component_by_entity(&ais_2, eid_2)
            // testing.expect(t, a.neurons_count == a_2.neurons_count)

            // //
            // // Move component 
            // //

            // a, err = ecs.move_component(&ais_2, &ais, eid_1)
            // testing.expect(t, err == nil)
            // testing.expect(t, a.neurons_count == 111)
            // a_2 = ecs.get_component_by_entity(&ais_2, eid_1)
            // testing.expect(t, a == a_2)
            // a_2 = ecs.get_component_by_entity(&ais, eid_1)
            // testing.expect(t, a_2 == nil)

            // ecs.clear(&ais)

    }
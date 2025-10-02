/*
    2025 (c) Oleh, https://github.com/zm69
*/

package ode_ecs__tests

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
    import oc_maps "../ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Database


     @(test)
    compact_table__empty_component__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            empty_table: ecs.Compact_Table(Empty)

        //
        // Test
        //
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)
            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.compact_table__init(&empty_table, &ecs_1, 10) == ecs.API_Error.Component_Size_Cannot_Be_Zero)
    }

    @(test)
    compact_table__attaching_detaching_tables__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Compact_Table(AI)
            ais_table2: ecs.Compact_Table(AI)
            positions: ecs.Compact_Table(Position)
            pos_table2: ecs.Compact_Table(Position)

        //
        // Test
        //
            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.init(&ecs_1, entities_cap=0, allocator=allocator) == ecs.API_Error.Entities_Cap_Should_Be_Greater_Than_Zero)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            testing.expect(t, ecs.compact_table__init(&ais, &ecs_1, 10) == nil)
            testing.expect(t, ais.id == 0)

            testing.expect(t, ecs.compact_table__init(&ais_table2, &ecs_1, 10) == nil)
            defer ecs.compact_table__terminate(&positions)
            testing.expect(t, ecs.compact_table__init(&positions, &ecs_1, 10) == nil)

            testing.expect(t, ais.id == 0)
            testing.expect(t, positions.id == 2)

            ecs.compact_table__terminate(&ais_table2)

            testing.expect(t, ais_table2.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[1] == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)

            defer ecs.compact_table__terminate(&pos_table2)
            testing.expect(t, ecs.compact_table__init(&pos_table2, &ecs_1, 10) == nil)
            testing.expect(t, pos_table2.id == 1)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == false)

            ecs.compact_table__terminate(&ais)

            testing.expect(t, ais.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[0] == nil) 
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)
    }

    @(test)
    compact_table__attaching_detaching_views__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Compact_Table(AI)
            positions: ecs.Compact_Table(Position)
            view1: ecs.View
            view2: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            defer ecs.compact_table__terminate(&ais)
            testing.expect(t, ecs.compact_table__init(&ais, &ecs_1, 10) == nil)
            
            defer ecs.compact_table__terminate(&positions)
            testing.expect(t, ecs.compact_table__init(&positions, &ecs_1, 10) == nil)

            testing.expect(t, ecs.view_init(&view1, &ecs_1, {&ais, &positions}) == nil)

            defer ecs.view_terminate(&view2)
            testing.expect(t, ecs.view_init(&view2, &ecs_1, {}) == ecs.API_Error.Tables_Array_Should_Not_Be_Empty)
            testing.expect(t, ecs.view_init(&view2, &ecs_1, {&positions}) == nil)

            testing.expect(t, oc.sparse_arr__len(&ecs_1.views) == 2)
            testing.expect(t, view1.id == 0)
            testing.expect(t, view2.id == 1)

            ecs.view_terminate(&view1)

            testing.expect(t, view2.id == 1)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.views) == 2)
            testing.expect(t, ecs_1.views.items[0] == nil)
            testing.expect(t, ecs_1.views.has_nil_item)
            
            mem.zero(&view1, size_of(ecs.View))
            testing.expect(t, ecs.view_init(&view1, &ecs_1, {&positions, &ais}) == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.views) == 2)
            testing.expect(t, ecs_1.views.items[0] == &view1)
            testing.expect(t, ecs_1.views.has_nil_item == false)

            ecs.view_terminate(&view1)

            testing.expect(t, oc.sparse_arr__len(&ecs_1.views) == 2)
            testing.expect(t, ecs_1.views.items[0] == nil)
            testing.expect(t, ecs_1.views.has_nil_item)
    }

///////////////////////////////////////////////////////////////////////////////
// Entity
    @(test)
    compact_table__creating_destroying_entities__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=2, allocator=allocator) == nil)

            testing.expect(t,  ecs_1.id_factory.created_count == 0)

            eid_1, eid_2, eid_3: ecs.entity_id
            err: ecs.Error

        //
        // Test
        //

            eid_1, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_1.ix == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs_1.id_factory.created_count == 1)

            eid_2, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_2.ix == 1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs_1.id_factory.created_count == 2)

            eid_3, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_3.ix == ecs.DELETED_INDEX)
            testing.expect(t, err == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs_1.id_factory.created_count == 2)

            testing.expect(t, ecs.database__destroy_entity(&ecs_1, eid_1) == nil)
            testing.expect(t, ecs_1.id_factory.created_count == 2)

            testing.expect(t, ecs.database__destroy_entity(&ecs_1, eid_1) == oc.Core_Error.Already_Freed)
            testing.expect(t, ecs_1.id_factory.created_count == 2)
    }
///////////////////////////////////////////////////////////////////////////////
// Compact_Table

    @(test)
    compact_table__adding_removing_components__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Compact_Table(AI)
            ais_2: ecs.Compact_Table(AI)
            positions: ecs.Compact_Table(Position)

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            defer ecs.compact_table__terminate(&ais)
            testing.expect(t, ecs.compact_table__init(&ais, &ecs_1, 10) == nil)
            
            defer ecs.compact_table__terminate(&positions)
            testing.expect(t, ecs.compact_table__init(&positions, &ecs_1, 10) == nil)

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
            testing.expect(t, ecs.compact_table__len(&positions) == 1)

            pos2, err = ecs.add_component(&positions, eid_2)
            testing.expect(t, pos2 != nil)
            testing.expect(t, pos2.x == 0 && pos2.y == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.compact_table__len(&positions) == 2)

            ai, err = ecs.add_component(&ais, eid_1)
            testing.expect(t, ai != nil)
            testing.expect(t, ai.IQ == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.compact_table__len(&ais) == 1)

            ai2, err = ecs.add_component(&ais, eid_2)
            testing.expect(t, ai2 != nil)
            testing.expect(t, ai2.IQ == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.compact_table__len(&ais) == 2)

            pos.x = 44
            pos.y = 77

            pos2.x = 55
            pos2.y = 88

            ai.IQ = 66
            ai2.IQ = 42

            // Remove components
            //testing.expect(t, positions.eid_to_ptr[eid_1.ix] == &positions.rows[0])
            testing.expect(t, oc_maps.rh_map__get(&positions.eid_to_ptr, eid_1.ix) == &positions.rows[0])
            //testing.expect(t, positions.eid_to_ptr[eid_2.ix] == &positions.rows[1])
            testing.expect(t, oc_maps.rh_map__get(&positions.eid_to_ptr, eid_2.ix) == &positions.rows[1])
            testing.expect(t, positions.rid_to_eid[0] == eid_1)
            testing.expect(t, positions.rid_to_eid[1] == eid_2)
            testing.expect(t, ecs.compact_table__len(&positions) == 2)

            testing.expect(t, ecs.remove_component(&positions, eid_1) == nil)

            testing.expect(t, pos.x == 55)
            testing.expect(t, pos.y == 88)
            
            testing.expect(t, pos2.x == 0)
            testing.expect(t, pos2.y == 0)

            //testing.expect(t, positions.eid_to_ptr[eid_1.ix] == nil)
            testing.expect(t, oc_maps.rh_map__get(&positions.eid_to_ptr, eid_1.ix) == nil)
            //testing.expect(t, positions.eid_to_ptr[eid_2.ix] == &positions.rows[0])
            testing.expect(t, oc_maps.rh_map__get(&positions.eid_to_ptr, eid_2.ix) == &positions.rows[0])  
            testing.expect(t, positions.rid_to_eid[0] == eid_2)
            testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.compact_table__len(&positions) == 1)

            testing.expect(t, ecs.remove_component(&positions, eid_1) == oc.Core_Error.Not_Found)
            testing.expect(t, ecs.remove_component(&positions, eid_2) == nil)

            //testing.expect(t, positions.eid_to_ptr[eid_1.ix] == nil)
            testing.expect(t, oc_maps.rh_map__get(&positions.eid_to_ptr, eid_1.ix) == nil)
            //testing.expect(t, positions.eid_to_ptr[eid_2.ix] == nil)
            testing.expect(t, oc_maps.rh_map__get(&positions.eid_to_ptr, eid_2.ix) == nil)
            testing.expect(t, positions.rid_to_eid[0].ix == ecs.DELETED_INDEX)
            testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.compact_table__len(&positions) == 0)

            testing.expect(t, ecs.remove_component(&positions, eid_2) == oc.Core_Error.Not_Found)

            // Get Component
            testing.expect(t, ecs.compact_table__len(&ais) == 2)

            a : ^AI
   
            a = ecs.get_component(&ais, eid_1)
            testing.expect(t, a != nil)
            testing.expect(t, a == ai)

            a.neurons_count = 111
            
            a = ecs.get_component(&ais, eid_2)
            testing.expect(t, a == ai2)

            a.neurons_count = 222

            pos = ecs.get_component(&positions, eid_2)
            testing.expect(t, pos == nil)

            //
            // Copy component 
            //

            defer ecs.compact_table__terminate(&ais_2)
            testing.expect(t, ecs.compact_table__init(&ais_2, &ecs_1, 10) == nil)

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

    compact_table__views_testing :: proc(
        t: ^testing.T,
        ecs_1: ^ecs.Database,
        ais: ^ecs.Compact_Table(AI),
        positions: ^ecs.Compact_Table(Position),
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
 
        r := ecs.view__get_record(view1, 0)
        testing.expect(t, r.eid == eid_2)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_2))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_2))

        r = ecs.view__get_record(view1, 1)
        testing.expect(t, r.eid == eid_1)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_1))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_1))

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

        r = ecs.view__get_record(view1, 2)
        testing.expect(t, r.eid == eid_3)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_3))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_3))

        ecs.remove_component(ais, eid_1) 
        testing.expect(t, ecs.view_len(view1) == 2)
        testing.expect(t, ecs.view_len(view3) == 1)

        r = ecs.view__get_record(view1, 0)
        testing.expect(t, r.eid == eid_2)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_2))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_2))

        r = ecs.view__get_record(view1, 1)
        testing.expect(t, r.eid == eid_3)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_3))
        
        // ais.eid_to_ptr[eid_3.ix] was changed because ais component was removed
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_3))

        err = ecs.remove_component(ais, eid_1)
        testing.expect(t, err == oc.Core_Error.Not_Found) 
        testing.expect(t, ecs.view_len(view1) == 2)

        ecs.remove_component(ais, eid_3)
        testing.expect(t, ecs.view_len(view1) == 1)

        r = ecs.view__get_record(view1, 0)
        testing.expect(t, r.eid == eid_2)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_2))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_2))

        testing.expect(t, ecs.view__get_record(view1, 1) == nil)

        ecs.remove_component(ais, eid_2)
        testing.expect(t, ecs.view_len(view1) == 0)

        #no_bounds_check {
            // Direct memory check 
            testing.expect(t, ((^ecs.View_Row_Raw)(&view1.rows[0])).eid.ix == ecs.DELETED_INDEX)
            testing.expect(t, ((^ecs.View_Row_Raw)(&view1.rows[0])).eid.gen == 0)
            testing.expect(t, ((^ecs.View_Row_Raw)(&view1.rows[0])).refs[0] == nil)
            testing.expect(t, ((^ecs.View_Row_Raw)(&view1.rows[0])).refs[1] == nil)

            testing.expect(t, ((^ecs.View_Row_Raw)(&view1.rows[0 + view1.one_record_size])).eid.ix == ecs.DELETED_INDEX)
            testing.expect(t, ((^ecs.View_Row_Raw)(&view1.rows[0 + view1.one_record_size])).eid.gen == 0)
            testing.expect(t, ((^ecs.View_Row_Raw)(&view1.rows[0 + view1.one_record_size])).refs[0] == nil)
            testing.expect(t, ((^ecs.View_Row_Raw)(&view1.rows[0 + view1.one_record_size])).refs[1] == nil)
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

        r = ecs.view__get_record(view1, 0)
        testing.expect(t, r.eid == eid_3)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_3))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_3))

        ai, err = ecs.add_component(ais, eid_2)
        ai.IQ = 22
        testing.expect(t, err == nil) 
        testing.expect(t, ecs.view_len(view1) == 1)

        ai, err = ecs.add_component(ais, eid_1)
        ai.IQ = 11
        testing.expect(t, err == nil) 
        testing.expect(t, ecs.view_len(view1) == 2)

        r = ecs.view__get_record(view1, 0)
        testing.expect(t, r.eid == eid_3)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_3))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_3))

        r = ecs.view__get_record(view1, 1)
        testing.expect(t, r.eid == eid_1)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_1))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_1))

        // FORCE CAP = 2
        old_cap := view1.cap
        view1.cap = 2

        // ADD POS
        pos, err = ecs.add_component(positions, eid_2)
        pos.x = 22
        testing.expect(t,  err == nil)
        testing.expect(t, ecs.view_len(view1) == 2) // LEN DIDN'T INCREASE, BECAUSE OF CAP
        testing.expect(t, ecs.view_len(view3) == 2)

        r = ecs.view__get_record(view3, 0)
        testing.expect(t, r.eid == eid_3)
        testing.expect(t, ecs.view__get_component_for_compact_table(view3, r, positions) == ecs.get_component(positions, eid_3))

        r = ecs.view__get_record(view3, 1)
        testing.expect(t, r.eid == eid_2)
        testing.expect(t, ecs.view__get_component_for_compact_table(view3, r, positions) == ecs.get_component(positions, eid_2))

        // RESTORE CAP
        view1.cap = old_cap

        // ADD POS
        before_error_add_len := ecs.view_len(view1)
        pos, err = ecs.add_component(positions, eid_2)     
        pos.x = 222       
        testing.expect(t,  err == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, ecs.view_len(view1) == before_error_add_len + 1)

        // view1 

        r = ecs.view__get_record(view1, 0)
        testing.expect(t, r.eid == eid_3)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_3))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_3))

        r = ecs.view__get_record(view1, 1)
        testing.expect(t, r.eid == eid_1)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_1))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_1))

        r = ecs.view__get_record(view1, 2)
        testing.expect(t, r.eid == eid_2)
        testing.expect(t, r.eid == eid_2)
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, ais) == ecs.get_component(ais, eid_2))
        testing.expect(t, ecs.view__get_component_for_compact_table(view1, r, positions) == ecs.get_component(positions, eid_2))

        // view3
        
        r = ecs.view__get_record(view3, 0)
        testing.expect(t, r.eid == eid_3)
        testing.expect(t, ecs.view__get_component_for_compact_table(view3, r, positions) == ecs.get_component(positions, eid_3))

        r = ecs.view__get_record(view3, 1)
        testing.expect(t, r.eid == eid_2)
        testing.expect(t, ecs.view__get_component_for_compact_table(view3, r, positions) == ecs.get_component(positions, eid_2))

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

        // Init again and see if everything still works
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

        r = ecs.view__get_record(view2, 0)
        testing.expect(t, r.eid == eid_3)
        testing.expect(t, ecs.view__get_component_for_compact_table(view2, r, ais) == ecs.get_component(ais, eid_3))
        testing.expect(t, ecs.view__get_component_for_compact_table(view2, r, positions) == ecs.get_component(positions, eid_3))
        r = ecs.view__get_record(view2, 1)
        testing.expect(t, r.eid == eid_1)
        testing.expect(t, ecs.view__get_component_for_compact_table(view2, r, ais) == ecs.get_component(ais, eid_1))
        testing.expect(t, ecs.view__get_component_for_compact_table(view2, r, positions) == ecs.get_component(positions, eid_1))
        r = ecs.view__get_record(view2, 2)
        testing.expect(t, r.eid == eid_2)
        testing.expect(t, ecs.view__get_component_for_compact_table(view2, r, ais) == ecs.get_component(ais, eid_2))
        testing.expect(t, ecs.view__get_component_for_compact_table(view2, r, positions) == ecs.get_component(positions, eid_2))

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

    compact_table__create_entities_and_components :: proc (
        t: ^testing.T, 
        ecs_1: ^ecs.Database, 
        positions: ^ecs.Compact_Table(Position), 
        ais: ^ecs.Compact_Table(AI)
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
    compact_table__views_subscribing_for_updates__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Compact_Table(AI)
            positions: ecs.Compact_Table(Position)
            view1: ecs.View
            view2: ecs.View
            view3: ecs.View
            err: ecs.Error

            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.compact_table__init(&ais, &ecs_1, 8) == nil)
            testing.expect(t, ecs.compact_table__init(&positions, &ecs_1, 10) == nil)

        //
        // Test
        //

        eid_1, eid_2, eid_3: ecs.entity_id
        pos: ^Position
        ai: ^AI

        // Create some entities and components
    
        eid_1, eid_2, eid_3 = compact_table__create_entities_and_components(t, &ecs_1, &positions, &ais)

        // Init views

        testing.expect(t, ecs.view_init(&view1, &ecs_1, {&ais, &positions}) == nil)
        testing.expect(t, ecs.view_len(&view1) == 0)
        testing.expect(t, view1.cap == 8)

        testing.expect(t, ecs.view_init(&view2, &ecs_1, {&ais, &positions}) == nil)
        testing.expect(t, ecs.view_len(&view2) == 0)
        testing.expect(t, view2.cap == 8)

        testing.expect(t, ecs.view_init(&view3, &ecs_1, {&positions}) == nil)
        testing.expect(t, view3.id == 2)
        testing.expect(t, ecs.view_len(&view3) == 0)

        testing.expect(t, view3.cap == 10)

        compact_table__views_testing(t, &ecs_1, &ais, &positions, &view1, &view2, &view3, eid_1, eid_2, eid_3)

        testing.expect(t, view1.cap == 8)

        // clear
        testing.expect(t, ecs.clear(&ecs_1) == nil)

        //
        // Repeat after clear to see if everything fine again
        // 

        // Create some entities and components

        ecs.suspend(&view1)
        ecs.suspend(&view2)
        ecs.suspend(&view3)

        eid_1, eid_2, eid_3 = compact_table__create_entities_and_components(t, &ecs_1, &positions, &ais)

        ecs.resume(&view1)
        ecs.resume(&view2)
        ecs.resume(&view3)

        //
        // Retest if everything was suspended
        //

        testing.expect(t, ecs.view_len(&view1) == 0)
        testing.expect(t, view1.cap == 8)

        testing.expect(t, ecs.view_len(&view2) == 0)
        testing.expect(t, view2.cap == 8)

        testing.expect(t, view3.id == 2)
        testing.expect(t, ecs.view_len(&view3) == 0)
        testing.expect(t, view3.cap == 10)

        compact_table__views_testing(t, &ecs_1, &ais, &positions, &view1, &view2, &view3, eid_1, eid_2, eid_3)

        view1.state = ecs.Object_State.Terminated
        testing.expect(t, ecs.clear(&ecs_1) == ecs.API_Error.Object_Invalid)
        view1.state = ecs.Object_State.Normal

        // this removes view1 from db and ecs.clear()
        ecs.view_terminate(&view1)

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view1) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.iterator_next(&it) == false)

        testing.expect(t, ecs.view__clear(&view1) == ecs.API_Error.Object_Invalid)

        // because view1 is terminated, it is removed from db and dont cause clear() to fail
        testing.expect(t, ecs.clear(&ecs_1) == nil) 
    }


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

///////////////////////////////////////////////////////////////////////////////
// Components

    Position :: struct {
        x, y: int
    }
    
    AI :: struct {
        IQ: f32,
        neurons_count: int
    }
    
///////////////////////////////////////////////////////////////////////////////
// Database

    @(test)
    attaching_detaching_tables__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Table(AI)
            ais_table2: ecs.Table(AI)
            positions: ecs.Table(Position)
            pos_table2: ecs.Table(Position)

        //
        // Test
        //
            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.init(&ecs_1, entities_cap=0, allocator=allocator) == ecs.API_Error.Entities_Cap_Should_Be_Greater_Than_Zero)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            testing.expect(t, ecs.table__init(&ais, &ecs_1, 10) == nil)
            testing.expect(t, ais.id == 0)

            testing.expect(t, ecs.table__init(&ais_table2, &ecs_1, 10) == nil)
            defer ecs.table__terminate(&positions)
            testing.expect(t, ecs.table__init(&positions, &ecs_1, 10) == nil)

            testing.expect(t, ais.id == 0)
            testing.expect(t, positions.id == 2)

            ecs.table__terminate(&ais_table2)

            testing.expect(t, ais_table2.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[1] == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)

            defer ecs.table__terminate(&pos_table2)
            testing.expect(t, ecs.table__init(&pos_table2, &ecs_1, 10) == nil)
            testing.expect(t, pos_table2.id == 1)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == false)

            ecs.table__terminate(&ais)

            testing.expect(t, ais.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[0] == nil) 
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)
    }

    @(test)
    attaching_detaching_views__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Table(AI)
            positions: ecs.Table(Position)
            view1: ecs.View
            view2: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            defer ecs.table__terminate(&ais)
            testing.expect(t, ecs.table__init(&ais, &ecs_1, 10) == nil)
            
            defer ecs.table__terminate(&positions)
            testing.expect(t, ecs.table__init(&positions, &ecs_1, 10) == nil)

            testing.expect(t, ecs.view__init(&view1, &ecs_1, {&ais, &positions}) == nil)

            defer ecs.view__terminate(&view2)
            testing.expect(t, ecs.view__init(&view2, &ecs_1, {}) == ecs.API_Error.Tables_Array_Should_Not_Be_Empty)
            testing.expect(t, ecs.view__init(&view2, &ecs_1, {&positions}) == nil)

            testing.expect(t, oc.sparse_arr__len(&ecs_1.views) == 2)
            testing.expect(t, view1.id == 0)
            testing.expect(t, view2.id == 1)

            ecs.view__terminate(&view1)

            testing.expect(t, view2.id == 1)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.views) == 2)
            testing.expect(t, ecs_1.views.items[0] == nil)
            testing.expect(t, ecs_1.views.has_nil_item)
            
            mem.zero(&view1, size_of(ecs.View))
            testing.expect(t, ecs.view__init(&view1, &ecs_1, {&positions, &ais}) == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.views) == 2)
            testing.expect(t, ecs_1.views.items[0] == &view1)
            testing.expect(t, ecs_1.views.has_nil_item == false)

            ecs.view__terminate(&view1)

            testing.expect(t, oc.sparse_arr__len(&ecs_1.views) == 2)
            testing.expect(t, ecs_1.views.items[0] == nil)
            testing.expect(t, ecs_1.views.has_nil_item)
    }

///////////////////////////////////////////////////////////////////////////////
// Entity
    @(test)
    creating_destroying_entities__test :: proc(t: ^testing.T) {
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

            eid_1, err = ecs.create_entity(&ecs_1)
            testing.expect(t, eid_1.ix == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs_1.id_factory.created_count == 1)

            eid_2, err = ecs.create_entity(&ecs_1)
            testing.expect(t, eid_2.ix == 1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs_1.id_factory.created_count == 2)

            eid_3, err = ecs.create_entity(&ecs_1)
            testing.expect(t, eid_3.ix == ecs.DELETED_INDEX)
            testing.expect(t, err == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs_1.id_factory.created_count == 2)

            testing.expect(t, ecs.destroy_entity(&ecs_1, eid_1) == nil)
            testing.expect(t, ecs_1.id_factory.created_count == 2)

            testing.expect(t, ecs.destroy_entity(&ecs_1, eid_1) == oc.Core_Error.Already_Freed)
            testing.expect(t, ecs_1.id_factory.created_count == 2)
    }
///////////////////////////////////////////////////////////////////////////////
// Table

    @(test)
    adding_removing_components__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Table(AI)
            positions: ecs.Table(Position)

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            defer ecs.table__terminate(&ais)
            testing.expect(t, ecs.table__init(&ais, &ecs_1, 10) == nil)
            
            defer ecs.table__terminate(&positions)
            testing.expect(t, ecs.table__init(&positions, &ecs_1, 10) == nil)

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
            pos, err = ecs.table__add_component(&positions, ecs.entity_id{ix = 99999})
            testing.expect(t, pos == nil)
            testing.expect(t, err == ecs.API_Error.Entity_Id_Out_of_Bounds)

            pos, err = ecs.table__add_component(&positions, eid_1)
            testing.expect(t, err == nil)
            testing.expect(t, pos != nil)
            testing.expect(t, pos.x == 0 && pos.y == 0)
            testing.expect(t, ecs.table__len(&positions) == 1)

            pos2, err = ecs.table__add_component(&positions, eid_2)
            testing.expect(t, pos2 != nil)
            testing.expect(t, pos2.x == 0 && pos2.y == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table__len(&positions) == 2)

            ai, err = ecs.table__add_component(&ais, eid_1)
            testing.expect(t, ai != nil)
            testing.expect(t, ai.IQ == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table__len(&ais) == 1)

            ai2, err = ecs.table__add_component(&ais, eid_2)
            testing.expect(t, ai2 != nil)
            testing.expect(t, ai2.IQ == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table__len(&ais) == 2)

            pos.x = 44
            pos.y = 77

            pos2.x = 55
            pos2.y = 88

            ai.IQ = 66
            ai2.IQ = 42

            // Remove components
            testing.expect(t, positions.eid_to_rid[eid_1.ix] == 0)
            testing.expect(t, positions.eid_to_rid[eid_2.ix] == 1)
            testing.expect(t, positions.rid_to_eid[0] == eid_1)
            testing.expect(t, positions.rid_to_eid[1] == eid_2)
            testing.expect(t, ecs.table__len(&positions) == 2)

            testing.expect(t, ecs.table__remove_component(&positions, eid_1) == nil)

            testing.expect(t, pos.x == 55)
            testing.expect(t, pos.y == 88)
            
            testing.expect(t, pos2.x == 0)
            testing.expect(t, pos2.y == 0)

            testing.expect(t, positions.eid_to_rid[eid_1.ix] == ecs.DELETED_INDEX)
            testing.expect(t, positions.eid_to_rid[eid_2.ix] == 0)
            testing.expect(t, positions.rid_to_eid[0] == eid_2)
            testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.table__len(&positions) == 1)

            testing.expect(t, ecs.table__remove_component(&positions, eid_1) == oc.Core_Error.Not_Found)
            testing.expect(t, ecs.table__remove_component(&positions, eid_2) == nil)

            testing.expect(t, positions.eid_to_rid[eid_1.ix] == ecs.DELETED_INDEX)
            testing.expect(t, positions.eid_to_rid[eid_2.ix] == ecs.DELETED_INDEX)
            testing.expect(t, positions.rid_to_eid[0].ix == ecs.DELETED_INDEX)
            testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.table__len(&positions) == 0)

            testing.expect(t, ecs.table__remove_component(&positions, eid_2) == oc.Core_Error.Not_Found)

            // Get Component
            testing.expect(t, ecs.table__len(&ais) == 2)

            a : ^AI
   
            a, err = ecs.get_component(&ais, eid_1)
            testing.expect(t, a == ai)
            testing.expect(t, err == nil)

            a, err = ecs.table__get_component_by_entity_id(&ais, ecs.entity_id{ix = 99999})
            testing.expect(t, a == nil)
            testing.expect(t, err == ecs.API_Error.Entity_Id_Out_of_Bounds)

            
            a, err = ecs.table__get_component_by_entity_id(&ais, eid_2)
            testing.expect(t, a == ai2)
            testing.expect(t, err == nil)

            pos, err = ecs.table__get_component_by_entity_id(&positions, eid_2)
            testing.expect(t, pos == nil)
            testing.expect(t, err == oc.Core_Error.Not_Found)
    }

///////////////////////////////////////////////////////////////////////////////
// View

    views_testing :: proc(
        t: ^testing.T,
        ecs_1: ^ecs.Database,
        ais: ^ecs.Table(AI),
        positions: ^ecs.Table(Position),
        view1: ^ecs.View,
        view2: ^ecs.View,
        view3: ^ecs.View,
        eid_1, eid_2, eid_3: ecs.entity_id
    ) {
        
        err: ecs.Error
        pos: ^Position
        ai: ^AI

        ecs.rebuild(view1)

        testing.expect(t, ecs.view__len(view1) == 2)
        testing.expect(t, ecs.view__len(view3) == 0)
        
        #no_bounds_check {
            testing.expect(t, view1.records[0] == eid_2.ix)
            testing.expect(t, view1.records[0 + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_2.ix])
            testing.expect(t, view1.records[0 + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_2.ix])
            testing.expect(t, view1.records[1 * view1.columns_count] == eid_1.ix)
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_1.ix])
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_1.ix])         
        }

        // ADD POS 1
        pos, err = ecs.table__add_component(positions, eid_3)
        pos.x = 333
        testing.expect(t,  err == nil)
        testing.expect(t, ecs.view__len(view1) == 2)
        testing.expect(t, ecs.view__len(view3) == 1)

        ai, err = ecs.table__add_component(ais, eid_3)
        testing.expect(t, err == nil) 
        testing.expect(t, ecs.view__len(view1) == 3)
        testing.expect(t, ecs.view__len(view3) == 1)

        #no_bounds_check {
            testing.expect(t, view1.records[2 * view1.columns_count] == eid_3.ix)
            testing.expect(t, view1.records[2 * view1.columns_count + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_3.ix])
            testing.expect(t, view1.records[2 * view1.columns_count + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_3.ix])  
        }
        
        ecs.table__remove_component(ais, eid_1) 
        testing.expect(t, ecs.view__len(view1) == 2)
        testing.expect(t, ecs.view__len(view3) == 1)

        #no_bounds_check {
            testing.expect(t, view1.records[0] == eid_2.ix)
            testing.expect(t, view1.records[0 + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_2.ix])
            testing.expect(t, view1.records[0 + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_2.ix])
            testing.expect(t, view1.records[1 * view1.columns_count] == eid_3.ix)
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_3.ix]) 

            // ais.eid_to_rid[eid_3.ix] was changed because ais component was removed
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_3.ix])
        }
        err = ecs.table__remove_component(ais, eid_1)
        testing.expect(t, err == oc.Core_Error.Not_Found) 
        testing.expect(t, ecs.view__len(view1) == 2)

        ecs.table__remove_component(ais, eid_3)
        testing.expect(t, ecs.view__len(view1) == 1)

        #no_bounds_check {
            testing.expect(t, view1.records[0] == eid_2.ix)
            testing.expect(t, view1.records[0 + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_2.ix])
            testing.expect(t, view1.records[0 + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_2.ix])
            testing.expect(t, view1.records[1 * view1.columns_count] == ecs.DELETED_INDEX)
            testing.expect(t, view1.records[1 * view1.columns_count + 1] == ecs.DELETED_INDEX) 
            testing.expect(t, view1.records[1 * view1.columns_count + 2] == ecs.DELETED_INDEX)
        }

        ecs.table__remove_component(ais, eid_2)
        testing.expect(t, ecs.view__len(view1) == 0)

        #no_bounds_check {
            testing.expect(t, view1.records[0] == ecs.DELETED_INDEX)
            testing.expect(t, view1.records[0 + view1.tid_to_cid[ais.id]] == ecs.DELETED_INDEX)
            testing.expect(t, view1.records[0 + view1.tid_to_cid[positions.id]] == ecs.DELETED_INDEX)
            testing.expect(t, view1.records[1 * view1.columns_count] == ecs.DELETED_INDEX)
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[ais.id]] == ecs.DELETED_INDEX) 
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[positions.id]] == ecs.DELETED_INDEX)
        }

        err = ecs.table__remove_component(ais, eid_2)
        testing.expect(t, err == oc.Core_Error.Not_Found)
        testing.expect(t, ecs.view__len(view1) == 0)

        testing.expect(t, ecs.view__len(view3) == 1)
        err = ecs.table__remove_component(positions, eid_2)
        testing.expect(t, ecs.view__len(view3) == 1)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.view__len(view1) == 0)

        ai, err = ecs.table__add_component(ais, eid_3)
        ai.IQ = 33
        testing.expect(t, err == nil) 
        testing.expect(t, ecs.view__len(view1) == 1)

        #no_bounds_check {
            testing.expect(t, view1.records[0] == eid_3.ix)
            testing.expect(t, view1.records[0 + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_3.ix])
            testing.expect(t, view1.records[0 + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_3.ix])
        }

        ai, err = ecs.table__add_component(ais, eid_2)
        ai.IQ = 22
        testing.expect(t, err == nil) 
        testing.expect(t, ecs.view__len(view1) == 1)

        ai, err = ecs.table__add_component(ais, eid_1)
        ai.IQ = 11
        testing.expect(t, err == nil) 
        testing.expect(t, ecs.view__len(view1) == 2)

        #no_bounds_check {
            testing.expect(t, view1.records[0] == eid_3.ix)
            testing.expect(t, view1.records[0 + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_3.ix])
            testing.expect(t, view1.records[0 + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_3.ix])
            testing.expect(t, view1.records[1 * view1.columns_count] == eid_1.ix)
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_1.ix]) 
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_1.ix])
        }

        // force cap = 2
        old_cap := view1.cap
        view1.cap = 2

        // ADD POS
        pos, err = ecs.table__add_component(positions, eid_2)
        pos.x = 22
        testing.expect(t,  err == nil)
        testing.expect(t, ecs.view__len(view1) == 2)
        testing.expect(t, ecs.view__len(view3) == 2)

        #no_bounds_check {
            testing.expect(t, view3.records[0] == eid_3.ix)
            testing.expect(t, view3.records[0 + view3.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_3.ix])
            testing.expect(t, view3.records[1 * view3.columns_count] == eid_2.ix)
            testing.expect(t, view3.records[1 * view3.columns_count + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_2.ix]) 
        }

        view1.cap = old_cap

        // ADD POS
        pos, err = ecs.table__add_component(positions, eid_2)     
        pos.x = 222       
        testing.expect(t,  err == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, ecs.view__len(view1) == 3)

        #no_bounds_check {
            testing.expect(t, view1.records[0] == eid_3.ix)
            testing.expect(t, view1.records[0 + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_3.ix])
            testing.expect(t, view1.records[0 + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_3.ix])
            testing.expect(t, view1.records[1 * view1.columns_count] == eid_1.ix)
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_1.ix]) 
            testing.expect(t, view1.records[1 * view1.columns_count + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_1.ix])
            testing.expect(t, view1.records[2 * view1.columns_count] == eid_2.ix)
            testing.expect(t, view1.records[2 * view1.columns_count + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_2.ix]) 
            testing.expect(t, view1.records[2 * view1.columns_count + view1.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_2.ix])
        }

        #no_bounds_check {
            testing.expect(t, view3.records[0] == eid_3.ix)
            testing.expect(t, view3.records[0 + view3.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_3.ix])
            testing.expect(t, view3.records[1 * view3.columns_count] == eid_2.ix)
            testing.expect(t, view3.records[1 * view3.columns_count + view1.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_2.ix]) 
        }

        it: ecs.Iterator
        ecs.iterator_init(&it, view1)

        for ecs.iterator__next(&it) {
            switch it.index {
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

        testing.expect(t, it.index == 3)

        // Init again and see if everything still works
        ecs.iterator_init(&it, view1)

        for ecs.iterator__next(&it) {
            switch it.index {
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

        testing.expect(t, it.index == 3)
        testing.expect(t, ecs.view__len(view2) == 3)

        #no_bounds_check {
            testing.expect(t, view2.records[0] == eid_3.ix)
            testing.expect(t, view2.records[0 + view2.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_3.ix])
            testing.expect(t, view2.records[0 + view2.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_3.ix])
            testing.expect(t, view2.records[1 * view2.columns_count] == eid_1.ix)
            testing.expect(t, view2.records[1 * view2.columns_count + view2.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_1.ix]) 
            testing.expect(t, view2.records[1 * view2.columns_count + view2.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_1.ix])
            testing.expect(t, view2.records[2 * view2.columns_count] == eid_2.ix)
            testing.expect(t, view2.records[2 * view2.columns_count + view2.tid_to_cid[positions.id]] == cast(int) positions.eid_to_rid[eid_2.ix]) 
            testing.expect(t, view2.records[2 * view2.columns_count + view2.tid_to_cid[ais.id]] == cast(int) ais.eid_to_rid[eid_2.ix])
        }

        testing.expect(t, ecs.iterator_init(&it, view2) == nil)

        for ecs.iterator__next(&it) {
            switch it.index {
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

        for ecs.iterator__next(&it) {
            switch it.index {
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

        for ecs.iterator__next(&it) {
            switch it.index {
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

    create_entities_and_components :: proc (
        t: ^testing.T, 
        ecs_1: ^ecs.Database, 
        positions: ^ecs.Table(Position), 
        ais: ^ecs.Table(AI)
    ) -> (eid_1, eid_2, eid_3: ecs.entity_id) {
        
        err: ecs.Error
        pos: ^Position
        ai: ^AI

        eid_1, err = ecs.create_entity(ecs_1)
        testing.expect(t, eid_1.ix == 0)
        testing.expect(t, err == nil)

        eid_2, err = ecs.create_entity(ecs_1)
        testing.expect(t, eid_2.ix == 1)
        testing.expect(t, err == nil)

        eid_3, err = ecs.create_entity(ecs_1)
        testing.expect(t, eid_3.ix == 2)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.has_component(positions, eid_2) == false)
        pos, err = ecs.table__add_component(positions, eid_2)
        testing.expect(t,  err == nil)
        testing.expect(t, ecs.has_component(positions, eid_2) == true)

        ai, err = ecs.table__add_component(ais, eid_2)
        testing.expect(t, err == nil)

        pos, err = ecs.table__add_component(positions, eid_1)
        pos.x = 111
        testing.expect(t,  err == nil)

        ai, err = ecs.table__add_component(ais, eid_1)
        testing.expect(t, err == nil) 

        return 
    }


    @(test)
    views_subscribing_for_updates__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
            
            ecs_1: ecs.Database
            ais: ecs.Table(AI)
            positions: ecs.Table(Position)
            view1: ecs.View
            view2: ecs.View
            view3: ecs.View
            err: ecs.Error

            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table__init(&ais, &ecs_1, 8) == nil)
            testing.expect(t, ecs.table__init(&positions, &ecs_1, 10) == nil)

        //
        // Test
        //

        eid_1, eid_2, eid_3: ecs.entity_id
        pos: ^Position
        ai: ^AI

        // Create some entities and components
    
        eid_1, eid_2, eid_3 = create_entities_and_components(t, &ecs_1, &positions, &ais)

        // Init views

        testing.expect(t, ecs.view__init(&view1, &ecs_1, {&ais, &positions}) == nil)
        testing.expect(t, view1.columns_count == 3)
        testing.expect(t, ecs.view__len(&view1) == 0)
        testing.expect(t, view1.cap == 8)

        testing.expect(t, ecs.view__init(&view2, &ecs_1, {&ais, &positions}) == nil)
        testing.expect(t, view2.columns_count == 3)
        testing.expect(t, ecs.view__len(&view2) == 0)
        testing.expect(t, view2.cap == 8)

        testing.expect(t, ecs.view__init(&view3, &ecs_1, {&positions}) == nil)
        testing.expect(t, view3.id == 2)
        testing.expect(t, view3.columns_count == 2)
        testing.expect(t, ecs.view__len(&view3) == 0)
        testing.expect(t, view3.cap == 10)

        views_testing(t, &ecs_1, &ais, &positions, &view1, &view2, &view3, eid_1, eid_2, eid_3)

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

        eid_1, eid_2, eid_3 = create_entities_and_components(t, &ecs_1, &positions, &ais)

        ecs.resume(&view1)
        ecs.resume(&view2)
        ecs.resume(&view3)

        //
        // Retest if everything was suspended
        //

        testing.expect(t, view1.columns_count == 3)
        testing.expect(t, ecs.view__len(&view1) == 0)
        testing.expect(t, view1.cap == 8)

        testing.expect(t, view2.columns_count == 3)
        testing.expect(t, ecs.view__len(&view2) == 0)
        testing.expect(t, view2.cap == 8)

        testing.expect(t, view3.id == 2)
        testing.expect(t, view3.columns_count == 2)
        testing.expect(t, ecs.view__len(&view3) == 0)
        testing.expect(t, view3.cap == 10)

        views_testing(t, &ecs_1, &ais, &positions, &view1, &view2, &view3, eid_1, eid_2, eid_3)

        view1.state = ecs.Object_State.Terminated
        testing.expect(t, ecs.clear(&ecs_1) == ecs.API_Error.Object_Invalid)
        view1.state = ecs.Object_State.Normal

        // this removes view1 from db and ecs.clear()
        ecs.view_terminate(&view1)

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view1) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.iterator_next(&it) == false)

        testing.expect(t, ecs.view_clear(&view1) == ecs.API_Error.Object_Invalid)

        // because view1 is terminated, it is removed from db and dont cause clear() to fail
        testing.expect(t, ecs.clear(&ecs_1) == nil) 
    }


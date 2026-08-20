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
// Components

    Position :: struct {
        x, y: int
    }
    
    AI :: struct {
        IQ: f32,
        neurons_count: int
    }

///////////////////////////////////////////////////////////////////////////////
    when !ecs.SYNC_ENABLED {
        @(test)
        sync_register_disabled_by_default__test :: proc(t: ^testing.T) {
            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

            tbl: ecs.Table(Position)
            defer ecs.table_terminate(&tbl)
            testing.expect(t, ecs.table_init(&tbl, &db, 10) == nil)

            ch: ecs.Sync_Channel
            defer ecs.sync_channel_terminate(&ch)
            testing.expect(t, ecs.sync_channel_init(&ch, &db, 4) == nil)

            testing.expect(t, ecs.sync_register(&ch, &tbl) == ecs.API_Error.Sync_Feature_Disabled)
        }
    }

///////////////////////////////////////////////////////////////////////////////
    when !ecs.OBSERVERS_ENABLED {
        @(test)
        observer_init_disabled_by_default__test :: proc(t: ^testing.T) {
            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

            noop_callback :: proc(event: ^ecs.Observer_Event, user_data: rawptr) {}

            obs: ecs.Observer
            testing.expect(t, ecs.observer_init(&obs, &db, noop_callback) == ecs.API_Error.Observers_Feature_Disabled)
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Database

    @(test)
    attaching_detaching_tables__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
            
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

            testing.expect(t, ecs.table_init(&ais, &ecs_1, 10) == nil)
            testing.expect(t, ais.id == 0)

            testing.expect(t, ecs.table_init(&ais_table2, &ecs_1, 10) == nil)
            defer ecs.table_terminate(&positions)
            testing.expect(t, ecs.table_init(&positions, &ecs_1, 10) == nil)

            testing.expect(t, ais.id == 0)
            testing.expect(t, positions.id == 2)

            ecs.table_terminate(&ais_table2)

            testing.expect(t, ais_table2.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[1] == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)

            defer ecs.table_terminate(&pos_table2)
            testing.expect(t, ecs.table_init(&pos_table2, &ecs_1, 10) == nil)
            testing.expect(t, pos_table2.id == 1)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == false)

            ecs.table_terminate(&ais)

            testing.expect(t, ais.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[0] == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)
    }

    @(test)
    per_database_caps__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator, tables_cap = 3, views_cap = 2, tiny_tables_cap = 1) == nil)

        t1: ecs.Table(Position)
        defer ecs.table_terminate(&t1)
        t2: ecs.Table(AI)
        defer ecs.table_terminate(&t2)
        testing.expect(t, ecs.table_init(&t1, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t2, &db, 10) == nil)

        tt1: ecs.Tiny_Table(AI)
        defer ecs.tiny_table__terminate(&tt1)
        testing.expect(t, ecs.tiny_table__init(&tt1, &db) == nil)

        t3: ecs.Table(Position)
        defer ecs.table_terminate(&t3)
        testing.expect(t, ecs.table_init(&t3, &db, 10) == nil)
        testing.expect(t, db.tables.cap > 3, "tables array should have grown past its initial cap")

        tt2: ecs.Tiny_Table(AI)
        testing.expect(t, ecs.tiny_table__init(&tt2, &db) == oc.Core_Error.Container_Is_Full)

        v1: ecs.View
        defer ecs.view_terminate(&v1)
        v2: ecs.View
        defer ecs.view_terminate(&v2)
        testing.expect(t, ecs.view_init(&v1, &db, {&t1}) == nil)
        testing.expect(t, ecs.view_init(&v2, &db, {&t1}) == nil)

        v3: ecs.View
        defer ecs.view_terminate(&v3)
        testing.expect(t, ecs.view_init(&v3, &db, {&t1}) == nil)
        testing.expect(t, db.views.cap > 2, "views array should have grown past its initial cap")
    }

    @(test)
    database__arrays_grow_independently__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator, tables_cap = 2, views_cap = 2, tiny_tables_cap = 1) == nil)

        tables_cap_before := db.tables.cap
        views_cap_before := db.views.cap
        groups_cap_before := db.groups.cap
        testing.expect(t, tables_cap_before == 2)
        testing.expect(t, views_cap_before == 2)
        testing.expect(t, groups_cap_before == 2)

        t1: ecs.Table(Position)
        defer ecs.table_terminate(&t1)
        t2: ecs.Table(AI)
        defer ecs.table_terminate(&t2)
        t3: ecs.Table(Position)
        defer ecs.table_terminate(&t3)
        testing.expect(t, ecs.table_init(&t1, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t2, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t3, &db, 10) == nil)

        testing.expect(t, db.tables.cap > tables_cap_before, "tables should have grown")
        testing.expect(t, db.views.cap == views_cap_before, "views must not grow just because tables did")
        testing.expect(t, db.groups.cap == groups_cap_before, "groups must not grow just because tables did")

        v1: ecs.View
        defer ecs.view_terminate(&v1)
        v2: ecs.View
        defer ecs.view_terminate(&v2)
        v3: ecs.View
        defer ecs.view_terminate(&v3)
        testing.expect(t, ecs.view_init(&v1, &db, {&t1}) == nil)
        testing.expect(t, ecs.view_init(&v2, &db, {&t1}) == nil)
        testing.expect(t, ecs.view_init(&v3, &db, {&t1}) == nil)

        testing.expect(t, db.views.cap > views_cap_before, "views should have grown")
        testing.expect(t, db.groups.cap == groups_cap_before, "groups must still not have grown")

        t4: ecs.Table(AI)
        defer ecs.table_terminate(&t4)
        t5: ecs.Table(Position)
        defer ecs.table_terminate(&t5)
        testing.expect(t, ecs.table_init(&t4, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t5, &db, 10) == nil)

        g1: ecs.Group
        defer ecs.group_terminate(&g1)
        g2: ecs.Group
        defer ecs.group_terminate(&g2)
        g3: ecs.Group
        defer ecs.group_terminate(&g3)
        testing.expect(t, ecs.group_init(&g1, &db, {&t2}) == nil)
        testing.expect(t, ecs.group_init(&g2, &db, {&t4}) == nil)
        testing.expect(t, ecs.group_init(&g3, &db, {&t5}) == nil)

        testing.expect(t, db.groups.cap > groups_cap_before, "groups should have grown")
    }

    @(test)
    database__tables_growth_clamps_at_id_ceiling__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator, tables_cap = 2, views_cap = 2, tiny_tables_cap = 1) == nil)

        table_id_cap :: ecs.BIT_SET_VALUES_CAP * ecs.TABLES_MULT
        tags: [table_id_cap]ecs.Tag_Table
        defer for &tag in tags do ecs.tag_table__terminate(&tag)
        for i in 0..<table_id_cap {
            testing.expect(t, ecs.tag_table__init(&tags[i], &db, 10) == nil)
        }
        testing.expect(t, db.tables.cap == table_id_cap, "tables must have grown exactly up to, and no further than, the true table-id ceiling")

        one_too_many: ecs.Tag_Table
        testing.expect(t, ecs.tag_table__init(&one_too_many, &db, 10) == oc.Core_Error.Container_Is_Full)
    }

    @(test)
    view_init_subscriber_cap_rollback__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        t1: ecs.Tiny_Table(Position)
        defer ecs.tiny_table__terminate(&t1)
        testing.expect(t, ecs.tiny_table__init(&t1, &db) == nil)

        views: [ecs.TINY_TABLE__VIEWS_CAP]ecs.View
        defer for &v in views do ecs.view_terminate(&v)
        for &v in views {
            testing.expect(t, ecs.view_init(&v, &db, {&t1}) == nil)
        }

        views_before := oc.sparse_arr__len(&db.views)

        v_extra: ecs.View
        testing.expect(t, ecs.view_init(&v_extra, &db, {&t1}) == oc.Core_Error.Container_Is_Full)
        testing.expect(t, ecs.is_valid(&v_extra) == false)
        testing.expect(t, v_extra.state == ecs.Object_State.Not_Initialized)
        testing.expect(t, oc.sparse_arr__len(&db.views) == views_before, "failed view must not remain attached to the database")

        eid, eerr := ecs.create_entity(&db)
        testing.expect(t, eerr == nil)
        _, aerr := ecs.add_component(&t1, eid)
        testing.expect(t, aerr == nil)
        testing.expect(t, ecs.view_len(&views[0]) == 1)
    }

    @(test)
    terminate_then_reinit__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            is_alive: ecs.Tag_Table
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            run_cycle :: proc(t: ^testing.T, db: ^ecs.Database, positions: ^ecs.Table(Position), is_alive: ^ecs.Tag_Table, view: ^ecs.View, allocator: mem.Allocator) {
                testing.expect(t, ecs.init(db, entities_cap=100, allocator=allocator) == nil)
                testing.expect(t, ecs.table_init(positions, db, 100) == nil)
                testing.expect(t, ecs.tag_table__init(is_alive, db, 100) == nil)
                testing.expect(t, ecs.view_init(view, db, {positions, is_alive}) == nil)

                eid, err := ecs.create_entity(db)
                testing.expect(t, err == nil)

                pos, perr := ecs.add_component(positions, eid)
                testing.expect(t, perr == nil)
                testing.expect(t, pos != nil)
                if pos != nil do pos^ = Position{ x = 1, y = 2 }

                testing.expect(t, ecs.add_tag(is_alive, eid) == nil)

                testing.expect(t, ecs.table_len(positions) == 1)
                testing.expect(t, ecs.view_len(view) == 1)
            }

            run_cycle(t, &db, &positions, &is_alive, &view, allocator)

            testing.expect(t, ecs.terminate(&db) == nil)

            testing.expect(t, db.state == ecs.Object_State.Not_Initialized)
            testing.expect(t, positions.state == ecs.Object_State.Not_Initialized)
            testing.expect(t, is_alive.state == ecs.Object_State.Not_Initialized)
            testing.expect(t, view.state == ecs.Object_State.Not_Initialized)

            run_cycle(t, &db, &positions, &is_alive, &view, allocator)
    }

    @(test)
    attaching_detaching_views__test :: proc(t: ^testing.T) {
        //
        // Prepare
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
            
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

            defer ecs.table_terminate(&ais)
            testing.expect(t, ecs.table_init(&ais, &ecs_1, 10) == nil)
            
            defer ecs.table_terminate(&positions)
            testing.expect(t, ecs.table_init(&positions, &ecs_1, 10) == nil)

            testing.expect(t, ecs.table__is_valid(&ais))
            testing.expect(t, ecs.table__is_valid(&positions))
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
    creating_destroying_entities__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
            
            ecs_1: ecs.Database

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=2, allocator=allocator) == nil)

            testing.expect(t,  ecs_1.overbase.id_factory.created_count == 0)

            eid_1, eid_2, eid_3: ecs.entity_id
            err: ecs.Error

        //
        // Test
        //

            eid_1, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_1.ix == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 1)

            eid_2, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_2.ix == 1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 2)

            eid_3, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_3.ix == ecs.DELETED_INDEX)
            testing.expect(t, err == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 2)

            testing.expect(t, ecs.database__destroy_entity(&ecs_1, eid_1) == nil)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 2)

            testing.expect(t, ecs.database__destroy_entity(&ecs_1, eid_1) == ecs.API_Error.Entity_Id_Expired)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 2)
    }
///////////////////////////////////////////////////////////////////////////////
// Table

    @(test)
    adding_removing_components__test :: proc(t: ^testing.T) {
        //
        // Prepare
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
            
            ecs_1: ecs.Database
            ais: ecs.Table(AI)
            ais_2: ecs.Table(AI)
            positions: ecs.Table(Position)

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            defer ecs.table_terminate(&ais)
            testing.expect(t, ecs.table_init(&ais, &ecs_1, 10) == nil)
            testing.expect(t, ecs.table_cap(&ais) == 10)

            defer ecs.table_terminate(&positions)
            testing.expect(t, ecs.table_init(&positions, &ecs_1, 10) == nil)
            testing.expect(t, ecs.table_cap(&positions) == 10)

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
            testing.expect(t, ecs.table_len(&positions) == 1)

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

            testing.expect(t, positions.eid_to_rid[eid_1.ix] == 0)
            testing.expect(t, positions.eid_to_rid[eid_2.ix] == 1)
            testing.expect(t, positions.rid_to_eid[0] == eid_1)
            testing.expect(t, positions.rid_to_eid[1] == eid_2)
            testing.expect(t, ecs.table_len(&positions) == 2)

            testing.expect(t, ecs.remove_component(&positions, eid_1) == nil)

            testing.expect(t, pos.x == 55)
            testing.expect(t, pos.y == 88)
            
            testing.expect(t, pos2.x == 0)
            testing.expect(t, pos2.y == 0)

            testing.expect(t, positions.eid_to_rid[eid_1.ix] == max(u32))
            testing.expect(t, positions.eid_to_rid[eid_2.ix] == 0)
            testing.expect(t, positions.rid_to_eid[0] == eid_2)
            testing.expect(t, positions.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.table_len(&positions) == 1)

            testing.expect(t, ecs.remove_component(&positions, eid_1) == oc.Core_Error.Not_Found)
            testing.expect(t, ecs.remove_component(&positions, eid_2) == nil)

            testing.expect(t, positions.eid_to_rid[eid_1.ix] == max(u32))
            testing.expect(t, positions.eid_to_rid[eid_2.ix] == max(u32))
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
            
            a = ecs.get_component(&ais, eid_2)
            testing.expect(t, a == ai2)

            a.neurons_count = 222

            pos = ecs.get_component(&positions, eid_2)
            testing.expect(t, pos == nil)

            //
            // Copy component 
            //

            defer ecs.table_terminate(&ais_2)
            testing.expect(t, ecs.table_init(&ais_2, &ecs_1, 10) == nil)

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

        // FORCE CAP = 2
        old_cap := view1.cap
        view1.cap = 2

        // ADD POS
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

        // RESTORE CAP
        view1.cap = old_cap

        // ADD POS
        before_error_add_len := ecs.view_len(view1)
        pos, err = ecs.add_component(positions, eid_2)
        pos.x = 222
        testing.expect(t,  err == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, ecs.view_len(view1) == before_error_add_len + 1)

        // view1

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

        // view3

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

    create_entities_and_components :: proc (
        t: ^testing.T, 
        ecs_1: ^ecs.Database, 
        positions: ^ecs.Table(Position), 
        ais: ^ecs.Table(AI)
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
    views_subscribing_for_updates__test :: proc(t: ^testing.T) {
        //
        // Prepare
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
            
            ecs_1: ecs.Database
            ais: ecs.Table(AI)
            positions: ecs.Table(Position)
            view1: ecs.View
            view2: ecs.View
            view3: ecs.View
            err: ecs.Error

            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&ais, &ecs_1, 8) == nil)
            testing.expect(t, ecs.table_init(&positions, &ecs_1, 10) == nil)

        //
        // Test
        //

        eid_1, eid_2, eid_3: ecs.entity_id
        pos: ^Position
        ai: ^AI

        eid_1, eid_2, eid_3 = create_entities_and_components(t, &ecs_1, &positions, &ais)

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

        views_testing(t, &ecs_1, &ais, &positions, &view1, &view2, &view3, eid_1, eid_2, eid_3)

        testing.expect(t, view1.cap == 8)

        testing.expect(t, ecs.clear(&ecs_1) == nil)

        //
        // Repeat after clear to see if everything fine again
        //

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

        testing.expect(t, ecs.view_len(&view1) == 0)
        testing.expect(t, view1.cap == 8)

        testing.expect(t, ecs.view_len(&view2) == 0)
        testing.expect(t, view2.cap == 8)

        testing.expect(t, view3.id == 2)
        testing.expect(t, ecs.view_len(&view3) == 0)
        testing.expect(t, view3.cap == 10)

        views_testing(t, &ecs_1, &ais, &positions, &view1, &view2, &view3, eid_1, eid_2, eid_3)

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
    views_iterator_range__test :: proc(t: ^testing.T) {

        //
        // Prepare
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

        db: ecs.Database
        table: ecs.Table(Position)
        view: ecs.View
        eid: ecs.entity_id
        err: ecs.Error
        pos: ^Position
        i: int

        ENTITIES_CAP :: 10
        
        defer ecs.terminate(&db)
        err = ecs.init(&db, ENTITIES_CAP, allocator)
        testing.expect(t, err == nil)

        err = ecs.table_init(&table, &db, ENTITIES_CAP)
        testing.expect(t, err == nil)

        err = ecs.view_init(&view, &db, {&table})
        testing.expect(t, err == nil)

        for i := 0; i < ENTITIES_CAP; i+=1 {
            eid, err = ecs.create_entity(&db)
            testing.expect(t, err == nil)

            pos, err = ecs.add_component(&table, eid)
            testing.expect(t, err == nil)
        }

        testing.expect(t, ecs.view_len(&view) == ENTITIES_CAP)

        //
        // Test view ranges
        //

        it: ecs.Iterator
        ecs.iterator_init(&it, &view)

        for i=0; ecs.iterator_next(&it); i+=1 {
            testing.expect(t, ecs.get_component(&table, &it) == &table.rows[i])
        }

        testing.expect(t, i == ENTITIES_CAP)

        start_row : int = 0
        end_row : int = 5
        ecs.iterator_init(&it, &view, start_row, end_row)
        for i=start_row; ecs.iterator_next(&it); i+=1 {
            testing.expect(t, ecs.get_component(&table, &it) == &table.rows[i])
        }

        start_row = 4
        end_row = ENTITIES_CAP
        ecs.iterator_init(&it, &view, start_row, end_row)
        for i=start_row; ecs.iterator_next(&it); i+=1 {
            testing.expect(t, ecs.get_component(&table, &it) == &table.rows[i])
        }

        start_row = 3
        end_row = 8
        ecs.iterator_init(&it, &view, start_row, end_row)
        for i=start_row; ecs.iterator_next(&it); i+=1 {
            testing.expect(t, ecs.get_component(&table, &it) == &table.rows[i])
        }

    }

    @(test)
    table__filter__test :: proc(t: ^testing.T) {
        //
        // Prepare
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

            movement_table : ecs.Table(Movement)

            err = ecs.table__init(&movement_table, &db, 10)
            testing.expect(t, err == nil)

            movement: ^Movement

            // Add Movement component for human and bird            
            movement, err = ecs.table__add_component(&movement_table, human)
            testing.expect(t, err == nil) 

            movement.speed = 5.0
            movement.direction = 180.0  
            movement.state = Character_State.Walking

            movement, err = ecs.table__add_component(&movement_table, bird)
            testing.expect(t, err == nil)

            movement.speed = 20.0
            movement.direction = 90.0
            movement.state = Character_State.Flying

            movement, err = ecs.table__add_component(&movement_table, chair)
            testing.expect(t, err == nil)

            movement.speed = 0.0
            movement.direction = 0.0    
            movement.state = Character_State.Idle

            Movement_User_Data :: struct {
                movement_table: ^ecs.Table(Movement),
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
            testing.expect(t, movement_table.type == ecs.Table_Type.Table)
            testing.expect(t, oc.dense_arr__len(&movement_table.subscribers_with_filter) == 1)

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

            movement = ecs.table__get_component_by_entity(&movement_table, human)
            movement.state = Character_State.Idle

            movement = ecs.table__get_component_by_entity(&movement_table, chair)
            movement.state = Character_State.Sliding

            // Reset
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

            ecs.table__rerun_views_filters(&movement_table, chair)

            // Reset
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
// Regression tests (2026-07 bug audit)

    @(test)
    database_clear_expires_old_ids__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

        old_eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.clear(&db) == nil)
        testing.expect(t, ecs.entities_len(&db) == 0)
        testing.expect(t, ecs.is_expired(&db, old_eid))

        new_eid, err2 := ecs.create_entity(&db)
        testing.expect(t, err2 == nil)
        testing.expect(t, new_eid.ix == old_eid.ix)
        testing.expect(t, new_eid != old_eid)
        testing.expect(t, ecs.is_expired(&db, old_eid))
    }

    @(test)
    table_terminate_view_cleanup__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        defer mem.tracking_allocator_destroy(&track)
        allocator := mem.tracking_allocator(&track)
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        ais: ecs.Table(AI)
        ais2: ecs.Table(AI)
        view: ecs.View
        view2: ecs.View

        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions, &ais}) == nil)
        testing.expect(t, ecs.view_init(&view2, &db, {&positions, &ais}) == nil)

        eid, cerr := ecs.create_entity(&db)
        testing.expect(t, cerr == nil)

        _, err := ecs.add_component(&positions, eid)
        testing.expect(t, err == nil)
        _, err = ecs.add_component(&ais, eid)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.view_len(&view) == 1)

        testing.expect(t, ecs.table_terminate(&ais) == nil)
        testing.expect(t, view.state == ecs.Object_State.Invalid)
        testing.expect(t, view2.state == ecs.Object_State.Invalid)

        testing.expect(t, ecs.table_init(&ais2, &db, 10) == nil)
        testing.expect(t, ais2.id == 1)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
        testing.expect(t, ecs.entities_len(&db) == 0)

        testing.expect(t, ecs.view_terminate(&view) == nil)

        testing.expect(t, ecs.terminate(&db) == nil)

        testing.expect(t, len(track.allocation_map) == 0)
        testing.expect(t, len(track.bad_free_array) == 0)
    }

    @(test)
    add_component_at_cap_already_exists__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 2) == nil)

        e1, err1 := ecs.create_entity(&db)
        testing.expect(t, err1 == nil)
        e2, err2 := ecs.create_entity(&db)
        testing.expect(t, err2 == nil)
        e3, err3 := ecs.create_entity(&db)
        testing.expect(t, err3 == nil)

        _, err := ecs.add_component(&positions, e1)
        testing.expect(t, err == nil)
        _, err = ecs.add_component(&positions, e2)
        testing.expect(t, err == nil)

        p: ^Position
        p, err = ecs.add_component(&positions, e1)
        testing.expect(t, err == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, p != nil)

        p, err = ecs.add_component(&positions, e3)
        testing.expect(t, err == oc.Core_Error.Container_Is_Full)
        testing.expect(t, p == nil)
    }

    @(test)
    table_expired_entity_id__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

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
    table_pause_resume_edge_cases__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        _, aerr := ecs.add_component(&positions, eid)
        testing.expect(t, aerr == nil)

        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, ecs.resume_packing(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 1)
        testing.expect(t, ecs.has_component(&positions, eid))

        testing.expect(t, ecs.table_terminate(&positions) == nil)
        testing.expect(t, ecs.pause_packing(&positions) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.resume_packing(&positions) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.pack(&positions) == ecs.API_Error.Object_Invalid)
    }

    @(test)
    database_clear_with_invalid_view__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        ais: ecs.Table(AI)
        view: ecs.View

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&ais}) == nil)

        eid, cerr := ecs.create_entity(&db)
        testing.expect(t, cerr == nil)
        _, err := ecs.add_component(&positions, eid)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.table_terminate(&ais) == nil)
        testing.expect(t, view.state == ecs.Object_State.Invalid)

        testing.expect(t, ecs.clear(&db) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.entities_len(&db) == 0)
        testing.expect(t, ecs.table_len(&positions) == 0)
        testing.expect(t, ecs.is_expired(&db, eid))
    }

    @(test)
    destroy_entity_high_table_id__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        tags: [68]ecs.Tag_Table
        positions: ecs.Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

        for i in 0..<68 {
            testing.expect(t, ecs.tag_table__init(&tags[i], &db, 10) == nil)
        }
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, int(positions.id) == 68)

        eid, cerr := ecs.create_entity(&db)
        testing.expect(t, cerr == nil)
        _, aerr := ecs.add_component(&positions, eid)
        testing.expect(t, aerr == nil)
        testing.expect(t, ecs.add_tag(&tags[0], eid) == nil)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
        testing.expect(t, ecs.entities_len(&db) == 0)
        testing.expect(t, ecs.table_len(&positions) == 0)
        testing.expect(t, ecs.table_len(&tags[0]) == 0)
        testing.expect(t, ecs.has_component(&positions, eid) == false)
    }

///////////////////////////////////////////////////////////////////////////////
// Deferred tail swap (pause_packing / resume_packing / pack)

    @(test)
    pause_packing__table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        view: ecs.View

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
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
    pause_packing__standalone_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

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
    pause_packing__database__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        ais: ecs.Compact_Table(AI)
        tiny_positions: ecs.Tiny_Table(Position)
        marked: ecs.Tag_Table
        view: ecs.View

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.compact_table__init(&ais, &db, 10) == nil)
        testing.expect(t, ecs.tiny_table__init(&tiny_positions, &db) == nil)
        testing.expect(t, ecs.tag_table__init(&marked, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions, &ais}) == nil)

        eids: [6]ecs.entity_id
        for i in 0..<6 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)

            p, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)
            p.x = i

            a, aerr := ecs.add_component(&ais, eid)
            testing.expect(t, aerr == nil)
            a.neurons_count = i * 10

            tp, terr := ecs.add_component(&tiny_positions, eid)
            testing.expect(t, terr == nil)
            tp.y = i

            testing.expect(t, ecs.add_tag(&marked, eid) == nil)

            eids[i] = eid
        }

        testing.expect(t, ecs.view_len(&view) == 6)

        ecs.pause_packing(&db)

        destroyed := 0
        for i in 0..<ecs.table_len(&positions) {
            eid := ecs.get_entity(&positions, i)
            if eid.ix == ecs.DELETED_INDEX do continue
            if i % 2 == 0 {
                testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
                destroyed += 1
            }
        }
        testing.expect(t, destroyed == 3)

        testing.expect(t, positions.holes_count == 3)
        testing.expect(t, ais.holes_count == 3)
        testing.expect(t, tiny_positions.holes_count == 3)
        testing.expect(t, ecs.view_len(&view) == 3)
        testing.expect(t, marked.holes_count == 3)
        testing.expect(t, ecs.table_len(&marked) == 6)

        testing.expect(t, ecs.rebuild(&view) == nil)
        testing.expect(t, ecs.view_len(&view) == 3)

        testing.expect(t, ecs.resume_packing(&db) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ais.holes_count == 0)
        testing.expect(t, tiny_positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 3)
        testing.expect(t, ecs.table_len(&ais) == 3)
        testing.expect(t, ecs.table_len(&tiny_positions) == 3)
        testing.expect(t, marked.holes_count == 0)
        testing.expect(t, ecs.table_len(&marked) == 3)
        testing.expect(t, ecs.entities_len(&db) == 3)

        for i in 0..<6 {
            if i % 2 == 0 do continue
            eid := eids[i]

            p := ecs.get_component(&positions, eid)
            testing.expect(t, p != nil && p.x == i)

            a := ecs.get_component(&ais, eid)
            testing.expect(t, a != nil && a.neurons_count == i * 10)

            tp := ecs.get_component(&tiny_positions, eid)
            testing.expect(t, tp != nil && tp.y == i)
        }

        testing.expect(t, ecs.remove_component(&positions, eids[1]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 2)
    }

    @(test)
    pause_packing__dense_view__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        view: ecs.View

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        eids: [4]ecs.entity_id
        for i in 0..<4 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            p, aerr := ecs.add_component(&positions, eid)
            testing.expect(t, aerr == nil)
            p.x = i
            eids[i] = eid
        }

        pos_cid := view.tid_to_cid[positions.id]
        it: ecs.Iterator

        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        testing.expect(t, view.dense_cols[pos_cid] == ecs.View_Dense_State.Aligned)
        testing.expect(t, ecs.view_len(&view) == 4)

        ecs.pause_packing(&db)
        testing.expect(t, ecs.remove_component(&positions, eids[1]) == nil)

        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        testing.expect(t, view.dense_cols[pos_cid] == ecs.View_Dense_State.Misaligned)

        testing.expect(t, ecs.resume_packing(&db) == nil)

        testing.expect(t, ecs.rebuild(&view) == nil)
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        testing.expect(t, view.dense_cols[pos_cid] == ecs.View_Dense_State.Aligned)
        testing.expect(t, ecs.view_len(&view) == 3)
        for ecs.iterator_next(&it) {
            eid := ecs.get_entity(&it)
            row := ecs.get_component(&positions, &it)
            testing.expect(t, ecs.get_component(&positions, eid).x == row.x)
        }
    }


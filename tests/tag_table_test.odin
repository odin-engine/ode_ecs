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
    import oc_maps "../ode_core/maps"


///////////////////////////////////////////////////////////////////////////////
// Tag_Table

    @(test)
    tag_table__view_test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            // Log into console when panic happens
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
        //
        // Test
        //
            db: ecs.Database
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=0, allocator=allocator) == ecs.API_Error.Entities_Cap_Should_Be_Greater_Than_Zero)
            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

            is_alive_table : ecs.Tag_Table

            testing.expect(t, ecs.tag_table__init(&is_alive_table, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__len(&is_alive_table) == 0)
            testing.expect(t, ecs.tag_table__cap(&is_alive_table) == 10)

            view : ecs.View

            testing.expect(t, ecs.tag_table__is_valid(&is_alive_table))
            testing.expect(t, ecs.view_init(&view, &db, {&is_alive_table}) == nil)

            err : ecs.Error
            human, bird, chair : ecs.entity_id

            human, err = ecs.create_entity(&db)
            testing.expect(t, err == nil)

            bird, err = ecs.create_entity(&db)
            testing.expect(t, err == nil)

            chair, err = ecs.create_entity(&db)
            testing.expect(t, err == nil)

            ecs.tag(&is_alive_table, human)

            testing.expect(t, ecs.tag_table__len(&is_alive_table) == 1)
            testing.expect(t, ecs.tag_table__cap(&is_alive_table) == 10)

            ecs.tag(&is_alive_table, bird)

            testing.expect(t, ecs.tag_table__len(&is_alive_table) == 2)
            testing.expect(t, ecs.tag_table__cap(&is_alive_table) == 10)

            it: ecs.Iterator
            err = ecs.iterator_init(&it, &view)
            testing.expect(t, err == nil)

            eid : ecs.entity_id
            is_human_alive := false
            is_bird_alive := false
            is_chair_alive := false

            for ecs.iterator_next(&it) {
                eid = ecs.get_entity(&it)

                if eid == human do is_human_alive = true
                if eid == bird do is_bird_alive = true 
                if eid == chair do is_chair_alive = true

                //fmt.println(eid)
            }

            testing.expect(t, is_human_alive)
            testing.expect(t, is_bird_alive)
            testing.expect(t, !is_chair_alive)

            ecs.suspend(&view)

            ecs.add_tag(&is_alive_table, chair)

            testing.expect(t, ecs.tag_table__len(&is_alive_table) == 3)
            testing.expect(t, ecs.tag_table__cap(&is_alive_table) == 10)

            //fmt.println(is_alive_table.eid_map)

            ecs.resume(&view)

            ecs.rebuild(&view)

            ecs.iterator_reset(&it)

            is_human_alive = false
            is_bird_alive = false  
            is_chair_alive = false

            for ecs.iterator_next(&it) {
                eid = ecs.get_entity(&it)

                if eid == human do is_human_alive = true
                if eid == bird do is_bird_alive = true 
                if eid == chair do is_chair_alive = true
            }

            testing.expect(t, is_human_alive)
            testing.expect(t, is_bird_alive)
            testing.expect(t, is_chair_alive)

            ecs.untag(&is_alive_table, human)
            ecs.untag(&is_alive_table, chair)

            ecs.iterator_reset(&it)

            is_human_alive = false
            is_bird_alive = false  
            is_chair_alive = false

            for ecs.iterator_next(&it) {
                eid = ecs.get_entity(&it)

                if eid == human do is_human_alive = true
                if eid == bird do is_bird_alive = true 
                if eid == chair do is_chair_alive = true
            }

            testing.expect(t, !is_human_alive)
            testing.expect(t, is_bird_alive)
            testing.expect(t, !is_chair_alive)

            testing.expect(t, ecs.tag_table__len(&is_alive_table) == 1)
            testing.expect(t, ecs.tag_table__cap(&is_alive_table) == 10)

        //
        // View filter example without using user_data
        //
            view2: ecs.View

            my_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil)->bool {
                eid := ecs.get_entity(row)

                // 0 is human, 1 is bird, 2 is chair
                if eid.ix == 0 || eid.ix == 2 do return true 

                return false
            }

            testing.expect(t, ecs.view_init(&view2, &db, {&is_alive_table}, my_filter) == nil)

            ecs.rebuild(&view2)

            ecs.add_tag(&is_alive_table, human)
            ecs.add_tag(&is_alive_table, chair)

            testing.expect(t, ecs.iterator_init(&it, &view2) == nil)

            is_human_alive = false
            is_bird_alive = false  
            is_chair_alive = false

            for ecs.iterator_next(&it) {
                eid = ecs.get_entity(&it)

                if eid == human do is_human_alive = true
                if eid == bird do is_bird_alive = true 
                if eid == chair do is_chair_alive = true
            }

            testing.expect(t, is_human_alive)
            testing.expect(t, !is_bird_alive)
            testing.expect(t, is_chair_alive)

        //
        // View filter example with user data
        //
            view3: ecs.View

            My_User_Data :: struct {
                human_eid: ecs.entity_id,
                chair_eid: ecs.entity_id,
            }

            my_filter2 :: proc(row: ^ecs.View_Row, user_data: rawptr = nil)->bool {

                if user_data == nil do return false

                eid := ecs.get_entity(row)
                data := (^My_User_Data)(user_data)

                // using entities saved in user data
                if eid == data.human_eid || eid == data.chair_eid do return true 

                return false
            }

            my_user_data := My_User_Data{
                human_eid = human,
                chair_eid = chair,
            }

            view3.user_data = &my_user_data   // set user_data !!!

            testing.expect(t, ecs.view_init(&view3, &db, {&is_alive_table}, my_filter2) == nil)

            ecs.rebuild(&view3)

            it3: ecs.Iterator

            testing.expect(t, ecs.iterator_init(&it3, &view3) == nil)

            is_human_alive = false
            is_bird_alive = false  
            is_chair_alive = false

            for ecs.iterator_next(&it3) {
                eid = ecs.get_entity(&it3)

                if eid == human do is_human_alive = true
                if eid == bird do is_bird_alive = true 
                if eid == chair do is_chair_alive = true
            }

            testing.expect(t, is_human_alive)
            testing.expect(t, !is_bird_alive)
            testing.expect(t, is_chair_alive)
    }

///////////////////////////////////////////////////////////////////////////////
// Deferred tail swap (pause_tail_swap / resume_tail_swap / pack)

    // While paused, untagging leaves holes and moves nothing; pack compacts them.
    @(test)
    tag_table__pause_tail_swap__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        is_alive: ecs.Tag_Table
        view: ecs.View

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.tag_table__init(&is_alive, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&is_alive}) == nil)

        eids: [5]ecs.entity_id
        for i in 0..<5 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            testing.expect(t, ecs.add_tag(&is_alive, eid) == nil)
            eids[i] = eid
        }

        testing.expect(t, ecs.tag_table__len(&is_alive) == 5)
        testing.expect(t, ecs.view_len(&view) == 5)

        ecs.pause_tail_swap(&db)

        // removing a middle entity leaves a hole, nothing moves
        testing.expect(t, ecs.untag(&is_alive, eids[2]) == nil)
        testing.expect(t, ecs.tag_table__len(&is_alive) == 4)
        testing.expect(t, is_alive.holes_count == 1)
        testing.expect(t, ecs.get_entity(&is_alive, 2).ix == ecs.DELETED_INDEX) // hole marker
        testing.expect(t, ecs.get_entity(&is_alive, 1) == eids[1]) // stable (tail swap would have moved it)
        testing.expect(t, ecs.view_len(&view) == 4) // views are still notified

        // removing the tail row shrinks the span without leaving a hole
        testing.expect(t, ecs.untag(&is_alive, eids[4]) == nil)
        testing.expect(t, is_alive.holes_count == 1)

        // removing the new tail absorbs the trailing hole at row 2 as well
        testing.expect(t, ecs.untag(&is_alive, eids[3]) == nil)
        testing.expect(t, is_alive.holes_count == 0)

        // punch a hole and pack explicitly (pack is usable mid-pause)
        testing.expect(t, ecs.untag(&is_alive, eids[0]) == nil)
        testing.expect(t, is_alive.holes_count == 1)

        testing.expect(t, ecs.pack(&is_alive) == nil)
        testing.expect(t, is_alive.holes_count == 0)
        testing.expect(t, ecs.tag_table__len(&is_alive) == 1)
        testing.expect(t, ecs.get_entity(&is_alive, 0) == eids[1]) // survivor moved into the hole
        testing.expect(t, ecs.view_len(&view) == 1)

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        for ecs.iterator_next(&it) {
            testing.expect(t, ecs.get_entity(&it) == eids[1])
        }

        // normal tail-swap removal works after resume
        testing.expect(t, ecs.resume_tail_swap(&db) == nil)
        testing.expect(t, ecs.untag(&is_alive, eids[1]) == nil)
        testing.expect(t, ecs.tag_table__len(&is_alive) == 0)
    }


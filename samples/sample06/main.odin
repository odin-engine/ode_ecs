/*
    2025 (c) Oleh, https://github.com/zm69

    Tag_Table and View filter example.
*/

package ode_ecs_sample5

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:log"
    import "core:slice"
    import "core:mem"
    import "core:math"
    import "core:math/rand"
    import "core:time"
    import "core:testing"
     
// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// This example includes simple error handling.
//
main :: proc() {

    //
    // OPTIONAL: Setup memory tracking and logger. 
    //
        mem_track: oc.Mem_Track

        // Track memory leaks and bad frees
        context.allocator = oc.mem_track__init(&mem_track, context.allocator)  
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track) // Defer statements are executed in the reverse order that they were declared

        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        // Replace default allocator with panic allocator to make sure that  
        // no allocations happen outside of provided allocator
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

    //
    // Actual ODE_ECS sample starts here.
    //
        // Simple error handling
        err: ecs.Error
    
        // Database
        db : ecs.Database

       // Init database
        defer { 
            err = ecs.terminate(&db) 
            if err != nil do report_error(err)
        }

        err = ecs.database__init(&db, 10, allocator)
        if err != nil { report_error(err); return }
    
    //
    // Tag_Table example
    //
        is_alive_table : ecs.Tag_Table

        err = ecs.tag_table__init(&is_alive_table, &db, 10)
        if err != nil { report_error(err); return }

        view : ecs.View

        err = ecs.view_init(&view, &db, {&is_alive_table})
        if err != nil { report_error(err); return }

        human, bird, chair : ecs.entity_id

        human, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        bird, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        chair, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        err = ecs.add_tag(&is_alive_table, human)
        if err != nil { report_error(err); return }

        err = ecs.add_tag(&is_alive_table, bird)
        if err != nil { report_error(err); return }

        // iterate over entities tagged in is_alive_table
        fmt.println("Tagged entities:")
        for eid in is_alive_table.rows {
            fmt.println("Entity tagged in `is_alive_table`:", eid)
        }

        it: ecs.Iterator
        err = ecs.iterator_init(&it, &view)
        if err != nil { report_error(err); return }

        eid : ecs.entity_id
        is_human_alive := false
        is_bird_alive := false
        is_chair_alive := false

        for ecs.iterator_next(&it) {
            eid = ecs.get_entity(&it)

            if eid == human do is_human_alive = true
            if eid == bird do is_bird_alive = true 
            if eid == chair do is_chair_alive = true
        }

        fmt.println()
        fmt.println("Only entities tagged in `is_alive_table` should be alive:")
        fmt.println("Is human alive:",  is_human_alive)
        fmt.println("Is bird alive:",  is_bird_alive)
        fmt.println("Is chair alive:", is_chair_alive)

        // Remove some tags
        ecs.remove_tag(&is_alive_table, human)
        ecs.remove_tag(&is_alive_table, chair)

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

        fmt.println()
        fmt.println("Only entities tagged in `is_alive_table` should be alive:")
        fmt.println("Is human alive:",  is_human_alive)
        fmt.println("Is bird alive:",  is_bird_alive)
        fmt.println("Is chair alive:", is_chair_alive)

    //
    // View filter example 
    //
        view2: ecs.View

        my_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil)->bool {
            eid := ecs.get_entity(row)

            // 0 is human, 1 is bird, 2 is chair
            if eid.ix == 0 || eid.ix == 2 do return true 

            return false
        }

        err = ecs.view_init(&view2, &db, {&is_alive_table}, my_filter)
         if err != nil { report_error(err); return }

        ecs.rebuild(&view2)

        ecs.add_tag(&is_alive_table, human)
        ecs.add_tag(&is_alive_table, chair)

        err = ecs.iterator_init(&it, &view2)
        if err != nil { report_error(err); return }

        is_human_alive = false
        is_bird_alive = false  
        is_chair_alive = false

        for ecs.iterator_next(&it) {
            eid = ecs.get_entity(&it)

            if eid == human do is_human_alive = true
            if eid == bird do is_bird_alive = true 
            if eid == chair do is_chair_alive = true
        }

        fmt.println()
        fmt.println("View filter example:")
        fmt.println("Is human alive:",  is_human_alive)
        fmt.println("Is bird alive:",  is_bird_alive)
        fmt.println("Is chair alive:", is_chair_alive)

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

        view3.user_data = &my_user_data

        err = ecs.view_init(&view3, &db, {&is_alive_table}, my_filter2)
         if err != nil { report_error(err); return }

        ecs.rebuild(&view3)

        it3: ecs.Iterator

        err = ecs.iterator_init(&it3, &view3)
        if err != nil { report_error(err); return }

        is_human_alive = false
        is_bird_alive = false  
        is_chair_alive = false

        for ecs.iterator_next(&it3) {
            eid = ecs.get_entity(&it3)

            if eid == human do is_human_alive = true
            if eid == bird do is_bird_alive = true 
            if eid == chair do is_chair_alive = true
        }

        fmt.println()
        fmt.println("View filter example with user data:")
        fmt.println("Is human alive:",  is_human_alive)
        fmt.println("Is bird alive:",  is_bird_alive)
        fmt.println("Is chair alive:", is_chair_alive)
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}




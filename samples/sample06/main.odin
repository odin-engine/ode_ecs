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
    
    ///////////////////////////////////////////////////////////////////////////////
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

        err = ecs.tag(&is_alive_table, human)
        if err != nil { report_error(err); return }

        err = ecs.tag(&is_alive_table, bird)
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

        fmt.println()
        fmt.println("Only entities tagged in `is_alive_table` should be alive:")
        fmt.println("Is human alive:",  is_human_alive)
        fmt.println("Is bird alive:",  is_bird_alive)
        fmt.println("Is chair alive:", is_chair_alive)

    ///////////////////////////////////////////////////////////////////////////////
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

    ///////////////////////////////////////////////////////////////////////////////
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

    ///////////////////////////////////////////////////////////////////////////////
    // View filter example with rerunning filters for entities
    //

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

        movement_table : ecs.Tiny_Table(Movement) // you can use Table or Compact_Table as well

        err = ecs.tiny_table__init(&movement_table, &db)
        if err != nil { report_error(err); return } 

        movement: ^Movement // component

        // Add Movement component for human and bird            
        movement, err = ecs.tiny_table__add_component(&movement_table, human)
        if err != nil { report_error(err); return } 

        movement.speed = 5.0
        movement.direction = 180.0  
        movement.state = Character_State.Walking

        movement, err = ecs.tiny_table__add_component(&movement_table, bird)
        if err != nil { report_error(err); return }

        movement.speed = 20.0
        movement.direction = 90.0
        movement.state = Character_State.Flying

        movement, err = ecs.tiny_table__add_component(&movement_table, chair)
        if err != nil { report_error(err); return }

        movement.speed = 0.0
        movement.direction = 0.0    
        movement.state = Character_State.Idle

        view4: ecs.View

        Movement_User_Data :: struct {
            movement_table: ^ecs.Tiny_Table(Movement),
        }

        user_data : Movement_User_Data = Movement_User_Data{ 
            movement_table = &movement_table,
        }

        not_idle_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil)->bool {
            eid := ecs.get_entity(row)
            movement_table := (^Movement_User_Data)(user_data).movement_table

            // get Movement component
            movement := ecs.get_component(movement_table, row)

            if movement == nil do return false

            if movement.state == Character_State.Idle do return false

            return true
        }

        err = ecs.view_init(&view4, &db, {&movement_table}, not_idle_filter)
        if err != nil { report_error(err); return }

        view4.user_data = &user_data

        err = ecs.rebuild(&view4)
        if err != nil { report_error(err); return }
    
        it4: ecs.Iterator

        err = ecs.iterator_init(&it4, &view4)
        if err != nil { report_error(err); return }

        // Print list of moving entities (not idle)
        fmt.println()
        fmt.println(ecs.view_len(&view4), "entities are moving (not idle):")
        for ecs.iterator_next(&it4) {
            eid = ecs.get_entity(&it4)

            movement := ecs.get_component(&movement_table, &it4)

            switch eid {
                case human: fmt.println("Human is", movement.state)
                case bird:  fmt.println("Bird is", movement.state)
                case chair: fmt.println("Chair is", movement.state)
            }
        }

        // Now let's change state of some entities and rerun filter for them
        movement = ecs.tiny_table__get_component_by_entity(&movement_table, human)
        movement.state = Character_State.Idle // human stopped moving

        movement = ecs.tiny_table__get_component_by_entity(&movement_table, chair)
        movement.state = Character_State.Sliding // chair started sliding for some reason

        fmt.println()
        fmt.println("View is not updated:")
        ecs.iterator_reset(&it4)
        for ecs.iterator_next(&it4) {
            eid = ecs.get_entity(&it4)

            movement := ecs.get_component(&movement_table, &it4)

            switch eid {
                case human: fmt.println("Human is", movement.state)
                case bird:  fmt.println("Bird is", movement.state)
                case chair: fmt.println("Chair is", movement.state)
            }
        }

        
        // If we re-iterate again, view is not updated, we need to rerun filter for entities that changed
        ecs.view__rerun_filter(&view4, human)

        // Rerun filter for all views that has this component and entity
        ecs.tiny_table__rerun_views_filters(&movement_table, chair)

        fmt.println()
        fmt.println("Now view is updated after we rerun filters:")
        ecs.iterator_reset(&it4)
        for ecs.iterator_next(&it4) {
            eid = ecs.get_entity(&it4)

            movement := ecs.get_component(&movement_table, &it4)

            switch eid {
                case human: fmt.println("Human is", movement.state)
                case bird:  fmt.println("Bird is", movement.state)
                case chair: fmt.println("Chair is", movement.state)
            }
        }

}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}




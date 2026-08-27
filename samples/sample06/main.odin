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
    import "core:mem"
     
// ODE_ECS
    import ecs "../../src"
    import oc "../../src/ode_core"

//
// This example includes simple error handling.
//
main :: proc() {

    //
    // OPTIONAL: Setup memory tracking and logger. 
    //
        mem_track: oc.Mem_Track

        context.allocator = oc.mem_track__init(&mem_track, context.allocator)
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track)

        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

    //
    // Actual ODE_ECS sample starts here.
    //
        err: ecs.Error

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

        fmt.println("Tagged entities:")
        for eid in ecs.slice(&is_alive_table) {
            fmt.println("Entity tagged in `is_alive_table`:", eid)
        }

        is_human_alive := false
        is_bird_alive := false
        is_chair_alive := false

        for eid in ecs.entities_slice(&view) {
            if eid == human do is_human_alive = true
            if eid == bird do is_bird_alive = true
            if eid == chair do is_chair_alive = true
        }

        fmt.println()
        fmt.println("Only entities tagged in `is_alive_table` should be alive:")
        fmt.println("Is human alive:",  is_human_alive)
        fmt.println("Is bird alive:",  is_bird_alive)
        fmt.println("Is chair alive:", is_chair_alive)

        ecs.untag(&is_alive_table, human)
        ecs.untag(&is_alive_table, chair)

        is_human_alive = false
        is_bird_alive = false
        is_chair_alive = false

        for eid in ecs.entities_slice(&view) {
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

            if eid.ix == 0 || eid.ix == 2 do return true

            return false
        }

        err = ecs.view_init(&view2, &db, {&is_alive_table}, filter = my_filter)
         if err != nil { report_error(err); return }

        ecs.rebuild(&view2)

        ecs.add_tag(&is_alive_table, human)
        ecs.add_tag(&is_alive_table, chair)

        is_human_alive = false
        is_bird_alive = false
        is_chair_alive = false

        for eid in ecs.entities_slice(&view2) {
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

            if eid == data.human_eid || eid == data.chair_eid do return true

            return false
        }

        my_user_data := My_User_Data{
            human_eid = human,
            chair_eid = chair,
        }

        view3.user_data = &my_user_data

        err = ecs.view_init(&view3, &db, {&is_alive_table}, filter = my_filter2)
         if err != nil { report_error(err); return }

        ecs.rebuild(&view3)

        is_human_alive = false
        is_bird_alive = false
        is_chair_alive = false

        for eid in ecs.entities_slice(&view3) {
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

        movement_table : ecs.Tiny_Table(Movement)

        err = ecs.tiny_table__init(&movement_table, &db)
        if err != nil { report_error(err); return } 

        movement: ^Movement

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

            movement := ecs.get_component(movement_table, row)

            if movement == nil do return false

            if movement.state == Character_State.Idle do return false

            return true
        }

        err = ecs.view_init(&view4, &db, {&movement_table}, filter = not_idle_filter)
        if err != nil { report_error(err); return }

        view4.user_data = &user_data

        err = ecs.rebuild(&view4)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println(ecs.view_len(&view4), "entities are moving (not idle):")
        view4_eids := ecs.entities_slice(&view4)
        view4_movement := ecs.slice(&view4, Movement)
        for i in 0..<len(view4_eids) {
            eid := view4_eids[i]
            movement := view4_movement[i]

            switch eid {
                case human: fmt.println("Human is", movement.state)
                case bird:  fmt.println("Bird is", movement.state)
                case chair: fmt.println("Chair is", movement.state)
            }
        }

        movement = ecs.tiny_table__get_component_by_entity(&movement_table, human)
        movement.state = Character_State.Idle

        movement = ecs.tiny_table__get_component_by_entity(&movement_table, chair)
        movement.state = Character_State.Sliding

        fmt.println()
        fmt.println("View is not updated:")
        view4_eids = ecs.entities_slice(&view4)
        view4_movement = ecs.slice(&view4, Movement)
        for i in 0..<len(view4_eids) {
            eid := view4_eids[i]
            movement := view4_movement[i]

            switch eid {
                case human: fmt.println("Human is", movement.state)
                case bird:  fmt.println("Bird is", movement.state)
                case chair: fmt.println("Chair is", movement.state)
            }
        }


        ecs.view__rerun_filter(&view4, human)

        ecs.tiny_table__rerun_views_filters(&movement_table, chair)

        fmt.println()
        fmt.println("Now view is updated after we rerun filters:")
        view4_eids = ecs.entities_slice(&view4)
        view4_movement = ecs.slice(&view4, Movement)
        for i in 0..<len(view4_eids) {
            eid := view4_eids[i]
            movement := view4_movement[i]

            switch eid {
                case human: fmt.println("Human is", movement.state)
                case bird:  fmt.println("Bird is", movement.state)
                case chair: fmt.println("Chair is", movement.state)
            }
        }

    ///////////////////////////////////////////////////////////////////////////////
    // View excludes example: "has Movement but is NOT tagged in is_alive_table".
    //
        view5: ecs.View

        err = ecs.view_init(&view5, &db, {&movement_table}, excludes = {&is_alive_table})
        if err != nil { report_error(err); return }

        err = ecs.rebuild(&view5)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Entities with Movement that are NOT tagged alive (all three are tagged, so none):")
        for eid in ecs.entities_slice(&view5) {
            switch eid {
                case human: fmt.println("Human")
                case bird:  fmt.println("Bird")
                case chair: fmt.println("Chair")
            }
        }

        err = ecs.untag(&is_alive_table, chair)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("After untagging chair (auto-updated, no rebuild):")
        for eid in ecs.entities_slice(&view5) {
            switch eid {
                case human: fmt.println("Human")
                case bird:  fmt.println("Bird")
                case chair: fmt.println("Chair")
            }
        }

    ///////////////////////////////////////////////////////////////////////////////
    // View any_of example (OR): "has Movement AND (is flying OR is heavy)".
    //
        is_flying_table: ecs.Tag_Table
        is_heavy_table:  ecs.Tag_Table

        err = ecs.tag_table__init(&is_flying_table, &db, 10)
        if err != nil { report_error(err); return }
        err = ecs.tag_table__init(&is_heavy_table, &db, 10)
        if err != nil { report_error(err); return }

        err = ecs.tag(&is_flying_table, bird)
        if err != nil { report_error(err); return }
        err = ecs.tag(&is_heavy_table, chair)
        if err != nil { report_error(err); return }

        view6: ecs.View
        err = ecs.view_init(&view6, &db, {&movement_table}, any_of = {&is_flying_table, &is_heavy_table})
        if err != nil { report_error(err); return }

        err = ecs.rebuild(&view6)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Entities with Movement that are flying or heavy (bird flies, chair is heavy):")
        for eid in ecs.entities_slice(&view6) {
            switch eid {
                case human: fmt.println("Human")
                case bird:  fmt.println("Bird")
                case chair: fmt.println("Chair")
            }
        }

        err = ecs.tag(&is_heavy_table, human)
        if err != nil { report_error(err); return }

        err = ecs.untag(&is_heavy_table, chair)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("After tagging human heavy and untagging chair (auto-updated, no rebuild):")
        for eid in ecs.entities_slice(&view6) {
            switch eid {
                case human: fmt.println("Human")
                case bird:  fmt.println("Bird")
                case chair: fmt.println("Chair")
            }
        }

}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}




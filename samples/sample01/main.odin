/*
    2025 (c) Oleh, https://github.com/zm69
*/

package ode_ecs_sample1

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:log"
    import "core:slice"
    import "core:mem"

// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// Components
//
    Position :: struct { x, y: int } 
    AI :: struct { neurons_count: int }
    Physical :: struct { velocity, mass: f32 }


//
// This example includes simple error handing.
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
        //
        // ECS Database
        //
        db: ecs.Database

        // 
        // Component tables
        //
        positions : ecs.Table(Position)
        ais : ecs.Table(AI)
        physics: ecs.Table(Physical)

        //
        // Views
        //
        physical: ecs.View 
        
        //
        // Simple error handling
        //
        err: ecs.Error

        report_error :: proc (err: ecs.Error, loc := #caller_location) {
            log.error("Error:", err, location = loc)
        }

    //
    // Init 
    //
       
        // Init database
        defer { 
            err = ecs.terminate(&db) 
            if err != nil do report_error(err)
        }
        err = ecs.init(&db, 100_000, allocator) // Maximum 100K entities
        if err != nil { report_error(err); return }
        
        // Init tables
        err = ecs.table_init(&positions, &db, 100_000) // Maximum 100K position components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&ais, &db, 20_000) // Maximum 20K AI components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&physics, &db, 70_000) // Maximum 70K position components
        if err != nil { report_error(err); return }

        // Init views
        err = ecs.view__init(&physical, &db, {&positions, &physics})
        if err != nil { report_error(err); return }

    //
    // Systems
    //

        process_physics :: proc(view: ^ecs.View, positions: ^ecs.Table(Position), physics: ^ecs.Table(Physical)) {
            pos: ^Position
            ph: ^Physical
            err: ecs.Error
            it: ecs.Iterator

            err = ecs.iterator_init(&it, view)
            if err != nil { report_error(err); return }

            for ecs.iterator__next(&it) {

                // Doing some calculations on components

                pos = ecs.get_component(positions, &it)
                pos.x += 34
                pos.y += 7

                ph = ecs.get_component(physics, &it)
                ph.velocity += 0.4
                ph.mass += 0.1
            }

        }

        process_ai :: proc (table: ^ecs.Table(AI)) {
            for &ai in table.records {
                // Doing some calculations on components
                ai.neurons_count += 1 
            }
        }       

    

        fmt.println("Total memory usage:", ecs.memory_usage(&db) / runtime.Megabyte, "MB")
}

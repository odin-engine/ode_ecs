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
    import "core:math"
    import "core:math/rand"
    import "core:time"
    import "core:testing"
     

// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// Components
//
   
// 
// Globals
// 
    // ECS Database
    db: ecs.Database

    // Component tables
    
    
    // Views
    physical: ecs.View 

   
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
        // Simple error handling
        //
        err: ecs.Error

    //
    // Init 
    //
       
        // Init database
        defer { 
            err = ecs.terminate(&db) 
            if err != nil do report_error(err)
        }
        err = ecs.init(&db, 10, allocator) // Maximum 100K entities
        if err != nil { report_error(err); return }
        
        // Init tables



    //
    // Systems
    //


    //
    // Results
    //

    fmt.println("EEEEEEEEEEEEEE")
        
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

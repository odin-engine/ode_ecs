/*
    2025 (c) Oleh, https://github.com/zm69

    Memory and speed comparision of Table and Compact_Table.
*/

package ode_ecs_sample4

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
    // UI_Panel
    //

        UI_Panel :: struct { 
            color: int, 
            width: int,
            height: int, 
        }

        ui_panel__print :: proc(self: ^UI_Panel) {
            fmt.printf("panel width=%v height=%v", self.width, self.height)
        }

    //
    // Tiny_Tables 
    //


    
// 
// Globals
// 
    // ECS Database
    db: ecs.Database

    table: ecs.Table(UI_Panel)
    compact_table: ecs.Compact_Table(UI_Panel)

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
        
        err = ecs.init(&db, 100_000, allocator) // Maximum 100K entities
        if err != nil { report_error(err); return }
        
        // Init tables
        err = ecs.table_init(&table, &db, 1_000) // Maximum 1K components
        if err != nil { report_error(err); return }

        err = ecs.compact_table__init(&compact_table, &db, 1_000) // Maximum 1K components
        if err != nil { report_error(err); return }

    //
    // Systems
    //


    //
    // Results
    //

    // tt: ecs.Tiny_Table(UI_Position)
    // ecs.tiny_table__init(&tt, &db)
    // fmt.printfln("%-30s %v bytes", "Tiny_Table(UI_Position) memory usage:", ecs.memory_usage(&tt))
    // fmt.printfln("%-30s %v", "is_power_of_2(64):", math.is_power_of_two(64))
    // fmt.printfln("%-30s %v", "is_power_of_2(63):", math.is_power_of_two(63))
    // fmt.printfln("%-30s %v", "is_power_of_2(65):", math.is_power_of_two(65))

    fmt.println("YOOOOOOOOOOO!!!")


        //print_elements(&root)
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}




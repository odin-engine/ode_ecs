/*
    2025 (c) Oleh, https://github.com/zm69

    Run this sample with speed optimizations to see results closer to real-world performance:

    odin run . -o:speed
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
// Globals
// 
    // ECS Database
    db: ecs.Database

    // Component tables
    positions : ecs.Table(Position)
    ais : ecs.Table(AI)
    physics: ecs.Table(Physical)

    // Views
    physical: ecs.View 

    // All possible components combinations for generating random entities
    g_combo_choice: [7][3]int = {{ 1, 2, 3 }, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}, {1, 2, 0}, {1, 3, 0}, {2, 3, 0}}

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
        err = ecs.table_init(&positions, &db, 100_000) // Maximum 100K position components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&ais, &db, 100_000) // Maximum 20K AI components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&physics, &db, 100_000) // Maximum 70K position components
        if err != nil { report_error(err); return }

        // Init views
        err = ecs.view_init(&physical, &db, {&positions, &physics})
        if err != nil { report_error(err); return }

    //
    // Systems
    //

        iterate_over_view :: proc(view: ^ecs.View, positions: ^ecs.Table(Position), physics: ^ecs.Table(Physical)) {
            pos: ^Position
            ph: ^Physical
            err: ecs.Error
            it: ecs.Iterator

            err = ecs.iterator_init(&it, view)
            if err != nil { report_error(err); return }

            for ecs.iterator_next(&it) {

                // Doing some calculations on components

                pos = ecs.get_component(positions, &it)
                pos.x += 34
                pos.y += 7

                ph = ecs.get_component(physics, &it)
                ph.velocity += 0.4
                ph.mass += 0.1
            }
        }

        iterate_over_table :: proc (table: ^ecs.Table(AI)) {
            for &ai in table.rows {
                // Doing some calculations on components
                ai.neurons_count += 1 
            }
        }       

    //
    // Game load, create 100_000 entities with random components
    // 
        create_entities_with_random_components_and_data(100_000)
    //
    //  Game loop, frame zero, iterating over table only
    // 
        sw: time.Stopwatch
        time.stopwatch_start(&sw)

            iterate_over_table(&ais) 

        time.stopwatch_stop(&sw)

        _, _, _, nanos0 := time.precise_clock_from_stopwatch(sw)

    //
    //  Game loop, frame one, iterating over view and table
    // 
     
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            iterate_over_view(&physical, &positions, &physics)

        time.stopwatch_stop(&sw)

        _, _, _, nanos1 := time.precise_clock_from_stopwatch(sw)

    //
    //  Game loop, frame two, destroying and creating 10_000 entities plus iterating over view and table
    // 
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            destroy_entities_in_range(45_000, 55_000)

            create_entities_with_random_components_and_data(10_000)

            iterate_over_view(&physical, &positions, &physics)

            iterate_over_table(&ais)

        time.stopwatch_stop(&sw)

        _, _, _, nanos2 := time.precise_clock_from_stopwatch(sw)
    //
    // Print results
    //
        s:= oc.add_thousand_separator(ecs.database__entities_len(&db), sep=',', allocator=allocator)
        fmt.printfln("%-30s %s", "Entities count:", s)
        delete(s, allocator)

        s = oc.add_thousand_separator(ecs.table_len(&positions), sep=',', allocator=allocator)
        fmt.printfln("%-30s %v", "Position components count:", s)
        delete(s, allocator)

        s = oc.add_thousand_separator(ecs.table_len(&ais), sep=',', allocator=allocator)
        fmt.printfln("%-30s %v", "AI components count:", s)
        delete(s, allocator)

        s = oc.add_thousand_separator(ecs.table_len(&physics), sep=',', allocator=allocator)
        fmt.printfln("%-30s %v", "Physics components count:", s) 
        delete(s, allocator)

        s = oc.add_thousand_separator(ecs.view_len(&physical), sep=',', allocator=allocator)
        fmt.printfln("%-30s %v", "Physical view len:", s)
        delete(s, allocator)

        fmt.printfln("%-30s %v MB", "Total memory usage:", ecs.memory_usage(&db) / runtime.Megabyte)
        fmt.println("-----------------------------------------------------------")

        s = oc.add_thousand_separator(ecs.table_len(&ais), sep=',', allocator=allocator)
        fmt.printfln("%-30s %.4f ms (%v components)", "Iterate over table:", f64(nanos0)/1_000_000.0, s)
        delete(s, allocator)
        
        s = oc.add_thousand_separator(ecs.view_len(&physical), sep=',', allocator=allocator)
        s2 := oc.add_thousand_separator(ecs.view_len(&physical) * 2, sep=',', allocator=allocator)
        fmt.printfln("%-30s %.4f ms (%v rows, %v components)", "Iterate over view:", f64(nanos1)/1_000_000.0, s, s2)
        delete(s, allocator)
        delete(s2, allocator)

        fmt.printfln("%-30s %.4f ms (destroying 10K entities, creating 10K entities with random components and iterating table and view)", "Frame two time:", f64(nanos2)/1_000_000.0)
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

create_entities_with_random_components_and_data :: proc(number_of_components_to_create: int) {
    pos: ^Position
    ph: ^Physical
    ai: ^AI
    err: ecs.Error

    eid: ecs.entity_id
    eid_components_count: int
    for i:=0; i < number_of_components_to_create; i+=1 {
        eid, err = ecs.database__create_entity(&db)
        if err != nil { report_error(err); return }

        // Randomly chose what components combo we want for entity
        combo := rand.choice(g_combo_choice[:])

        for j:=0; j<3; j+=1 {
            switch combo[j] {
                case 0:
                    break
                case 1:
                    pos, err = ecs.add_component(&positions, eid)
                    if err != nil { report_error(err); fmt.println(eid); return }
                    // pos.x = int(rand.int63()) % 1920
                    // pos.y = int(rand.int63()) % 1080
                case 2:               
                    ai, err = ecs.add_component(&ais, eid)
                    if err != nil { report_error(err); fmt.println(eid); return }
                    // ai.neurons_count = int(rand.uint32()) % 400
                case 3:
                    ph, err = ecs.add_component(&physics, eid)
                    if err != nil { report_error(err); return } 
                    // ph.mass = rand.float32_range(30, 100)
            }

        }
    }
}

destroy_entities_in_range :: proc(start_ix, end_ix: int) {
    assert(end_ix > start_ix)
    assert(start_ix >= 0)

    for i:=start_ix; i < end_ix; i+=1 {
        eid := ecs.get_entity(&db, i)
        ecs.database__destroy_entity(&db, eid)
    }
}
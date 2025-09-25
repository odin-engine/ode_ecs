/*
    2025 (c) Oleh, https://github.com/zm69

    Memory and speed comparision of Table and Compact_Table.

    Run this sample with speed optimizations to see results closer to real-world performance:

    odin run . -o:speed
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
// Components
// 

    Position :: struct { x, y: int }
    AI :: struct { level: int, name: [32]u8 }
    Health :: struct { hp: int, max_hp: int }
    Inventory :: struct { items: [8][32]Item_Type, item_count: int }

    Item_Type :: enum {
        None = 0,
        Sword,
        Armor,
        Potion,
        Food,
        Misc
    } 

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

        ENTITIES_CAP :: 200_000
        COMPONENTS_CAP :: 10_000

        // 100k entities !!!
        err = ecs.init(&db, ENTITIES_CAP, allocator) 
        if err != nil { report_error(err); return }

        // Table and Compact_Table
        table : ecs.Table(Health)
        compact_table : ecs.Compact_Table(Health)

        large_table : ecs.Table(Health)
        large_compact_table : ecs.Compact_Table(Health)

        // Init table and compact_table
        err = ecs.table__init(&table, &db, COMPONENTS_CAP)
        if err != nil { report_error(err); return }

        err = ecs.compact_table__init(&compact_table, &db, COMPONENTS_CAP)
        if err != nil { report_error(err); return }

        // Init table and compact_table
        err = ecs.table__init(&large_table, &db, ENTITIES_CAP)
        if err != nil { report_error(err); return }

        err = ecs.compact_table__init(&large_compact_table, &db, ENTITIES_CAP)
        if err != nil { report_error(err); return }


        //
        // Create ENTITIES_CAP entities and fill table and compact_table
        //

        eid : ecs.entity_id
        component: ^Health

        //
        // Fill smaller and large tables
        //

            for i:=0; i < ENTITIES_CAP; i+=1 {
                eid, err = ecs.create_entity(&db)
                if err != nil { report_error(err); return }

                //
                // fill small tables
                //

                if i < COMPONENTS_CAP {
                    // create table component
                    component, err = ecs.add_component(&table, eid)
                    if err != nil { report_error(err); return }

                    // fill component with "random" values
                    component.hp = i
                    component.max_hp = ENTITIES_CAP

                    // create compact_table component
                    component, err = ecs.add_component(&compact_table, eid)
                    if err != nil { report_error(err); return }

                    // fill component with "random" values
                    component.hp = i   
                    component.max_hp = ENTITIES_CAP
                }

                //
                // fill large tables
                //

                // create table component
                component, err = ecs.add_component(&large_table, eid)
                if err != nil { report_error(err); return }

                // fill component with "random" values
                component.hp = i
                component.max_hp = ENTITIES_CAP

                // create compact_table component
                component, err = ecs.add_component(&large_compact_table, eid)
                if err != nil { report_error(err); return }

                // fill component with "random" values
                component.hp = i   
                component.max_hp = ENTITIES_CAP
            }

        //
        // Iterate over smaller Table
        //

        sw: time.Stopwatch

        time.stopwatch_start(&sw)

            for &comp, index in table.rows {
                eid = ecs.get_entity(&table, index)

                comp.hp += eid.ix  // random operation over component
                comp.max_hp += eid.ix
            }    
        
        time.stopwatch_stop(&sw)
        _, _, _, smaller_table_time := time.precise_clock_from_stopwatch(sw)

        //
        // Iterate over smaller Compact_Table
        //

        time.stopwatch_start(&sw)

            for &comp, index in compact_table.rows {
                eid = ecs.get_entity(&compact_table, index)

                comp.hp += eid.ix  // random operation over component
                comp.max_hp += eid.ix
            }    
        
        time.stopwatch_stop(&sw)
        _, _, _, smaller_compact_table_time := time.precise_clock_from_stopwatch(sw)

        //
        // Iterate over large Table
        //

        time.stopwatch_start(&sw)

            for &comp, index in large_table.rows {
                eid = ecs.get_entity(&large_table, index)

                comp.hp += eid.ix  // random operation over component
                comp.max_hp += eid.ix
            }    
        
        time.stopwatch_stop(&sw)
        _, _, _, large_table_time := time.precise_clock_from_stopwatch(sw)

        //
        // Iterate over large Compact_Table
        //

        time.stopwatch_start(&sw)

            for &comp, index in large_compact_table.rows {
                eid = ecs.get_entity(&large_compact_table, index)

                comp.hp += eid.ix  // random operation over component
                comp.max_hp += eid.ix
            }    
        
        time.stopwatch_stop(&sw)
        _, _, _, large_compact_table_time := time.precise_clock_from_stopwatch(sw)

        s:= oc.add_thousand_separator(ecs.database__entities_len(&db), sep=',', allocator=allocator)
        fmt.printfln("%-30s %s", "Entities count:", s)
        delete(s, allocator)

        fmt.printfln("%-30s %.2f MB", "Total memory usage:", f64(ecs.memory_usage(&db)) / f64(runtime.Megabyte))

        //
        // Smaller Table
        // 
        fmt.println()
        s = oc.add_thousand_separator(ecs.table_len(&table), sep=',', allocator=allocator)
        fmt.printfln("Table (%v rows)", s)
        delete(s, allocator)
        fmt.println("-----------------------------------------")
       
        fmt.printfln("%-30s %.4f ms", "Loop time:", f64(smaller_table_time) / 1_000_000.0)
        fmt.printfln("%-30s %.2f MB", "Memory usage:", f64(ecs.memory_usage(&table))/  f64(runtime.Megabyte))

        //
        // Smaller Compact_Table
        // 
        fmt.println()
        s = oc.add_thousand_separator(ecs.table_len(&compact_table), sep=',', allocator=allocator)
        fmt.printfln("Compact_Table (%v rows)", s)
        delete(s, allocator)
        fmt.println("-----------------------------------------")
       
        fmt.printfln("%-30s %.4f ms", "Loop time:", f64(smaller_compact_table_time) / 1_000_000.0)
        fmt.printfln("%-30s %.2f MB", "Memory usage:",  f64(ecs.memory_usage(&compact_table))/  f64(runtime.Megabyte))
       
        //
        // Large Table
        // 
        fmt.println()
        s = oc.add_thousand_separator(ecs.table_len(&large_table), sep=',', allocator=allocator)
        fmt.printfln("Table (%v rows)", s)
        delete(s, allocator)
        fmt.println("-----------------------------------------")
       
        fmt.printfln("%-30s %.4f ms", "Loop time:", f64(large_table_time) / 1_000_000.0)
        fmt.printfln("%-30s %.2f MB", "Memory usage:", f64(ecs.memory_usage(&large_table))/  f64(runtime.Megabyte))


        //
        // Large Compact_Table
        // 
        fmt.println()
        s = oc.add_thousand_separator(ecs.table_len(&large_compact_table), sep=',', allocator=allocator)
        fmt.printfln("Compact_Table (%v rows)", s)
        delete(s, allocator)
        fmt.println("-----------------------------------------")
       
        fmt.printfln("%-30s %.4f ms", "Loop time:", f64(large_compact_table_time) / 1_000_000.0)
        fmt.printfln("%-30s %.2f MB", "Memory usage:", f64(ecs.memory_usage(&large_compact_table))/  f64(runtime.Megabyte))

        fmt.println("=========================================")
        fmt.println("Conclusion:")
        fmt.println("It makes sense to use Compact_Table if you want to save memory at the cost of speed,")
        fmt.println("but only if the Compact_Table capacity is much lower than your database entity capacity.")
        fmt.println("If the Compact_Table capacity is close to the database entity capacity, Table will be faster and save you more memory.")

    
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}




/*
    2025 (c) Oleh, https://github.com/zm69

    Table vs. Compact_Table comparison and Tiny_Table vs. Compact_Table vs. Table comparison.

    Run this sample with speed optimizations to see results closer to real-world performance:

    odin run . -o:speed
*/

package ode_ecs_sample5

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:log"
    import "core:mem"
    import "core:time"
     
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

        context.allocator = oc.mem_track__init(&mem_track, context.allocator)
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track) // Defers run in reverse declaration order

        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        // Panic allocator ensures no allocations happen outside the provided allocator
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

        ENTITIES_CAP :: 200_000
        COMPONENTS_CAP :: 10_000

        err = ecs.init(&db, ENTITIES_CAP, allocator)
        if err != nil { report_error(err); return }

        table : ecs.Table(Health)
        compact_table : ecs.Compact_Table(Health)

        large_table : ecs.Table(Health)
        large_compact_table : ecs.Compact_Table(Health)

        err = ecs.table__init(&table, &db, COMPONENTS_CAP)
        if err != nil { report_error(err); return }

        err = ecs.compact_table__init(&compact_table, &db, COMPONENTS_CAP)
        if err != nil { report_error(err); return }

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
                    component, err = ecs.add_component(&table, eid)
                    if err != nil { report_error(err); return }

                    component.hp = i
                    component.max_hp = ENTITIES_CAP

                    component, err = ecs.add_component(&compact_table, eid)
                    if err != nil { report_error(err); return }

                    component.hp = i
                    component.max_hp = ENTITIES_CAP
                }

                //
                // fill large tables
                //

                component, err = ecs.add_component(&large_table, eid)
                if err != nil { report_error(err); return }

                component.hp = i
                component.max_hp = ENTITIES_CAP

                component, err = ecs.add_component(&large_compact_table, eid)
                if err != nil { report_error(err); return }

                component.hp = i
                component.max_hp = ENTITIES_CAP
            }

        //
        // Iterate over smaller Table
        //

        sw: time.Stopwatch

        time.stopwatch_reset(&sw) // NOTE: Stopwatch accumulates; reset before every measurement
        time.stopwatch_start(&sw)

            table_dense := ecs.slice(&table)
            table_eids := ecs.entities_slice(&table)
            for i in 0..<len(table_dense) {
                comp := &table_dense[i]
                eid = table_eids[i]

                comp.hp += eid.ix
                comp.max_hp += eid.ix
            }

        time.stopwatch_stop(&sw)
        _, _, _, smaller_table_time := time.precise_clock_from_stopwatch(sw)

        //
        // Iterate over smaller Compact_Table
        //

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            compact_table_dense := ecs.slice(&compact_table)
            compact_table_eids := ecs.entities_slice(&compact_table)
            for i in 0..<len(compact_table_dense) {
                comp := &compact_table_dense[i]
                eid = compact_table_eids[i]

                comp.hp += eid.ix
                comp.max_hp += eid.ix
            }

        time.stopwatch_stop(&sw)
        _, _, _, smaller_compact_table_time := time.precise_clock_from_stopwatch(sw)

        //
        // Iterate over large Table
        //

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            large_table_dense := ecs.slice(&large_table)
            large_table_eids := ecs.entities_slice(&large_table)
            for i in 0..<len(large_table_dense) {
                comp := &large_table_dense[i]
                eid = large_table_eids[i]

                comp.hp += eid.ix
                comp.max_hp += eid.ix
            }

        time.stopwatch_stop(&sw)
        _, _, _, large_table_time := time.precise_clock_from_stopwatch(sw)

        //
        // Iterate over large Compact_Table
        //

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            large_compact_table_dense := ecs.slice(&large_compact_table)
            large_compact_table_eids := ecs.entities_slice(&large_compact_table)
            for i in 0..<len(large_compact_table_dense) {
                comp := &large_compact_table_dense[i]
                eid = large_compact_table_eids[i]

                comp.hp += eid.ix
                comp.max_hp += eid.ix
            }
        
        time.stopwatch_stop(&sw)
        _, _, _, large_compact_table_time := time.precise_clock_from_stopwatch(sw)


        //
        // Comparison with Tiny_Table
        //

        tiny_table: ecs.Tiny_Table(Health)
        table8: ecs.Table(Health)
        compact_table8: ecs.Compact_Table(Health)

        err = ecs.tiny_table__init(&tiny_table, &db)
        if err != nil { report_error(err); return }

        err = ecs.table__init(&table8, &db, ecs.TINY_TABLE__ROW_CAP)
        if err != nil { report_error(err); return }

        err = ecs.compact_table__init(&compact_table8, &db, ecs.TINY_TABLE__ROW_CAP)
        if err != nil { report_error(err); return }

        //
        // Fill tables
        //

        for i:= 0; i < ecs.TINY_TABLE__ROW_CAP; i+=1 {
            eid = ecs.get_entity(&db, i)

            component, err = ecs.add_component(&tiny_table, eid)
            if err != nil { report_error(err); return }

            component, err = ecs.add_component(&table8, eid)
            if err != nil { report_error(err); return }

            component, err = ecs.add_component(&compact_table8, eid)
            if err != nil { report_error(err); return }
        }

        
        // 8-row tables are too fast to time in a single pass, so we repeat REPEAT times.
        // Loop times below are totals over REPEAT passes; `rep` is folded into the work
        // so the optimizer can't collapse the identical passes.
        REPEAT :: 1_000_000

        //
        // Iterate over Tiny_Table
        //

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            // ecs.slice bound once outside the repeat loop; rows don't change across repeats.
            tiny_dense := ecs.slice(&tiny_table)
            for rep := 0; rep < REPEAT; rep += 1 {
                for &comp, index in tiny_dense {
                    eid = ecs.get_entity(&tiny_table, index)

                    comp.hp += eid.ix + rep
                    comp.max_hp += eid.ix
                }
            }

        time.stopwatch_stop(&sw)
        _, _, _, tiny_table_time := time.precise_clock_from_stopwatch(sw)


        //
        // Iterate over tiny Compact_Table
        //

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            compact8_dense := ecs.slice(&compact_table8)
            for rep := 0; rep < REPEAT; rep += 1 {
                for &comp, index in compact8_dense {
                    eid = ecs.get_entity(&compact_table8, index)

                    comp.hp += eid.ix + rep
                    comp.max_hp += eid.ix
                }
            }

        time.stopwatch_stop(&sw)
        _, _, _, compact_table8_time := time.precise_clock_from_stopwatch(sw)

        //
        // Iterate over tiny Table
        //

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            table8_dense := ecs.slice(&table8)
            for rep := 0; rep < REPEAT; rep += 1 {
                for &comp, index in table8_dense {
                    eid = ecs.get_entity(&table8, index)

                    comp.hp += eid.ix + rep
                    comp.max_hp += eid.ix
                }
            }

        time.stopwatch_stop(&sw)
        _, _, _, table8_time := time.precise_clock_from_stopwatch(sw)

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
    
        fmt.println()
        fmt.println("Comparison with Tiny_Table")
        fmt.println("=========================================")
        fmt.printfln("(8-row loop times below are totals over %v passes)", REPEAT)

        //
        // Tiny_Table
        //
        fmt.println()
        s = oc.add_thousand_separator(ecs.table_len(&tiny_table), sep=',', allocator=allocator)
        fmt.printfln("Tiny_Table (%v rows)", s)
        delete(s, allocator)
        fmt.println("-----------------------------------------")
    
        fmt.printfln("%-30s %.4f ms (%v passes)", "Loop time:", f64(tiny_table_time) / 1_000_000.0, REPEAT)
        fmt.printfln("%-30s %.4f MB", "Memory usage:",  f64(ecs.memory_usage(&tiny_table)) / f64(runtime.Megabyte))

        //
        // Compact_Table8
        //
        fmt.println()
        s = oc.add_thousand_separator(ecs.table_len(&compact_table8), sep=',', allocator=allocator)
        fmt.printfln("Compact_Table (%v rows)", s)
        delete(s, allocator)
        fmt.println("-----------------------------------------")
    
        fmt.printfln("%-30s %.4f ms (%v passes)", "Loop time:", f64(compact_table8_time) / 1_000_000.0, REPEAT)
        fmt.printfln("%-30s %.4f MB", "Memory usage:",  f64(ecs.memory_usage(&compact_table8)) / f64(runtime.Megabyte))

        //
        // Table8
        //
        fmt.println()
        s = oc.add_thousand_separator(ecs.table_len(&table8), sep=',', allocator=allocator)
        fmt.printfln("Table (%v rows)", s)
        delete(s, allocator)
        fmt.println("-----------------------------------------")
    
        fmt.printfln("%-30s %.4f ms (%v passes)", "Loop time:", f64(table8_time) / 1_000_000.0, REPEAT)
        fmt.printfln("%-30s %.4f MB", "Memory usage:",  f64(ecs.memory_usage(&table8)) / f64(runtime.Megabyte))

        fmt.println("=========================================")
        fmt.println("Conclusions:")
        fmt.println()
        fmt.println("   Compact_Table vs. Table")
        fmt.println("       Use Compact_Table to save memory when its capacity is much lower than the database entity capacity. Iteration speed is")
        fmt.println("       about the same as Table, but per-entity lookups and add/remove are slower (hash map vs. direct array). If the capacity is")
        fmt.println("       close to the entity capacity, Table is faster on lookups and uses less memory.")
        fmt.println()
        fmt.println("   For Tiny_Table vs. Compact_Table vs. Table:")
        fmt.printfln("       Use Tiny_Table when you need a table with a component capacity of %v or less.", ecs.TINY_TABLE__ROW_CAP)


}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}




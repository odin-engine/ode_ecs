/*
    2025 (c) Oleh, https://github.com/zm69

    Tiny_Table example. Also shows how to use View on top of different table types (Tiny_Table, Table and Compact_Table).
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

        // Simple error handling
        err: ecs.Error

        // ECS Database
        db: ecs.Database

        // Entities
        human, robot, bird: ecs.entity_id

        // Init database
        defer { 
            err = ecs.terminate(&db) 
            if err != nil do report_error(err)
        }
        err = ecs.init(&db, 100, allocator) 
        if err != nil { report_error(err); return }

        //
        // Create entities
        //

        // human entity
        human, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        // robot entity
        robot, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        // non important entity, we just want to increase entity count
        _, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        // non important entity, we just want to increase entity count
        _, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        // bird entity
        bird, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        //
        // Tiny_Table
        //

        pos_table : ecs.Tiny_Table(Position) // Tiny_Table !!!
        
        err = ecs.tiny_table__init(&pos_table, &db)
        if err != nil { report_error(err); return }

        //
        // Add components to human and bird entities
        // 

        human_pos: ^Position
        bird_pos: ^Position

        human_pos, err = ecs.add_component(&pos_table, human)
        if err != nil { report_error(err); return }
        human_pos.x = 10
        human_pos.y = 20    

        bird_pos, err = ecs.add_component(&pos_table, bird)
        if err != nil { report_error(err); return }
        bird_pos.x = 100
        bird_pos.y = 200   

        // 
        // Iterate over components. 
        // NOTE: Tiny_Table can hold only eight (defined by TINY_TABLE__ROW_CAP) components. 
        // .rows in Tiny_Table is a static (fixed-size) array of TINY_TABLE__ROW_CAP elements (because Tiny_Table has no dynamic arrays and is fully in stack memory). 
        // There is no metadata for it , so if you use `for &pos, index in pos_table.rows` loop it will go through all eight elements.
        // To avoid this use `for i := 0; i < ecs.table_len(&pos_table); i += 1` loop instead.
        // 
        fmt.println("Using `for &pos, index in pos_table.rows` loop:")
        fmt.println("--------------------------------------------------------------")
        for &pos, index in pos_table.rows {
            eid := ecs.get_entity(&pos_table, index)

            if eid == human {
                fmt.println("Human: ", eid, pos)
            } else if eid == bird {
                fmt.println("Bird: ", eid, pos)
            }   
            else {
                fmt.println("Unknown entity: ", eid, pos)
            }   
        }

        fmt.println()
        
        fmt.println("Using `for i := 0; i < ecs.table_len(&pos_table); i += 1` loop:")
        fmt.println("--------------------------------------------------------------")
        // This loop is better because it goes only through valid components
        for i := 0; i < ecs.table_len(&pos_table); i += 1 {
            component := &pos_table.rows[i]
            eid := ecs.get_entity(&pos_table, i)

            if eid == human {
                fmt.println("Human: ", eid, component)
            } else if eid == bird {
                fmt.println("Bird: ", eid, component)
            }   
            else {
                fmt.println("Unknown entity: ", eid, component)
            }  
        }

        //
        // View on top of Tiny_Table, Table and Component_Table
        //

        // 
        // Table
        //

        health_table : ecs.Table(Health)  // Table !!!
        err = ecs.table__init(&health_table, &db, 20)
        if err != nil { report_error(err); return } 

        //
        // Compact_Table
        //
        inventory_table : ecs.Compact_Table(Inventory) // Compact_Table !!!
        err = ecs.compact_table__init(&inventory_table, &db, 5)
        if err != nil { report_error(err); return }     

        //
        // Create view on top of different table types
        //
        view: ecs.View
        err = ecs.view__init(&view, &db, {&pos_table, &health_table, &inventory_table}) // View on top of Tiny_Table, Table and Compact_Table !!!
        if err != nil { report_error(err); return }

        //
        // Add Health and Inventory components to human and bird entities
        //

        // Add Health component to human
        human_health: ^Health
        human_health, err = ecs.add_component(&health_table, human)
        if err != nil { report_error(err); return }
        human_health.hp = 100
        human_health.max_hp = 300

        // Add Inventory component to human
        human_inventory: ^Inventory
        human_inventory, err = ecs.add_component(&inventory_table, human)
        if err != nil { report_error(err); return }
        human_inventory.items[0][0] = Item_Type.Sword
        human_inventory.item_count = 1

        // Add Health component to bird
        bird_health: ^Health
        bird_health, err = ecs.add_component(&health_table, bird)
        if err != nil { report_error(err); return }
        bird_health.hp = 10
        bird_health.max_hp = 10

        // Add Inventory component to bird
        bird_inventory: ^Inventory  
        bird_inventory, err = ecs.add_component(&inventory_table, bird)
        if err != nil { report_error(err); return }
        bird_inventory.items[0][0] = Item_Type.Food
        bird_inventory.item_count = 1

        //
        // Rebuild view after adding components because Positions were added before view was created
        //

        ecs.view__rebuild(&view) 

        //
        // Iterate over view that includes Position(Tiny_Table), Health(Table) and Inventory(Compact_Table) components
        //

        it: ecs.Iterator
        err = ecs.iterator_init(&it, &view)   
        if err != nil { report_error(err); return }


        fmt.println()
        fmt.println("Iterating over view that includes Position(Tiny_Table), Health(Table) and Inventory(Compact_Table) components:") 
        fmt.println("--------------------------------------------------------------")
        for ecs.iterator_next(&it) {
            eid := ecs.get_entity(&it)  

            pos := ecs.get_component(&pos_table, &it)
            health := ecs.get_component(&health_table, &it)
            inventory := ecs.get_component(&inventory_table, &it)

            if eid == human {
                fmt.printfln("HUMAN id=%d position(x: %v, y: %v) health: %v/%v inventory: %v", eid.ix, pos.x, pos.y, health.hp, health.max_hp, inventory.items[0][0])
            } else if eid == bird {
               fmt.printfln("BIRD id=%d position(x: %v, y: %v) health: %v/%v inventory: %v", eid.ix, pos.x, pos.y, health.hp, health.max_hp, inventory.items[0][0])
            }   
            else {
                fmt.println("Unknown entity: ", eid, pos, health, inventory)
            }  
        }
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}




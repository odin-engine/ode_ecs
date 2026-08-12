/*
    2025 (c) Oleh, https://github.com/zm69

    In this example:
    - How to use Tiny_Table
    - How to use View on top of different table types (Tiny_Table, Table, and Compact_Table)
    - An example of a tags table
    - An example of a bool table
*/

package ode_ecs_sample4

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:log"
    import "core:mem"

// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// Components
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
        err: ecs.Error
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
        human, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        robot, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        // Two throwaway entities, just to increase the entity count
        _, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        _, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        bird, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        //
        // Tiny_Table
        //
        pos_table : ecs.Tiny_Table(Position)

        err = ecs.tiny_table__init(&pos_table, &db)
        if err != nil { report_error(err); return }

        //
        // Add components to human and bird entities
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
        // NOTE: Tiny_Table.rows is a fixed TINY_TABLE__ROW_CAP-size array with no length metadata,
        // so `for x in pos_table.rows` visits all eight slots regardless of how many are live.
        // Use `ecs.slice(&pos_table)` instead to get just the live prefix.
        //
        fmt.println("Using `for &pos, index in pos_table.rows` loop (the gotcha — visits all eight slots):")
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

        fmt.println("Using `for &pos, index in ecs.slice(&pos_table)` loop:")
        fmt.println("--------------------------------------------------------------")
        // Better: only visits valid components, and also avoids a codegen pitfall where reading
        // `.rows` directly in a hot loop compiles worse than a slice returned by value (see table__slice's doc comment).
        for &component, index in ecs.slice(&pos_table) {
            eid := ecs.get_entity(&pos_table, index)

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
        // View on top of Tiny_Table, Table, Tag_Table and Compact_Table
        //

        //
        // Table
        //
        health_table : ecs.Table(Health)
        err = ecs.table__init(&health_table, &db, 20)
        if err != nil { report_error(err); return }

        //
        // Tag_Table
        //
        is_alive_tag_table : ecs.Tag_Table
        err = ecs.tag_table__init(&is_alive_tag_table, &db, 20)
        if err != nil { report_error(err); return }

        //ecs.tag_table__terminate(&is_alive_tag_table)

        //
        // Compact_Table
        //
        inventory_table : ecs.Compact_Table(Inventory)
        err = ecs.compact_table__init(&inventory_table, &db, 5)
        if err != nil { report_error(err); return }

        view: ecs.View
        err = ecs.view__init(&view, &db, {&pos_table, &health_table, &inventory_table, &is_alive_tag_table})
        if err != nil { report_error(err); return }

        //
        // Add Health and Inventory components to human and bird entities
        //
        human_health: ^Health
        human_health, err = ecs.add_component(&health_table, human)
        if err != nil { report_error(err); return }
        human_health.hp = 100
        human_health.max_hp = 300

        err = ecs.add_tag(&is_alive_tag_table, human)
        if err != nil { report_error(err); return }

        human_inventory: ^Inventory
        human_inventory, err = ecs.add_component(&inventory_table, human)
        if err != nil { report_error(err); return }
        human_inventory.items[0][0] = Item_Type.Sword
        human_inventory.item_count = 1

        bird_health: ^Health
        bird_health, err = ecs.add_component(&health_table, bird)
        if err != nil { report_error(err); return }
        bird_health.hp = 10
        bird_health.max_hp = 10

        err = ecs.add_tag(&is_alive_tag_table, bird)
        if err != nil { report_error(err); return }

        bird_inventory: ^Inventory
        bird_inventory, err = ecs.add_component(&inventory_table, bird)
        if err != nil { report_error(err); return }
        bird_inventory.items[0][0] = Item_Type.Food
        bird_inventory.item_count = 1

        //
        // Rebuild view: Positions were added to pos_table before the view was created
        //
        ecs.view__rebuild(&view)
        //
        //

        it: ecs.Iterator
        err = ecs.iterator_init(&it, &view)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Iterating over view that is on top of Tiny_Table, Table, Compact_Table and Tag_Table tables:")
        fmt.println("--------------------------------------------------------------")
        for ecs.next(&it) {
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

        //
        // Another way to do tags: an enum component
        // 
        Player_State :: enum {
            Walking,
            Running,
            Flying,
            Stunned,
            Dead,
            Fighting,
        }

        tags_table : ecs.Table(Player_State)

        err = ecs.table_init(&tags_table, &db, 10)
        if err != nil { report_error(err); return }

        enum_comp : ^Player_State
        enum_comp, err = ecs.add_component(&tags_table, human)
        if err != nil { report_error(err); return }
        enum_comp^ = Player_State.Running

        enum_comp, err = ecs.add_component(&tags_table, bird)
        if err != nil { report_error(err); return }
        enum_comp^ = Player_State.Flying

        fmt.println()
        fmt.println("Iterate over tags_table:")
        fmt.println("--------------------------------------------------------------")
        for &tag, index in ecs.slice(&tags_table) {
            eid := ecs.get_entity(&tags_table, index)

            if eid == human {
                fmt.println("Human is", tag)
            } else if eid == bird {
                fmt.println("Bird is", tag)
            }
            else {
                fmt.println("Unknown entity is", tag)
            }
        }

        //
        // A bool table: usually better to use a struct so you can add fields later, but any type works
        // 
        bool_table : ecs.Table(bool)

        err = ecs.table_init(&bool_table, &db, 10)
        if err != nil { report_error(err); return }

        is_true : ^bool
        is_true, err = ecs.add_component(&bool_table, human)
        if err != nil { report_error(err); return }
        is_true^ = false

        is_true, err = ecs.add_component(&bool_table, bird)
        if err != nil { report_error(err); return }
        is_true^ = true
        fmt.println()
        fmt.println("Iterate over bool_table:")
        fmt.println("--------------------------------------------------------------")
        for &comp, index in ecs.slice(&bool_table) {
            eid := ecs.get_entity(&bool_table, index)

            if eid == human {
                fmt.println("Human is", comp)
            } else if eid == bird {
                fmt.println("Bird is", comp)
            }
            else {
                fmt.println("Unknown entity is", comp)
            }
        }

}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

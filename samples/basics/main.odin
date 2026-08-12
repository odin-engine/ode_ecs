/*
    2025 (c) Oleh, https://github.com/zm69
*/

package ode_ecs_basics

// Core
    import "core:fmt"

// ODE_ECS
    import ecs "../../"

//
// Components
//
    Position :: struct { x, y: int }
    AI :: struct { neurons_count: int }

//
// NOTE: purpose is to demonstrate basic functionality; errors are not handled here for brevity.
//
main :: proc() {

    //
    // Init ECS database
    //
    my_ecs: ecs.Database

    defer ecs.terminate(&my_ecs)
    ecs.init(&my_ecs, entities_cap=100)

    //
    // Init component tables
    // 
    // Tables/views are attached to a Database and auto-terminated with it, though manual termination is also possible.

    //
    positions : ecs.Table(Position)
    ais : ecs.Table(AI)

    ecs.table_init(&positions, &my_ecs, 10)
    ecs.table_init(&ais, &my_ecs, 10)

    //
    // Init view
    view: ecs.View
    ecs.view_init(&view, &my_ecs, {&ais, &positions})

    //
    // Create entity and add components
    //
    robot, _ := ecs.database__create_entity(&my_ecs)

    fmt.println("Robot entity:", robot)

    pos1, _ := ecs.add_component(&positions, robot)
    pos1.x = 67
    pos1.y = 43

    pos2 := ecs.get_component(&positions, robot)

    assert(pos1 == pos2)

    ai: ^AI
    ai, _ = ecs.add_component(&ais, robot)
    ai.neurons_count = 88

    //
    // Iterate over table
    eid: ecs.entity_id
    for &pos, index in ecs.slice(&positions) {
        eid = ecs.get_entity(&positions, index)
        ai = ecs.get_component(&ais, eid)

        fmt.println("Iterating over table: ", eid, pos, ai)
    }

    //
    // Iterate over view
    it: ecs.Iterator

    ecs.iterator_init(&it, &view)

    for eid, pos1, ai in ecs.next(&it, &positions, &ais) {
        fmt.println("Iterating over view: ", eid, pos1, ai)
    }

    fmt.println("Total memory usage:", ecs.memory_usage(&my_ecs), "bytes")
}


/*
    2025 (c) Oleh, https://github.com/zm69
*/

package ode_ecs_basics

// Core
    import "core:fmt"

// ODE_ECS
    import ecs "../../src"

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
    robot, _ := ecs.create_entity(&my_ecs)

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
    pos_dense := ecs.slice(&positions)
    pos_eids := ecs.entities_slice(&positions)
    for i in 0..<len(pos_dense) {
        eid := pos_eids[i]
        ai = ecs.get_component(&ais, eid)

        fmt.println("Iterating over table: ", eid, pos_dense[i], ai)
    }

    //
    // Iterate over view
    pos_slice := ecs.slice(&view, Position)
    ai_slice := ecs.slice(&view, AI)
    view_eids := ecs.entities_slice(&view)

    for i in 0..<len(pos_slice) {
        fmt.println("Iterating over view: ", view_eids[i], pos_slice[i], ai_slice[i])
    }

    fmt.println("Total memory usage:", ecs.memory_usage(&my_ecs), "bytes")
}


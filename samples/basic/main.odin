/*
    2025 (c) Oleh, https://github.com/zm69
*/

package ode_ecs_basics

// Core
    import "core:fmt"
    import "core:mem"
    import "core:slice"

// ODE_ECS
    import ecs "../../"

//
// Components
//

    Position :: struct { x, y: int } 
    AI :: struct { neurons_count: int }

//
// NOTE: The purpose of this sample is to demonstrate basic functionality. 
// To keep the code less verbose, we are not handling errors in this example. 
// All non-trivial procedures can return errors.
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
    // Note: Tables and views do not need to be terminated manually as they are attached to a Database
    // and will be automatically terminated when the Database is terminated. However, you can still 
    // manually terminate tables and views if necessary.
    //
    
    positions : ecs.Table(Position)
    ais : ecs.Table(AI)

    ecs.table_init(&positions, &my_ecs, 10)
    ecs.table_init(&ais, &my_ecs, 10)

    //
    // Init view
    //

    view: ecs.View
    ecs.view_init(&view, &my_ecs, {&ais, &positions})

    //
    // Create entity and add components
    //

    robot, _ := ecs.create_entity(&my_ecs) 

    fmt.println("Robot entity:", robot)

    // Assign one component from table to entity
    pos1, _ := ecs.add_component(&positions, robot)
    pos1.x = 67
    pos1.y = 43

    // Get existing component from table for entity
    pos2, _ := ecs.get_component(&positions, robot)

    assert(pos1 == pos2)

    // Add ai component
    ai: ^AI // AI component
    ai, _ = ecs.add_component(&ais, robot)
    ai.neurons_count = 88

    //
    // Iterate over table
    // 

    eid: ecs.entity_id
    for &pos, index in positions.records {
        // Get entity with component index
        eid = ecs.get_entity(&positions, index)

        // Get other component with entity
        ai, _ = ecs.get_component(&ais, eid) 

        fmt.println("Iterating over table: ", eid, pos, ai)
    }

    //
    // Iterate over view
    //

    it: ecs.Iterator

    ecs.iterator_init(&it, &view)

    for ecs.iterator_next(&it) {
        // Get entity with iterator
        eid = ecs.get_entity(&it)

        // Get Position component with iterator
        pos1 = ecs.get_component(&positions, &it)

        // Get AI component with iterator
        ai = ecs.get_component(&ais, &it)

        fmt.println("Iterating over view: ", eid, pos1, ai)
    }

    fmt.println("Total memory usage:", ecs.memory_usage(&my_ecs), "bytes")
}



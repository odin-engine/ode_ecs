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
// NOTE: Purpose of this sample is to show basic functionality and we are not handling 
// errors in this example to make code less verbose. All non-trivial procs can return errors.
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
    // Note: We don't need to terminate tables and views, they are attached to a Database 
    // and will be automatically terminated when Database is terminated. You can still manually
    // terminate tables and views if you need.
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

    for ecs.iterator__next(&it) {
        // Get entity with iterator
        eid = ecs.get_entity(&it)

        // Get Position component with iterator
        pos1 = ecs.get_component(&positions, &it)

        // Get AI component with iterator
        ai = ecs.get_component(&ais, &it)

        fmt.println("Iterating over view: ", eid, pos1, ai)
    }

    fmt.println("Total memory usage:", ecs.memory_usage(&my_ecs), "bytes")

    a: bit_set[0..<ecs.BIT_SET_VALUES_CAP]
    b: bit_set[0..<ecs.BIT_SET_VALUES_CAP]
    c: bit_set[0..<ecs.BIT_SET_VALUES_CAP]

    a += {66}
    a += {5}
    a += {99}

    b += {1}
    b += {5}
    b += {99}
    b += {44}
    b += {66}

    c += {100}
    c += {5}
    c += {109}

    // c = {}


    fmt.println(a <= b)
    fmt.println(c & b == {})
}



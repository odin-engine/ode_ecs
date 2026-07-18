/*
    2026 (c) Oleh, https://github.com/zm69

    Group example.

    A Group takes exclusive ownership of a set of Tables and keeps the entities
    that have ALL owned components packed in the aligned prefix [0, group_len)
    of every owned table, at the same row index in each. Iterating that prefix
    is the fastest way to process a partial-overlap entity set — no lookups,
    just parallel dense arrays.
*/

package ode_ecs_sample07

// Core
    import "core:fmt"
    import "core:log"
    import "core:mem"

// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// Components
//

    Position :: struct { x, y: f32 }
    Velocity :: struct { dx, dy: f32 }

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
        err: ecs.Error

        db: ecs.Database

        defer {
            err = ecs.terminate(&db)
            if err != nil do report_error(err)
        }

        err = ecs.init(&db, entities_cap=100, allocator=allocator)
        if err != nil { report_error(err); return }

        positions: ecs.Table(Position)
        velocities: ecs.Table(Velocity)

        err = ecs.table_init(&positions, &db, 100)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&velocities, &db, 100)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Create a Group that owns both tables.
    //
    // Only the general-purpose Table type can be owned, and each Table can have
    // at most one owner. From now on the group keeps every entity that has
    // BOTH components in the aligned prefix of both tables automatically.
    //
        group: ecs.Group

        err = ecs.group_init(&group, &db, {&positions, &velocities})
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // 10 entities: all get Position, every second one also gets Velocity.
    //
        eids: [10]ecs.entity_id

        for i in 0..<10 {
            eids[i], err = ecs.create_entity(&db)
            if err != nil { report_error(err); return }

            pos: ^Position
            pos, err = ecs.add_component(&positions, eids[i])
            if err != nil { report_error(err); return }
            pos^ = Position{ x = f32(i), y = 0 }

            if i % 2 == 0 {
                vel: ^Velocity
                vel, err = ecs.add_component(&velocities, eids[i])
                if err != nil { report_error(err); return }
                vel^ = Velocity{ dx = 1, dy = f32(i) }
            }
        }

        fmt.println("Entities with Position:", ecs.table_len(&positions))
        fmt.println("Entities with Velocity:", ecs.table_len(&velocities))
        fmt.println("Group size (Position AND Velocity):", ecs.group_len(&group))

    ///////////////////////////////////////////////////////////////////////////////
    // Iterate the group: both slices are aligned — index i in one is the same
    // entity as index i in the other. This is a plain array walk, no lookups.
    //
        pos_slice := ecs.group_dense_slice(&group, &positions)
        vel_slice := ecs.group_dense_slice(&group, &velocities)

        for i in 0..<ecs.group_len(&group) {
            pos_slice[i].x += vel_slice[i].dx
            pos_slice[i].y += vel_slice[i].dy
        }

        fmt.println()
        fmt.println("After one movement step:")
        for i in 0..<ecs.group_len(&group) {
            fmt.println("  entity", ecs.get_entity(&positions, i), "pos =", pos_slice[i])
        }

    ///////////////////////////////////////////////////////////////////////////////
    // Membership is maintained automatically by the add/remove paths.
    //
        // eids[1] had no Velocity — adding one puts it into the group
        _, err = ecs.add_component(&velocities, eids[1])
        if err != nil { report_error(err); return }
        fmt.println()
        fmt.println("After adding Velocity to entity 1, group size:", ecs.group_len(&group))

        // removing a Velocity takes the entity out again
        err = ecs.remove_component(&velocities, eids[0])
        if err != nil { report_error(err); return }
        fmt.println("After removing Velocity from entity 0, group size:", ecs.group_len(&group))

    ///////////////////////////////////////////////////////////////////////////////
    // pause_packing / resume_packing on a Group.
    //
    // While packing is paused rows must not move, so membership changes only
    // mark the group dirty; group_dense_slice returns nil until the group is
    // rebuilt by resume_packing.
    //
        err = ecs.pause_packing(&group)
        if err != nil { report_error(err); return }

        err = ecs.remove_component(&velocities, eids[2])
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("While paused (group is dirty, dense slice unavailable):")
        fmt.println("  group_dense_slice == nil:", ecs.group_dense_slice(&group, &positions) == nil)

        err = ecs.resume_packing(&group) // packs the tables and rebuilds the group
        if err != nil { report_error(err); return }

        fmt.println("After resume_packing, group size:", ecs.group_len(&group))
        fmt.println("  group_dense_slice == nil:", ecs.group_dense_slice(&group, &positions) == nil)
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

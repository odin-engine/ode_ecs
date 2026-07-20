/*
    2026 (c) Oleh, https://github.com/zm69

    Overbase example.

    Overbase is a shareable entity ID space: one or more Databases can attach
    to the same Overbase (instead of each owning its own) so that the same
    entity_id refers to the same logical entity across all of them, while each
    Database still keeps its own independent set of component tables/views.

    Here, world_ecs (gameplay: Position/Velocity) and render_ecs (Sprite) share
    one Overbase. Entity lifecycle is fully owned by Overbase: destroying an
    entity through either Database removes its components from BOTH before the
    id is freed for reuse — a recycled index never resurfaces stale data in a
    Database that wasn't told the old entity died. See docs/overbase.md.
*/

package ode_ecs_sample12

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
    Sprite   :: struct { texture_id: int }

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

    ///////////////////////////////////////////////////////////////////////////////
    // One shared Overbase (databases_cap = max number of Databases that will
    // attach to it — preallocated, like everything else in ODE_ECS).
    //
        overbase: ecs.Overbase

        // Databases must be terminated before the Overbase they share — defer
        // the Overbase's termination FIRST so it runs LAST (defers are LIFO).
        defer {
            err = ecs.overbase_terminate(&overbase)
            if err != nil do report_error(err)
        }

        err = ecs.overbase_init(&overbase, entities_cap=10, databases_cap=2, allocator=allocator)
        if err != nil { report_error(err); return }

        world_ecs, render_ecs: ecs.Database

        defer {
            err = ecs.terminate(&render_ecs)
            if err != nil do report_error(err)
        }
        defer {
            err = ecs.terminate(&world_ecs)
            if err != nil do report_error(err)
        }

        // allocator omitted -> falls back to overbase's allocator
        err = ecs.init_from_overbase(&world_ecs, &overbase)
        if err != nil { report_error(err); return }
        err = ecs.init_from_overbase(&render_ecs, &overbase)
        if err != nil { report_error(err); return }

        positions: ecs.Table(Position)
        velocities: ecs.Table(Velocity)
        err = ecs.table_init(&positions, &world_ecs, 10)
        if err != nil { report_error(err); return }
        err = ecs.table_init(&velocities, &world_ecs, 10)
        if err != nil { report_error(err); return }

        sprites: ecs.Table(Sprite)
        err = ecs.table_init(&sprites, &render_ecs, 10)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Create an entity through the Overbase — it doesn't belong to either
    // Database yet, just to the shared id space. Add components to it in each
    // Database independently.
    //
        robot, cerr := ecs.create_entity(&overbase)
        if cerr != nil { report_error(cerr); return }

        pos: ^Position
        pos, err = ecs.add_component(&positions, robot)
        if err != nil { report_error(err); return }
        pos^ = Position{ 10, 20 }

        vel: ^Velocity
        vel, err = ecs.add_component(&velocities, robot)
        if err != nil { report_error(err); return }
        vel^ = Velocity{ 1, 0 }

        spr: ^Sprite
        spr, err = ecs.add_component(&sprites, robot)
        if err != nil { report_error(err); return }
        spr^ = Sprite{ texture_id = 42 }

        fmt.println("robot:", robot)
        fmt.println("  known to world_ecs: ", ecs.is_expired(&world_ecs, robot) == false)
        fmt.println("  known to render_ecs:", ecs.is_expired(&render_ecs, robot) == false)
        fmt.println("  Position:", ecs.get_component(&positions, robot)^)
        fmt.println("  Sprite:  ", ecs.get_component(&sprites, robot)^)

    ///////////////////////////////////////////////////////////////////////////////
    // Destroy through world_ecs only — the shared Overbase still cleans up
    // render_ecs's Sprite for the same entity, so a recycled index never
    // resurfaces stale render data on a future entity.
    //
        err = ecs.destroy_entity(&world_ecs, robot)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("After destroy_entity(&world_ecs, robot):")
        fmt.println("  expired in world_ecs: ", ecs.is_expired(&world_ecs, robot))
        fmt.println("  expired in render_ecs:", ecs.is_expired(&render_ecs, robot))
        fmt.println("  render_ecs still has Sprite for robot:", ecs.has_component(&sprites, robot))

        fmt.println()
        fmt.println("Total memory usage:", ecs.memory_usage(&world_ecs) + ecs.memory_usage(&render_ecs), "bytes")
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

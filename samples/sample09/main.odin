/*
    2026 (c) Oleh, https://github.com/zm69

    Command_Buffer example.

    Structural changes (destroying entities, adding/removing components) are
    not allowed while iterating a View — rows would move under the iterator.
    A Command_Buffer records those changes during iteration into preallocated
    memory and applies them all at once at a sync point with replay().
*/

package ode_ecs_sample09

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
    Health :: struct { hp: int }

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
        cb: ecs.Command_Buffer

        defer {
            err = ecs.terminate(&db)
            if err != nil do report_error(err)
        }
        // Command_Buffer is not owned by the Database — terminate it yourself
        defer {
            err = ecs.command_buffer_terminate(&cb)
            if err != nil do report_error(err)
        }

        err = ecs.init(&db, entities_cap=100, allocator=allocator)
        if err != nil { report_error(err); return }

        positions: ecs.Table(Position)
        healths: ecs.Table(Health)
        view: ecs.View

        err = ecs.table_init(&positions, &db, 100)
        if err != nil { report_error(err); return }
        err = ecs.table_init(&healths, &db, 100)
        if err != nil { report_error(err); return }
        err = ecs.view_init(&view, &db, {&positions, &healths})
        if err != nil { report_error(err); return }

        // Preallocate the buffer: up to 64 commands, 1 KB of component payload
        err = ecs.command_buffer_init(&cb, &db, commands_cap=64, payload_cap=1024)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // 6 entities with Position + Health, some already "dead".
    //
        for i in 0..<6 {
            eid: ecs.entity_id
            eid, err = ecs.create_entity(&db)
            if err != nil { report_error(err); return }

            pos: ^Position
            pos, err = ecs.add_component(&positions, eid)
            if err != nil { report_error(err); return }
            pos^ = Position{ x = f32(i), y = 0 }

            health: ^Health
            health, err = ecs.add_component(&healths, eid)
            if err != nil { report_error(err); return }
            health.hp = i % 3 == 0 ? 0 : 100 // entities 0 and 3 are at 0 hp
        }

        fmt.println("Before replay:", ecs.view_len(&view), "entities in the view")

    ///////////////////////////////////////////////////////////////////////////////
    // Iterate the view and RECORD changes instead of applying them.
    //
    // The database is untouched while recording, so the iterator stays valid.
    // (create_entity is iteration-safe and stays immediate; only its components
    // go through the buffer.)
    //
        spawned: ecs.entity_id

        it: ecs.Iterator
        err = ecs.iterator_init(&it, &view)
        if err != nil { report_error(err); return }

        for ecs.iterator_next(&it) {
            eid := ecs.get_entity(&it)
            health := ecs.get_component(&healths, &it)

            // "kill" entities that are at 0 hp — deferred until replay
            if health.hp <= 0 {
                err = ecs.cmd_destroy_entity(&cb, eid)
                if err != nil { report_error(err); return }

                // spawn a replacement: the component value is copied into the
                // buffer NOW and written into the table at replay
                spawned, err = ecs.create_entity(&db)
                if err != nil { report_error(err); return }
                err = ecs.cmd_add_component(&cb, &positions, spawned, Position{ x = -1, y = -1 })
                if err != nil { report_error(err); return }
                err = ecs.cmd_add_component(&cb, &healths, spawned, Health{ hp = 100 })
                if err != nil { report_error(err); return }
            }
        }

        fmt.println("Recorded", ecs.command_buffer_len(&cb), "commands; view still has", ecs.view_len(&view), "entities")

    ///////////////////////////////////////////////////////////////////////////////
    // Sync point: apply all commands in recorded order, then clear the buffer.
    //
    // replay returns how many commands were skipped (e.g. a command that
    // targeted an entity destroyed by an earlier command).
    //
        skipped: int
        skipped, err = ecs.replay(&cb)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("After replay (skipped:", skipped, "):")
        fmt.println("  view:", ecs.view_len(&view), "entities (2 destroyed, 2 spawned)")
        fmt.println("  buffer cleared:", ecs.command_buffer_len(&cb) == 0)

        spawned_health := ecs.get_component(&healths, spawned)
        fmt.println("  last spawned entity hp:", spawned_health.hp)
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

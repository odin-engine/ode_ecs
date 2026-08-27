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
    import ecs "../../src"
    import oc "../../src/ode_core"

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

        context.allocator = oc.mem_track__init(&mem_track, context.allocator)
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track)

        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
            health.hp = i % 3 == 0 ? 0 : 100
        }

        fmt.println("Before replay:", ecs.view_len(&view), "entities in the view")

    ///////////////////////////////////////////////////////////////////////////////
    // Iterate the view and RECORD changes instead of applying them.
    //
        spawned: ecs.entity_id

        health_slice := ecs.slice(&view, Health)
        view_eids := ecs.entities_slice(&view)

        for i in 0..<len(health_slice) {
            eid := view_eids[i]
            health := health_slice[i]

            if health.hp <= 0 {
                err = ecs.cmd_destroy_entity(&cb, eid)
                if err != nil { report_error(err); return }

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

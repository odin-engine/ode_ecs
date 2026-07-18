/*
    2026 (c) Oleh, https://github.com/zm69

    Multithreading example — the patterns from F.A.Q. question 1 ("Thread safety?").

    The ODE_ECS core is deliberately lock-free: baking locks into every call is
    exactly the kind of hidden cost the library avoids. Instead, parallelize at
    a higher level where synchronization amortizes to zero:

    1. PHASE SEPARATION — run read/compute systems in parallel, then apply all
       structural changes (create/destroy/add/remove) in a single-threaded
       sync point. The parallel phase touches no shared mutable bookkeeping.

    2. DATA-PARALLEL ITERATION — iterator_init(it, view, start_row, end_row)
       exists precisely for processing a View in disjoint batches.

    3. ONE DATABASE PER THREAD — for fully independent workloads; databases
       share nothing.

    This sample shows all three. For pattern 1 each worker records structural
    changes into its OWN Command_Buffer during the parallel phase (recording
    only writes into the buffer's preallocated memory, so per-thread buffers
    are race-free), and the main thread replays them at the sync point.
*/

package ode_ecs_sample11

// Core
    import "core:fmt"
    import "core:log"
    import "core:mem"
    import "core:thread"

// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// Components
//

    Position :: struct { x, y: f32 }
    Velocity :: struct { dx, dy: f32 }

//
// Part 1: shared Database — parallel compute phase + single-threaded sync point
//

    ENTITIES_COUNT :: 1000
    N_WORKERS :: 4
    WORLD_BOUND :: 50.0 // entities crossing this are destroyed at the sync point

    Worker :: struct {
        // read-only during the parallel phase
        view: ^ecs.View,
        positions: ^ecs.Table(Position),
        velocities: ^ecs.Table(Velocity),
        start_row, end_row: int, // this worker's disjoint batch of view rows

        // owned exclusively by this worker
        cb: ecs.Command_Buffer, // structural changes are recorded, not applied
        processed: int,
        out_of_bounds: int,
        err: ecs.Error,
    }

    // The parallel phase. Every view row belongs to exactly one worker, so
    // writing to a row's components is race-free. Reading shared state (the
    // view, the tables' layout) is safe because nothing mutates it — all
    // structural changes are deferred into per-worker command buffers.
    worker_proc :: proc(w: ^Worker) {
        it: ecs.Iterator
        w.err = ecs.iterator_init(&it, w.view, w.start_row, w.end_row)
        if w.err != nil do return

        for ecs.iterator_next(&it) {
            pos := ecs.get_component(w.positions, &it)
            vel := ecs.get_component(w.velocities, &it)

            pos.x += vel.dx
            pos.y += vel.dy

            if pos.x > WORLD_BOUND {
                // NOT ecs.destroy_entity — a structural change would mutate
                // shared bookkeeping mid-iteration; record it instead
                w.err = ecs.cmd_destroy_entity(&w.cb, ecs.get_entity(&it))
                if w.err != nil do return
                w.out_of_bounds += 1
            }

            w.processed += 1
        }
    }

//
// Part 2: one Database per thread — nothing is shared, so each thread may do
// everything, including structural changes.
//

    Region :: struct {
        name: string,
        entities_created: int,
        entities_destroyed: int,
        final_len: int,
        ok: bool,
    }

    region_proc :: proc(r: ^Region) {
        // This thread has a fresh default context; the database below lives
        // and dies entirely on this thread.
        db: ecs.Database
        monsters: ecs.Table(Position)

        if ecs.init(&db, entities_cap=100) != nil do return
        defer ecs.terminate(&db)

        if ecs.table_init(&monsters, &db, 100) != nil do return

        eids: [20]ecs.entity_id
        err: ecs.Error
        for i in 0..<20 {
            eids[i], err = ecs.create_entity(&db)
            if err != nil do return
            _, err = ecs.add_component(&monsters, eids[i])
            if err != nil do return
            r.entities_created += 1
        }

        // structural changes are fine here — no other thread can see this db
        for i := 0; i < 20; i += 4 {
            if ecs.destroy_entity(&db, eids[i]) != nil do return
            r.entities_destroyed += 1
        }

        r.final_len = ecs.entities_len(&db)
        r.ok = true
    }

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
        // no allocations happen outside of provided allocator.
        // (Worker threads are unaffected: each thread starts with its own
        // fresh default context.)
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

        err = ecs.init(&db, entities_cap=ENTITIES_COUNT, allocator=allocator)
        if err != nil { report_error(err); return }

        positions: ecs.Table(Position)
        velocities: ecs.Table(Velocity)
        view: ecs.View

        err = ecs.table_init(&positions, &db, ENTITIES_COUNT)
        if err != nil { report_error(err); return }
        err = ecs.table_init(&velocities, &db, ENTITIES_COUNT)
        if err != nil { report_error(err); return }
        err = ecs.view_init(&view, &db, {&positions, &velocities})
        if err != nil { report_error(err); return }

        for i in 0..<ENTITIES_COUNT {
            eid: ecs.entity_id
            eid, err = ecs.create_entity(&db)
            if err != nil { report_error(err); return }

            pos: ^Position
            pos, err = ecs.add_component(&positions, eid)
            if err != nil { report_error(err); return }
            pos^ = Position{ x = f32(i % 100), y = 0 }

            vel: ^Velocity
            vel, err = ecs.add_component(&velocities, eid)
            if err != nil { report_error(err); return }
            vel^ = Velocity{ dx = f32(i % 7), dy = 1 }
        }

        fmt.println("Part 1: phase separation over one shared Database")
        fmt.println("  entities in view:", ecs.view_len(&view))

    ///////////////////////////////////////////////////////////////////////////////
    // Split the view into disjoint batches, one per worker. Each worker also
    // gets its own Command_Buffer — sized for the worst case: every entity of
    // its batch destroyed.
    //
        workers: [N_WORKERS]Worker

        batch := ecs.view_len(&view) / N_WORKERS
        for &w, i in workers {
            w.view = &view
            w.positions = &positions
            w.velocities = &velocities
            w.start_row = i * batch
            // last worker takes the remainder rows
            w.end_row = i == N_WORKERS - 1 ? ecs.view_len(&view) : (i + 1) * batch

            err = ecs.command_buffer_init(&w.cb, &db, commands_cap=batch*2, payload_cap=64)
            if err != nil { report_error(err); return }
        }
        defer for &w in workers {
            err = ecs.command_buffer_terminate(&w.cb)
            if err != nil do report_error(err)
        }

    ///////////////////////////////////////////////////////////////////////////////
    // Parallel phase: compute only, no structural changes anywhere.
    //
        // core:thread allocates the Thread handles from context.allocator,
        // so restore the real allocator for the threading part of the sample
        // (mem_track still verifies they are all freed by thread.destroy)
        context.allocator = allocator

        threads: [N_WORKERS]^thread.Thread
        for &w, i in workers {
            threads[i] = thread.create_and_start_with_poly_data(&w, worker_proc)
        }
        for t in threads {
            thread.join(t)
            thread.destroy(t)
        }

        total_processed := 0
        total_recorded := 0
        for &w, i in workers {
            if w.err != nil { report_error(w.err); return }
            fmt.println("  worker", i, "rows [", w.start_row, ",", w.end_row, ") processed:", w.processed,
                " recorded destroys:", w.out_of_bounds)
            total_processed += w.processed
            total_recorded += ecs.command_buffer_len(&w.cb)
        }

        fmt.println("  batches were disjoint and complete:", total_processed == ecs.view_len(&view))
        fmt.println("  view untouched by the parallel phase:", ecs.view_len(&view) == ENTITIES_COUNT)

    ///////////////////////////////////////////////////////////////////////////////
    // Sync point: back on the main thread, apply all recorded structural
    // changes. Only now do entities actually get destroyed.
    //
        for &w in workers {
            _, err = ecs.replay(&w.cb)
            if err != nil { report_error(err); return }
        }

        fmt.println()
        fmt.println("  after sync point:")
        fmt.println("    destroys applied:", total_recorded)
        fmt.println("    entities in view:", ecs.view_len(&view))
        fmt.println("    view shrank by exactly the recorded amount:",
            ecs.view_len(&view) == ENTITIES_COUNT - total_recorded)

    ///////////////////////////////////////////////////////////////////////////////
    // Part 2: one Database per thread — fully independent workloads, nothing
    // shared, so no phases and no coordination are needed at all.
    //
        regions := [2]Region{ { name = "north" }, { name = "south" } }

        rthreads: [2]^thread.Thread
        for &r, i in regions {
            rthreads[i] = thread.create_and_start_with_poly_data(&r, region_proc)
        }
        for t in rthreads {
            thread.join(t)
            thread.destroy(t)
        }

        fmt.println()
        fmt.println("Part 2: one independent Database per thread")
        for &r in regions {
            if !r.ok { fmt.println("  region", r.name, "failed"); return }
            fmt.println("  region", r.name, ": created", r.entities_created,
                ", destroyed", r.entities_destroyed, ", final entities:", r.final_len)
        }
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

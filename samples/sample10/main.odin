/*
    2026 (c) Oleh, https://github.com/zm69

    Serialization example.

    A whole Database can be snapshotted into a binary buffer (zero allocations
    during serialize) or saved to a file, and later loaded into any Database
    initialized with the SAME schema: same tables, same init order, same
    component types, capacities no smaller than the saved data.

    Components must be POD — no pointers, slices, strings or maps inside
    (rows are copied as raw bytes).
*/

package ode_ecs_sample10

// Core
    import "core:fmt"
    import "core:log"
    import "core:mem"
    import "core:os"

// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// Components
//

    Position :: struct { x, y: f32 }

//
// Shared schema: init order matters, table ids of the source and the target
// databases must coincide.
//
World :: struct {
    db: ecs.Database,
    positions: ecs.Table(Position),
    is_alive: ecs.Tag_Table,
}

world__init :: proc(w: ^World, allocator: mem.Allocator) -> ecs.Error {
    ecs.init(&w.db, entities_cap=100, allocator=allocator) or_return
    ecs.table_init(&w.positions, &w.db, 100) or_return
    ecs.tag_table__init(&w.is_alive, &w.db, 100) or_return
    return nil
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
        // no allocations happen outside of provided allocator
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

    //
    // Actual ODE_ECS sample starts here.
    //
        err: ecs.Error

        a: World // source
        b: World // in-memory round-trip target
        c: World // file round-trip target

        defer {
            err = ecs.terminate(&a.db)
            if err != nil do report_error(err)
            err = ecs.terminate(&b.db)
            if err != nil do report_error(err)
            err = ecs.terminate(&c.db)
            if err != nil do report_error(err)
        }

        err = world__init(&a, allocator)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Build some state in world A.
    //
        eids: [5]ecs.entity_id
        for i in 0..<5 {
            eids[i], err = ecs.create_entity(&a.db)
            if err != nil { report_error(err); return }

            pos: ^Position
            pos, err = ecs.add_component(&a.positions, eids[i])
            if err != nil { report_error(err); return }
            pos^ = Position{ x = f32(i * 10), y = f32(i) }
        }
        err = ecs.add_tag(&a.is_alive, eids[0])
        if err != nil { report_error(err); return }
        err = ecs.add_tag(&a.is_alive, eids[2])
        if err != nil { report_error(err); return }

        // saved entity_ids stay valid after load — generations round-trip too
        err = ecs.destroy_entity(&a.db, eids[4])
        if err != nil { report_error(err); return }

        fmt.println("World A:", ecs.entities_len(&a.db), "entities,",
            ecs.table_len(&a.positions), "positions,", ecs.table_len(&a.is_alive), "alive tags")

    ///////////////////////////////////////////////////////////////////////////////
    // In-memory round trip: serialized_size → serialize → deserialize.
    //
        size: int
        size, err = ecs.serialized_size(&a.db)
        if err != nil { report_error(err); return }

        buf := make([]byte, size, allocator)
        defer delete(buf, allocator)

        written: int
        written, err = ecs.serialize(&a.db, buf) // zero allocations
        if err != nil { report_error(err); return }
        fmt.println()
        fmt.println("Serialized", written, "bytes")

        err = world__init(&b, allocator) // same schema, same init order
        if err != nil { report_error(err); return }

        err = ecs.deserialize(&b.db, buf)
        if err != nil { report_error(err); return }

        pos_b := ecs.get_component(&b.positions, eids[2])
        fmt.println("World B (from buffer): entity 2 position =", pos_b^,
            ", alive =", ecs.has_tag(&b.is_alive, eids[2]))
        fmt.println("World B: destroyed entity stayed destroyed:", ecs.is_expired(&b.db, eids[4]))

    ///////////////////////////////////////////////////////////////////////////////
    // File round trip: save_to_file → load_from_file.
    //
        path :: "sample10.snap" // cwd-relative; removed below
        defer os.remove(path)

        err = ecs.save_to_file(&a.db, path, allocator)
        if err != nil { report_error(err); return }

        err = world__init(&c, allocator)
        if err != nil { report_error(err); return }

        err = ecs.load_from_file(&c.db, path, allocator)
        if err != nil { report_error(err); return }

        pos_c := ecs.get_component(&c.positions, eids[2])
        fmt.println()
        fmt.println("World C (from", path, "): entity 2 position =", pos_c^,
            ", alive =", ecs.has_tag(&c.is_alive, eids[2]))
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

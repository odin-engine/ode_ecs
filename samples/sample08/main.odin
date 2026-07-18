/*
    2026 (c) Oleh, https://github.com/zm69

    Relations (parent/child) example.

    Relations_Table adds parent/child relations between entities: every entity
    can have at most one parent and any number of children. All memory is
    preallocated at init; set/remove/re-parent are O(1). Relations are not
    components — they never affect Views.
*/

package ode_ecs_sample08

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

    Transform :: struct { x, y: f32 }

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

    ///////////////////////////////////////////////////////////////////////////////
    // Attach a Relations_Table (at most one per Database).
    //
    // cap = max number of concurrent parent links (child→parent edges).
    // The table is terminated automatically with the database.
    //
        rt: ecs.Relations_Table

        err = ecs.relations_init(&rt, &db, cap=100)
        if err != nil { report_error(err); return }

        transforms: ecs.Table(Transform)
        err = ecs.table_init(&transforms, &db, 100)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // A ship with two turrets.
    //
        ship, turret1, turret2: ecs.entity_id

        ship, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }
        turret1, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }
        turret2, err = ecs.create_entity(&db)
        if err != nil { report_error(err); return }

        for eid in ([]ecs.entity_id{ship, turret1, turret2}) {
            t: ^Transform
            t, err = ecs.add_component(&transforms, eid)
            if err != nil { report_error(err); return }
            t^ = Transform{ 10, 20 }
        }

        err = ecs.set_parent(&db, turret1, ship) // make `ship` the parent of `turret1`
        if err != nil { report_error(err); return }
        err = ecs.set_parent(&db, turret2, ship)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Query the hierarchy.
    //
        parent, perr := ecs.parent_of(&db, turret1)
        if perr != nil { report_error(perr); return }
        fmt.println("Parent of turret1 is ship:", parent == ship)

        count, cerr := ecs.children_count(&db, ship)
        if cerr != nil { report_error(cerr); return }
        fmt.println("Ship has", count, "children")

        is_child, icerr := ecs.is_child_of(&db, turret2, ship)
        if icerr != nil { report_error(icerr); return }
        fmt.println("turret2 is a child of ship:", is_child)

        // children_of returns a slice of an internal buffer — use it immediately,
        // don't store it across other relation calls
        children, cherr := ecs.children_of(&db, ship)
        if cherr != nil { report_error(cherr); return }

        fmt.println()
        fmt.println("Move the ship: all direct children follow")
        for child in children {
            t := ecs.get_component(&transforms, child)
            t.x += 5
            fmt.println("  child", child, "moved to", t^)
        }

    ///////////////////////////////////////////////////////////////////////////////
    // Unlink and destroy.
    //
        // Re-parenting is one call — the previous link is replaced (O(1)).
        // Removing a link:
        err = ecs.unparent(&db, turret1) // alias: ecs.remove_parent
        if err != nil { report_error(err); return }

        count, cerr = ecs.children_count(&db, ship)
        if cerr != nil { report_error(cerr); return }
        fmt.println()
        fmt.println("After unparenting turret1, ship has", count, "child(ren)")

        // destroy_entity(.., destroy_children=true) destroys the whole subtree;
        // by default children survive and just lose their parent link
        err = ecs.destroy_entity(&db, ship, destroy_children=true)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("After destroying ship with destroy_children=true:")
        fmt.println("  ship expired:   ", ecs.is_expired(&db, ship))
        fmt.println("  turret2 expired:", ecs.is_expired(&db, turret2), "(was still a child)")
        fmt.println("  turret1 expired:", ecs.is_expired(&db, turret1), "(was unparented, survives)")
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

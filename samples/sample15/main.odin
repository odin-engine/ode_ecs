/*
    2026 (c) Oleh, https://github.com/zm69

    Relations hierarchy walk example.

    is_root / roots / walk_subtree / walk_hierarchy are read-only traversal
    helpers on top of Relations_Table, always parent-before-child order —
    the same order destroy_entity(.., destroy_children=true) relies on
    internally (reversed, to destroy deepest-first), exposed here for
    reading instead. See sample08 for the basic set_parent/children_of API.
*/

package ode_ecs_sample15

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

    Transform :: struct { x, y: f32 }

main :: proc() {

    //
    // OPTIONAL: Setup memory tracking and logger.
    //
        mem_track: oc.Mem_Track

        context.allocator = oc.mem_track__init(&mem_track, context.allocator)
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track) // Defers run in reverse declaration order

        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        // Panic allocator ensures no allocations happen outside the provided allocator
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

        rt: ecs.Relations_Table
        err = ecs.relations_init(&rt, &db, cap=100)
        if err != nil { report_error(err); return }

        transforms: ecs.Table(Transform)
        err = ecs.table_init(&transforms, &db, 100)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // A small two-root forest:
    //   hq   <- {squad_a, squad_b}; squad_a <- {soldier1, soldier2}
    //   base <- {vehicle1}
    //
        hq, squad_a, squad_b, soldier1, soldier2, base, vehicle1: ecs.entity_id

        for e in ([]^ecs.entity_id{&hq, &squad_a, &squad_b, &soldier1, &soldier2, &base, &vehicle1}) {
            e^, err = ecs.create_entity(&db)
            if err != nil { report_error(err); return }
            t: ^Transform
            t, err = ecs.add_component(&transforms, e^)
            if err != nil { report_error(err); return }
            t^ = Transform{ 0, 0 }
        }

        for link in ([][2]ecs.entity_id{ {squad_a, hq}, {squad_b, hq}, {soldier1, squad_a}, {soldier2, squad_a}, {vehicle1, base} }) {
            err = ecs.set_parent(&db, link[0], link[1])
            if err != nil { report_error(err); return }
        }

    ///////////////////////////////////////////////////////////////////////////////
    // is_root: no parent AND at least one child (an entity that never touched
    // relations at all is not a root, just untouched).
    //
        for e in ([]ecs.entity_id{hq, squad_a, base}) {
            is_r, ierr := ecs.is_root(&db, e)
            if ierr != nil { report_error(ierr); return }
            fmt.println("is_root:", e, "->", is_r)
        }

    ///////////////////////////////////////////////////////////////////////////////
    // roots: every root in the table, in one call — no need to already have a
    // specific entity handle in hand, unlike is_root/is_child_of.
    //
        roots, rerr := ecs.roots(&db)
        if rerr != nil { report_error(rerr); return }
        fmt.println()
        fmt.println(len(roots), "roots:", roots, "(hq and base)")

    ///////////////////////////////////////////////////////////////////////////////
    // walk_subtree: descendants of ONE root, breadth-first (children before
    // grandchildren) — root itself is not included, same convention as
    // children_of returning only children, not the parent. Cheaper than
    // walk_hierarchy below when you already have a specific root in hand and
    // don't need per-level boundaries.
    //
        desc, derr := ecs.walk_subtree(&db, hq)
        if derr != nil { report_error(derr); return }
        fmt.println()
        fmt.println("hq's descendants, breadth-first (squad_a/squad_b in some order, then soldier1/soldier2):", desc)

    ///////////////////////////////////////////////////////////////////////////////
    // walk_hierarchy: the WHOLE forest, breadth-first, with level boundaries —
    // discovers every root itself (see roots() above), so it's a materially
    // different (and more expensive) traversal than repeated walk_subtree
    // calls. Process one full depth level at a time, e.g. to propagate a
    // transform update top-down (a parent's move applied to its children
    // before their own children, level by level).
    //
        entities, levels, werr := ecs.walk_hierarchy(&db)
        if werr != nil { report_error(werr); return }

        fmt.println()
        fmt.println("Whole-forest walk,", len(levels) - 1, "levels:")
        for lvl := 0; lvl < len(levels) - 1; lvl += 1 {
            level := entities[levels[lvl]:levels[lvl + 1]]
            fmt.println("  level", lvl, ":", level)

            // Propagate a transform nudge from each entity's already-updated
            // parent — safe precisely because this level's parents (the
            // previous level) were already processed.
            for e in level {
                p, perr := ecs.parent_of(&db, e)
                if perr != nil { report_error(perr); return }
                if p.ix == ecs.DELETED_INDEX do continue // root: nothing to inherit from

                parent_t := ecs.get_component(&transforms, p)
                t := ecs.get_component(&transforms, e)
                t.x = parent_t.x + 1
                t.y = parent_t.y + 1
            }
        }

        fmt.println()
        fmt.println("Final transforms (each descendant inherited + nudged from its parent):")
        for e in ([]ecs.entity_id{hq, squad_a, soldier1, base, vehicle1}) {
            fmt.println("  ", e, "->", ecs.get_component(&transforms, e)^)
        }
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

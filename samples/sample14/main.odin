/*
    2026 (c) Oleh, https://github.com/zm69

    Arch_Table (Archetype Table) example.

    An Arch_Table is ODE_ECS's archetype-style table: a single struct holding N
    component columns that share ONE row index, so every column of a row moves
    together as one unit — contrast with the sparse-dense tables (Table,
    Compact_Table, Tiny_Table, Tag_Table), where each component type lives in
    its own independently-allocated table.

    This sample shows:
    1. Basic Arch_Table usage: init, whole-row create/add/remove, get_component,
       and iterating with Arch_Iterator's ecs.next(&it, T1, T2, ...) sugar.
    2. Mixing an Arch_Table into a View alongside a regular Table.
    3. Mixing an Arch_Table into a Group alongside a regular Table.
*/

package ode_ecs_sample14

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
    Health   :: struct { hp, max_hp: int }

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

        // Replace default allocator with a panic allocator to make sure that
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

        err = ecs.init(&db, entities_cap = 100, allocator = allocator)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Part 1: Arch_Table basics
    //
    // units holds Position AND Velocity in one struct — no per-component
    // add/remove, an entity either has the whole row or none of it.
    //
        fmt.println("=== Part 1: Arch_Table basics ===")
        fmt.println()

        units: ecs.Arch_Table
        err = ecs.arch_table__init(&units, &db, cap = 100, component_types = {Position, Velocity})
        if err != nil { report_error(err); return }

        // ecs.create_entity(&units) allocates the entity id AND its archetype
        // row in one call
        eids: [5]ecs.entity_id
        for i in 0..<5 {
            eids[i], err = ecs.create_entity(&units)
            if err != nil { report_error(err); return }

            pos := ecs.get_component(&units, eids[i], Position)
            pos.x = f32(i)
            pos.y = 0

            vel := ecs.get_component(&units, eids[i], Velocity)
            vel.dx = 1
            vel.dy = f32(i)
        }

        fmt.println("units row count:", ecs.table_len(&units))

        // Arch_Iterator + the ecs.next(&it, T1, T2, ...) sugar: types are bound
        // once at arch_iterator_init, then supplied again per next() call (up
        // to 7 columns). Column indices are resolved once and cached.
        it: ecs.Arch_Iterator
        err = ecs.arch_iterator_init(&it, &units)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Iterating units with Arch_Iterator (one movement step):")
        for eid, pos, vel in ecs.next(&it, Position, Velocity) {
            pos.x += vel.dx
            pos.y += vel.dy
            fmt.println("  entity", eid, "pos =", pos^)
        }

        // whole-row remove: eids[2] leaves the archetype entirely
        err = ecs.arch_table__remove_entity(&units, eids[2])
        if err != nil { report_error(err); return }
        fmt.println()
        fmt.println("After removing entity 2 from units, row count:", ecs.table_len(&units))
        fmt.println("  has_component(units, eids[2]):", ecs.has_component(&units, eids[2]))

    ///////////////////////////////////////////////////////////////////////////////
    // Part 2: Mixing an Arch_Table into a View, alongside a regular Table
    //
    // View membership works the same regardless of table kind: an entity
    // needs a row in every included table. Arch_Table columns are read
    // manually (iterator_next + get_component(&arch, &it, $T)) since they are
    // not part of the Table($T)-only ecs.iterate/ecs.next(&it, &t1, ...) sugar.
    //
        fmt.println()
        fmt.println("=== Part 2: Arch_Table mixed into a View ===")
        fmt.println()

        healths: ecs.Table(Health)
        err = ecs.table_init(&healths, &db, 100)
        if err != nil { report_error(err); return }

        // give Health to a subset of the surviving units (0, 1, 3) so the view
        // (Health AND units) only matches those
        idx_with_health := [3]int{0, 1, 3}
        for i in idx_with_health {
            h: ^Health
            h, err = ecs.add_component(&healths, eids[i])
            if err != nil { report_error(err); return }
            h.hp = 100
            h.max_hp = 100
        }

        view: ecs.View
        err = ecs.view_init(&view, &db, {&healths, &units})
        if err != nil { report_error(err); return }

        // Health and units rows already existed before the view was created,
        // so it needs one explicit rebuild to pick them up — a view created
        // BEFORE its data exists stays up to date automatically from then on.
        err = ecs.rebuild(&view)
        if err != nil { report_error(err); return }

        fmt.println("View size (Health AND units):", ecs.view_len(&view))

        view_it: ecs.Iterator
        err = ecs.iterator_init(&view_it, &view)
        if err != nil { report_error(err); return }

        for ecs.next(&view_it) {
            eid := ecs.get_entity(&view_it)
            h := ecs.get_component(&healths, &view_it)
            pos := ecs.get_component(&units, &view_it, Position)
            fmt.println("  entity", eid, "hp =", h.hp, "pos =", pos^)
        }

    ///////////////////////////////////////////////////////////////////////////////
    // Part 3: Mixing an Arch_Table into a Group, alongside a regular Table
    //
    // A Group can own a mix of Table and Arch_Table: an Arch_Table's whole row
    // counts as membership in every one of its columns at once, and a single
    // arch_table__swap_rows call moves every owned column together — compare
    // with owning N separate Tables, which pays one swap per owned column.
    //
        fmt.println()
        fmt.println("=== Part 3: Arch_Table mixed into a Group ===")
        fmt.println()

        group: ecs.Group
        err = ecs.group_init(&group, &db, {&healths, &units})
        if err != nil { report_error(err); return }

        fmt.println("Group size (Health AND units):", ecs.group_len(&group))

        health_slice := ecs.slice(&group, &healths)
        pos_slice := ecs.slice(&group, &units, Position)
        vel_slice := ecs.slice(&group, &units, Velocity)

        fmt.println("Group slices (aligned — index i is the same entity in all three):")
        for i in 0..<ecs.group_len(&group) {
            eid := ecs.get_entity(&healths, i) // any owned table agrees on the entity at row i
            fmt.println("  entity", eid, "hp =", health_slice[i].hp, "pos =", pos_slice[i], "vel =", vel_slice[i])
        }

        // removing the entity's row from either owned table leaves the group
        err = ecs.arch_table__remove_entity(&units, eids[1])
        if err != nil { report_error(err); return }
        fmt.println()
        fmt.println("After removing entity 1 from units, group size:", ecs.group_len(&group))
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

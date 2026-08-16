/*
    2026 (c) Oleh, https://github.com/zm69

    Component enable/disable example.

    A soft, bitset-based toggle that temporarily excludes a component from
    View matching WITHOUT moving or losing the stored value — the opposite of
    remove_component/add_component, which is a real structural change (tail
    swap + re-zero). See docs/tables.md#component-enable-disable and
    tests/component_enable_disable_test.odin.
*/

package ode_ecs_sample17

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
    Radar_Signature :: struct { signal: int }

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

        positions: ecs.Table(Position)
        radar: ecs.Table(Radar_Signature)

        err = ecs.table_init(&positions, &db, 100)
        if err != nil { report_error(err); return }
        err = ecs.table_init(&radar, &db, 100)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Setup: a targeting View needs both components to acquire a lock. A
    // render_group also owns both tables, packing them into an aligned dense
    // prefix for the render/physics pipeline — kept separate on purpose, to
    // contrast against disable/enable below.
    //
        targeting: ecs.View
        err = ecs.view_init(&targeting, &db, {&positions, &radar})
        if err != nil { report_error(err); return }

        render_group: ecs.Group
        err = ecs.group_init(&render_group, &db, {&positions, &radar})
        if err != nil { report_error(err); return }

        hero, enemy1, enemy2: ecs.entity_id

        for e in ([]^ecs.entity_id{&hero, &enemy1, &enemy2}) {
            e^, err = ecs.create_entity(&db)
            if err != nil { report_error(err); return }

            pos: ^Position
            pos, err = ecs.add_component(&positions, e^)
            if err != nil { report_error(err); return }
            pos^ = Position{ x = 0, y = 0 }

            sig: ^Radar_Signature
            sig, err = ecs.add_component(&radar, e^)
            if err != nil { report_error(err); return }
            sig^ = Radar_Signature{ signal = 42 }
        }

        fmt.println("Setup — targeting view:", ecs.view_len(&targeting), " render_group:", ecs.group_len(&render_group))

    ///////////////////////////////////////////////////////////////////////////////
    // Cloak activated: disable_component evicts enemy1 from any View that
    // includes `radar`, but never touches the render_group — a Group's dense
    // prefix is physical row position, not bitset-based, so it never reacts
    // to disable/enable.
    //
        err = ecs.disable_component(&radar, enemy1)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Cloak activated (disable_component on enemy1's radar signature):")
        fmt.println("  is_component_disabled(enemy1):", ecs.is_component_disabled(&radar, enemy1))
        fmt.println("  targeting view (enemy1 dropped out):", ecs.view_len(&targeting))
        fmt.println("  render_group (unaffected — dense prefix is row position, not bits):", ecs.group_len(&render_group))

    ///////////////////////////////////////////////////////////////////////////////
    // Data untouched: disabling never moves or zeroes the stored value.
    //
        sig := ecs.get_component(&radar, enemy1)
        fmt.println()
        fmt.println("Data untouched while disabled:")
        fmt.println("  get_component(enemy1).signal:", sig.signal, " has_component(enemy1):", ecs.has_component(&radar, enemy1))

    ///////////////////////////////////////////////////////////////////////////////
    // Decloak: enable_component re-enters every View that now matches again.
    //
        err = ecs.enable_component(&radar, enemy1)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Decloaked (enable_component):")
        fmt.println("  is_component_disabled(enemy1):", ecs.is_component_disabled(&radar, enemy1))
        fmt.println("  targeting view (enemy1 re-entered):", ecs.view_len(&targeting))

    ///////////////////////////////////////////////////////////////////////////////
    // Caveats — not demonstrated with fake calls, just documented: enable/
    // disable_component is not recordable in a Command_Buffer and is not
    // included in serialization snapshots. See docs/tables.md#component-enable-disable.
    //
        fmt.println()
        fmt.println("Not shown above (unsupported by design): Command_Buffer recording and")
        fmt.println("serialization snapshots do not carry disabled/enabled state — see")
        fmt.println("docs/tables.md#component-enable-disable.")
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

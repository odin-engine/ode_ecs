/*
    2026 (c) Oleh, https://github.com/zm69

    Pair_Table (many-to-many relations) example.

    A runnable companion to docs/pair_table.md and tests/pair_table_test.odin,
    not a restatement of either — this uses a directional "guard protects VIP"
    relation instead of the doc's "likes" example. Unlike Relations_Table's
    single-parent tree (see sample08/sample15), a Pair_Table holder can point
    at any number of targets, and a target can be pointed at by any number of
    holders.
*/

package ode_ecs_sample16

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

    Protection :: struct { priority: int }

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

        assignments: ecs.Pair_Table(Protection)
        err = ecs.pair_init(&assignments, &db, holders_cap=10, pairs_cap=20)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Setup: three guards, three VIPs. alpha protects both king and queen —
    // many-to-many, unlike Relations_Table's one-parent tree.
    //
        alpha, beta, gamma, king, queen, diplomat: ecs.entity_id

        for e in ([]^ecs.entity_id{&alpha, &beta, &gamma, &king, &queen, &diplomat}) {
            e^, err = ecs.create_entity(&db)
            if err != nil { report_error(err); return }
        }

        _, err = ecs.pair_add(&assignments, alpha, king, Protection{priority=1})
        if err != nil { report_error(err); return }
        _, err = ecs.pair_add(&assignments, alpha, queen, Protection{priority=2})
        if err != nil { report_error(err); return }
        _, err = ecs.pair_add(&assignments, beta, king, Protection{priority=1})
        if err != nil { report_error(err); return }
        _, err = ecs.pair_add(&assignments, gamma, diplomat, Protection{priority=1})
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Idempotent add: re-adding an existing (holder, target) pair is a no-op —
    // the payload is NOT overwritten. beta has only one pair, so first_data
    // below is guaranteed to be the (beta, king) row.
    //
        _, err = ecs.pair_add(&assignments, beta, king, Protection{priority=99})
        if err != nil { report_error(err); return }

        fmt.println("Re-adding beta->king with priority=99 is a no-op:")
        fmt.println("  has_pair(beta, king):", ecs.pair_has_pair(&assignments, beta, king))
        beta_data, _ := ecs.pair_first_data(&assignments, beta)
        fmt.println("  beta's priority for king is still 1, not 99:", beta_data.priority)

    ///////////////////////////////////////////////////////////////////////////////
    // Queries: first_target/first_data are O(1) (head of the holder's linked
    // list, most-recently-added — not a stable choice among several); targets_of
    // is O(#pairs for that holder), returning every target at once.
    //
        fmt.println()
        fmt.println("Queries:")
        fmt.println("  has_pair(alpha, king):", ecs.pair_has_pair(&assignments, alpha, king))
        fmt.println("  has_any(gamma):", ecs.pair_has_any(&assignments, gamma))

        alpha_target, _ := ecs.pair_first_target(&assignments, alpha)
        fmt.println("  first_target(alpha):", alpha_target, "(most-recently-added: queen)")

        alpha_targets, terr := ecs.pair_targets_of(&assignments, alpha)
        if terr != nil { report_error(terr); return }
        fmt.println("  targets_of(alpha):", alpha_targets, "(king and queen)")

    ///////////////////////////////////////////////////////////////////////////////
    // View integration: `presence` is a real Tag_Table with one row per holder
    // that has >= 1 pair — {&assignments.presence} works directly in
    // view_init's includes/excludes/any_of, zero extra View code.
    //
        off_duty: ecs.Tag_Table
        err = ecs.tag_table__init(&off_duty, &db, 10)
        if err != nil { report_error(err); return }

        err = ecs.tag(&off_duty, gamma)
        if err != nil { report_error(err); return }

        on_duty: ecs.View
        err = ecs.view_init(&on_duty, &db, {&assignments.presence}, excludes = {&off_duty})
        if err != nil { report_error(err); return }

        // Pairs/tags already existed before on_duty was created, so populate it
        // once (a view created up front would instead stay live automatically,
        // as it does for the rest of this sample after this point).
        err = ecs.rebuild(&on_duty)
        if err != nil { report_error(err); return }

        it: ecs.Iterator
        err = ecs.iterator_init(&it, &on_duty)
        if err != nil { report_error(err); return }

        alpha_on, beta_on, gamma_on := false, false, false
        for ecs.next(&it) {
            eid := ecs.get_entity(&it)
            if eid == alpha do alpha_on = true
            if eid == beta do beta_on = true
            if eid == gamma do gamma_on = true
        }
        fmt.println()
        fmt.println("on_duty view (has a pair AND not off-duty):")
        fmt.println("  alpha:", alpha_on, " beta:", beta_on, " gamma:", gamma_on, "(gamma has a pair but is off-duty)")

        err = ecs.untag(&off_duty, gamma)
        if err != nil { report_error(err); return }

        err = ecs.iterator_reset(&it)
        if err != nil { report_error(err); return }
        alpha_on, beta_on, gamma_on = false, false, false
        for ecs.next(&it) {
            eid := ecs.get_entity(&it)
            if eid == alpha do alpha_on = true
            if eid == beta do beta_on = true
            if eid == gamma do gamma_on = true
        }
        fmt.println("After untagging gamma as off-duty (auto-updated, no rebuild):")
        fmt.println("  alpha:", alpha_on, " beta:", beta_on, " gamma:", gamma_on)

    ///////////////////////////////////////////////////////////////////////////////
    // Automatic cleanup when a pair's target is destroyed — no explicit
    // pair_remove call needed either way. destroy_entity walks only the
    // destroyed entity's OWN pair rows (via the target-side linked list), so
    // this costs nothing for entities that never appear in any Pair_Table.
    //
        err = ecs.destroy_entity(&db, queen) // one of alpha's TWO targets
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Destroyed queen (one of alpha's two targets):")
        fmt.println("  has_pair(alpha, queen):", ecs.pair_has_pair(&assignments, alpha, queen))
        alpha_targets2, terr2 := ecs.pair_targets_of(&assignments, alpha)
        if terr2 != nil { report_error(terr2); return }
        fmt.println("  targets_of(alpha):", alpha_targets2, "(king only now)")

        err = ecs.iterator_reset(&it)
        if err != nil { report_error(err); return }
        alpha_on = false
        for ecs.next(&it) {
            eid := ecs.get_entity(&it)
            if eid == alpha do alpha_on = true
        }
        fmt.println("  alpha still on_duty (still has a pair):", alpha_on)

        err = ecs.destroy_entity(&db, diplomat) // gamma's ONLY target
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Destroyed diplomat (gamma's only target):")
        fmt.println("  has_any(gamma):", ecs.pair_has_any(&assignments, gamma))

        err = ecs.iterator_reset(&it)
        if err != nil { report_error(err); return }
        gamma_on = false
        for ecs.next(&it) {
            eid := ecs.get_entity(&it)
            if eid == gamma do gamma_on = true
        }
        fmt.println("  gamma auto-evicted from on_duty (no explicit pair_remove call):", !gamma_on)

    ///////////////////////////////////////////////////////////////////////////////
    // Explicit remove / remove_all.
    //
        err = ecs.pair_remove(&assignments, alpha, king) // alpha's last remaining pair
        if err != nil { report_error(err); return }
        fmt.println()
        fmt.println("Removed alpha's last pair (king) -> has_any(alpha):", ecs.pair_has_any(&assignments, alpha))

        err = ecs.pair_remove_all(&assignments, beta) // beta's only pair, via the bulk API
        if err != nil { report_error(err); return }
        fmt.println("remove_all(beta) -> has_any(beta):", ecs.pair_has_any(&assignments, beta))

        fmt.println("on_duty view is now empty:", ecs.view_len(&on_duty) == 0)
        fmt.println("total live pairs:", ecs.pair_table__len(&assignments))

        fmt.println()
        fmt.println("Command_Buffer recording (cmd_pair_add/cmd_pair_remove) and full")
        fmt.println("serialization round-trips are documented in docs/pair_table.md and")
        fmt.println("demonstrated generally in Sample09 (Command_Buffer) / Sample10 (serialization).")
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

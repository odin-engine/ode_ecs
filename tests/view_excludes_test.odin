/*
    2025 (c) Oleh, https://github.com/zm69

    View `excludes` and `refilter` tests.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs ".."

///////////////////////////////////////////////////////////////////////////////
// Components

    XHealth :: struct { hp: int }
    XArmor :: struct { armor: int }

///////////////////////////////////////////////////////////////////////////////
// Helpers

    @(private="file")
    view_has_entity :: proc(view: ^ecs.View, eid: ecs.entity_id) -> bool {
        it: ecs.Iterator
        if ecs.iterator_init(&it, view) != nil do return false
        for ecs.iterator_next(&it) {
            if ecs.get_entity(&it) == eid do return true
        }
        return false
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    // Basic excludes: include one Table, exclude a Tag_Table. Membership must
    // follow add_tag/remove_tag automatically, and rebuild must respect excludes.
    @(test)
    view_excludes__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // no allocations outside provided allocator

            db: ecs.Database
            healths: ecs.Table(XHealth)
            stunned: ecs.Tag_Table
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&stunned, &db, 10) == nil)

            // Same table in includes and excludes is rejected
            testing.expect(t, ecs.view_init(&view, &db, {&healths}, excludes={&healths}) == ecs.API_Error.Table_Cannot_Be_Included_And_Excluded)

            testing.expect(t, ecs.view_init(&view, &db, {&healths}, excludes={&stunned}) == nil)
            defer ecs.view_terminate(&view)

            e1, err1 := ecs.create_entity(&db)
            e2, err2 := ecs.create_entity(&db)
            e3, err3 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil && err2 == nil && err3 == nil)

            for eid in ([]ecs.entity_id{e1, e2, e3}) {
                _, err := ecs.add_component(&healths, eid)
                testing.expect(t, err == nil)
            }

            testing.expect(t, ecs.view_len(&view) == 3)

            // Tagging moves the entity out of the view...
            testing.expect(t, ecs.add_tag(&stunned, e2) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)
            testing.expect(t, !view_has_entity(&view, e2))
            testing.expect(t, !ecs.view_components_match(&view, e2))

            // ...and untagging moves it back in.
            testing.expect(t, ecs.remove_tag(&stunned, e2) == nil)
            testing.expect(t, ecs.view_len(&view) == 3)
            testing.expect(t, view_has_entity(&view, e2))

            // rebuild goes through the same match — excludes respected
            testing.expect(t, ecs.add_tag(&stunned, e1) == nil)
            testing.expect(t, ecs.rebuild(&view) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)
            testing.expect(t, !view_has_entity(&view, e1))

            // Destroying a tagged (excluded) entity must not resurrect it in the view
            testing.expect(t, ecs.destroy_entity(&db, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)

            // Destroying a member removes it
            testing.expect(t, ecs.destroy_entity(&db, e3) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, view_has_entity(&view, e2))
    }

    // Excludes across the other table variants: Compact_Table and Tiny_Table.
    @(test)
    view_excludes_variants__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(XHealth)
            armors: ecs.Compact_Table(XArmor)
            marks: ecs.Tiny_Table(XArmor)
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.compact_table__init(&armors, &db, 4) == nil)
            testing.expect(t, ecs.tiny_table__init(&marks, &db) == nil)

            testing.expect(t, ecs.view_init(&view, &db, {&healths}, excludes={&armors, &marks}) == nil)
            defer ecs.view_terminate(&view)

            e1, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)

            _, err := ecs.add_component(&healths, e1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.view_len(&view) == 1)

            // Compact_Table exclude
            _, err = ecs.add_component(&armors, e1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.view_len(&view) == 0)

            testing.expect(t, ecs.remove_component(&armors, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, view_has_entity(&view, e1))

            // Tiny_Table exclude
            _, err = ecs.add_component(&marks, e1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.view_len(&view) == 0)

            testing.expect(t, ecs.remove_component(&marks, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)

            // Both at once: removing only one keeps the entity excluded
            _, err = ecs.add_component(&armors, e1)
            testing.expect(t, err == nil)
            _, err = ecs.add_component(&marks, e1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.view_len(&view) == 0)

            testing.expect(t, ecs.remove_component(&marks, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 0) // still has armor

            testing.expect(t, ecs.remove_component(&armors, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
    }

    // Destroying an entity removes its components in table-id order. Here the
    // excluded table has the LOWER id, so its component goes first — without the
    // destroying_eid_ix guard the dying entity would transiently enter the view
    // (and its filter would observe a half-destroyed entity).
    @(test)
    view_excludes_destroy_order__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            stuns: ecs.Table(XArmor)    // id 0 — excluded, removed first on destroy
            healths: ecs.Table(XHealth) // id 1 — included
            view: ecs.View

            Observed :: struct {
                dying: ecs.entity_id,
                saw_dying: bool,
            }
            observed: Observed

            spy_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil) -> bool {
                data := (^Observed)(user_data)
                if data != nil && ecs.get_entity(row) == data.dying do data.saw_dying = true
                return true
            }

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&stuns, &db, 10) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, int(stuns.id) < int(healths.id))

            view.user_data = &observed
            testing.expect(t, ecs.view_init(&view, &db, {&healths}, spy_filter, excludes={&stuns}) == nil)
            defer ecs.view_terminate(&view)

            e1, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)

            _, err := ecs.add_component(&healths, e1)
            testing.expect(t, err == nil)
            _, err = ecs.add_component(&stuns, e1)
            testing.expect(t, err == nil)

            testing.expect(t, ecs.view_len(&view) == 0) // excluded

            observed.dying = e1
            observed.saw_dying = false

            testing.expect(t, ecs.destroy_entity(&db, e1) == nil)

            testing.expect(t, ecs.view_len(&view) == 0)
            testing.expect(t, !observed.saw_dying) // filter never saw the dying entity
    }

    // Terminating an excluded table invalidates the view; the same view struct can
    // then be terminated and re-init'd (issue #8) without stale exclude_bits.
    @(test)
    view_excludes_terminate_reinit__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(XHealth)
            stunned: ecs.Tag_Table
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&stunned, &db, 10) == nil)

            testing.expect(t, ecs.view_init(&view, &db, {&healths}, excludes={&stunned}) == nil)

            // Terminating the excluded table invalidates the view
            testing.expect(t, ecs.tag_table__terminate(&stunned) == nil)
            testing.expect(t, view.state == ecs.Object_State.Invalid)

            // Re-init the same structs; the view now has NO excludes — stale
            // exclude_bits from the previous life must not leak in.
            testing.expect(t, ecs.view_terminate(&view) == nil)
            testing.expect(t, ecs.tag_table__init(&stunned, &db, 10) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&healths}) == nil)
            defer ecs.view_terminate(&view)

            e1, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)

            _, err := ecs.add_component(&healths, e1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.add_tag(&stunned, e1) == nil)

            // Tagged, but this view no longer excludes the tag table
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, view_has_entity(&view, e1))
    }

    // refilter: one sweep after bulk mutations removes rows that stopped matching
    // and adds candidates that now match.
    @(test)
    view_refilter__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(XHealth)
            view: ecs.View
            view_no_filter: ecs.View

            alive_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil) -> bool {
                healths := (^ecs.Table(XHealth))(user_data)
                return ecs.get_component(healths, row).hp > 0
            }

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)

            view.user_data = &healths
            testing.expect(t, ecs.view_init(&view, &db, {&healths}, alive_filter) == nil)
            defer ecs.view_terminate(&view)

            testing.expect(t, ecs.view_init(&view_no_filter, &db, {&healths}) == nil)
            defer ecs.view_terminate(&view_no_filter)

            eids: [5]ecs.entity_id
            hps := [5]int{1, 0, 2, 0, 3}
            for i in 0..<5 {
                err: ecs.Error
                eids[i], err = ecs.create_entity(&db)
                testing.expect(t, err == nil)

                health, herr := ecs.add_component(&healths, eids[i])
                testing.expect(t, herr == nil)
                health.hp = hps[i]
                // hp was set after the add notification (filter saw hp == 0) —
                // re-evaluate this entity, exercising the rerun proc group
                testing.expect(t, ecs.rerun_views_filters(&healths, eids[i]) == nil)
            }

            // Filter re-ran after hp was set: only hp > 0 entities entered
            testing.expect(t, ecs.view_len(&view) == 3)
            testing.expect(t, ecs.view_len(&view_no_filter) == 5)

            // Bulk mutation — the view does not notice by itself
            ecs.get_component(&healths, eids[0]).hp = 0 // member drops out
            ecs.get_component(&healths, eids[1]).hp = 5 // non-member comes in
            ecs.get_component(&healths, eids[3]).hp = 7 // non-member comes in
            testing.expect(t, ecs.view_len(&view) == 3)

            testing.expect(t, ecs.refilter(&view) == nil)

            testing.expect(t, ecs.view_len(&view) == 4)
            testing.expect(t, !view_has_entity(&view, eids[0]))
            testing.expect(t, view_has_entity(&view, eids[1]))
            testing.expect(t, view_has_entity(&view, eids[2]))
            testing.expect(t, view_has_entity(&view, eids[3]))
            testing.expect(t, view_has_entity(&view, eids[4]))

            // No-filter view: refilter is a no-op
            testing.expect(t, ecs.refilter(&view_no_filter) == nil)
            testing.expect(t, ecs.view_len(&view_no_filter) == 5)

            // Everything drops out
            for eid in eids do ecs.get_component(&healths, eid).hp = 0
            testing.expect(t, ecs.refilter(&view) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)

            // And back in
            for eid in eids do ecs.get_component(&healths, eid).hp = 1
            testing.expect(t, ecs.refilter(&view) == nil)
            testing.expect(t, ecs.view_len(&view) == 5)
    }

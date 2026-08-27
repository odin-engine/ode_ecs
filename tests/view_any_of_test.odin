/*
    2026 (c) Oleh, https://github.com/zm69

    View `any_of` (OR) tests. Completes the AND (`includes`) / NOT (`excludes`) / OR
    (`any_of`) trio of structural query combinators — see docs/view.md.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Components

    OHealth :: struct { hp: int }
    OArmor :: struct { armor: int }

///////////////////////////////////////////////////////////////////////////////
// Helpers

    @(private="file")
    any_of_view_has_entity :: proc(view: ^ecs.View, eid: ecs.entity_id) -> bool {
        it: ecs.Iterator
        if ecs.iterator_init(&it, view) != nil do return false
        for ecs.iterator_next(&it) {
            if ecs.get_entity(&it) == eid do return true
        }
        return false
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    // Basic OR: entity must have at least one of two any_of tables. Membership
    // follows add/remove of either, and eviction only happens when the LAST
    // matching any_of table's component is removed (not on every removal).
    @(test)
    view_any_of__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // no allocations outside provided allocator

            db: ecs.Database
            healths: ecs.Table(OHealth)
            enemy: ecs.Tag_Table
            boss: ecs.Tag_Table
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&enemy, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&boss, &db, 10) == nil)

            // Same table in includes and any_of is rejected
            testing.expect(t, ecs.view_init(&view, &db, {&healths}, any_of={&healths}) == ecs.API_Error.Table_Cannot_Be_Included_And_Any_Of)

            testing.expect(t, ecs.view_init(&view, &db, {&healths}, any_of={&enemy, &boss}) == nil)
            defer ecs.view_terminate(&view)

            e1, err1 := ecs.create_entity(&db)
            e2, err2 := ecs.create_entity(&db)
            e3, err3 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil && err2 == nil && err3 == nil)

            for eid in ([]ecs.entity_id{e1, e2, e3}) {
                _, err := ecs.add_component(&healths, eid)
                testing.expect(t, err == nil)
            }

            // None of them are enemy or boss yet — any_of is not vacuously true
            testing.expect(t, ecs.view_len(&view) == 0)

            testing.expect(t, ecs.add_tag(&enemy, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, any_of_view_has_entity(&view, e1))

            testing.expect(t, ecs.add_tag(&boss, e2) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)

            // e3 gets BOTH tags — still just one membership, no double-add error
            testing.expect(t, ecs.add_tag(&enemy, e3) == nil)
            testing.expect(t, ecs.add_tag(&boss, e3) == nil)
            testing.expect(t, ecs.view_len(&view) == 3)

            // Removing one of e3's two any_of tags must NOT evict it — it still
            // matches via the other one.
            testing.expect(t, ecs.remove_tag(&enemy, e3) == nil)
            testing.expect(t, ecs.view_len(&view) == 3)
            testing.expect(t, any_of_view_has_entity(&view, e3))

            // Removing the last matching any_of tag evicts it.
            testing.expect(t, ecs.remove_tag(&boss, e3) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)
            testing.expect(t, !any_of_view_has_entity(&view, e3))

            // e1 loses its only any_of tag — evicted.
            testing.expect(t, ecs.remove_tag(&enemy, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, any_of_view_has_entity(&view, e2))

            // Losing the AND-required table evicts regardless of any_of.
            testing.expect(t, ecs.remove_component(&healths, e2) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)
    }

    // any_of across the other table variants (Compact_Table, Tiny_Table), and
    // excludes+any_of overlap on the same table is allowed (not a contradiction).
    @(test)
    view_any_of_variants_and_excludes_overlap__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(OHealth)
            armors: ecs.Compact_Table(OArmor)
            marks: ecs.Tiny_Table(OArmor)
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.compact_table__init(&armors, &db, 4) == nil)
            testing.expect(t, ecs.tiny_table__init(&marks, &db) == nil)

            // excludes and any_of both referencing `marks` is allowed
            testing.expect(t, ecs.view_init(&view, &db, {&healths}, excludes={&marks}, any_of={&armors, &marks}) == nil)
            defer ecs.view_terminate(&view)

            e1, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)

            _, err := ecs.add_component(&healths, e1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.view_len(&view) == 0) // no any_of table yet

            // Compact_Table any_of
            _, err = ecs.add_component(&armors, e1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.view_len(&view) == 1)

            // Tiny_Table is in both excludes and any_of — excludes wins (NOT is
            // still checked and takes priority, same as includes/excludes today)
            _, err = ecs.add_component(&marks, e1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.view_len(&view) == 0)

            testing.expect(t, ecs.remove_component(&marks, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1) // still has armor (any_of)

            testing.expect(t, ecs.remove_component(&armors, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)
    }

    // Combined AND + NOT + OR in one view, and view__rebuild/refilter consistency.
    @(test)
    view_any_of_combined_and_rebuild__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(OHealth)
            dead: ecs.Tag_Table
            enemy: ecs.Tag_Table
            boss: ecs.Tag_Table
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&dead, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&enemy, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&boss, &db, 10) == nil)

            // AND healths, NOT dead, OR (enemy | boss)
            testing.expect(t, ecs.view_init(&view, &db, {&healths}, excludes={&dead}, any_of={&enemy, &boss}) == nil)
            defer ecs.view_terminate(&view)

            e1, _ := ecs.create_entity(&db) // healths + enemy -> member
            e2, _ := ecs.create_entity(&db) // healths + boss + dead -> excluded
            e3, _ := ecs.create_entity(&db) // healths only -> not any_of

            for eid in ([]ecs.entity_id{e1, e2, e3}) {
                _, err := ecs.add_component(&healths, eid)
                testing.expect(t, err == nil)
            }
            testing.expect(t, ecs.add_tag(&enemy, e1) == nil)
            testing.expect(t, ecs.add_tag(&boss, e2) == nil)
            testing.expect(t, ecs.add_tag(&dead, e2) == nil)

            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, any_of_view_has_entity(&view, e1))

            // rebuild must reach the exact same membership from scratch
            testing.expect(t, ecs.rebuild(&view) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, any_of_view_has_entity(&view, e1))
            testing.expect(t, !any_of_view_has_entity(&view, e2))
            testing.expect(t, !any_of_view_has_entity(&view, e3))

            // e2 revives (untagged dead) — still matches any_of via boss
            testing.expect(t, ecs.remove_tag(&dead, e2) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)
            testing.expect(t, any_of_view_has_entity(&view, e2))

            // e3 tagged boss — now matches any_of too
            testing.expect(t, ecs.add_tag(&boss, e3) == nil)
            testing.expect(t, ecs.view_len(&view) == 3)
    }

    // A view using any_of still reaches the dense/aligned fast path — any_of
    // tables are not columns, so they must not affect column alignment at all.
    @(test)
    view_any_of_dense_path_preserved__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(OHealth)
            enemy: ecs.Tag_Table
            boss: ecs.Tag_Table
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&enemy, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&boss, &db, 10) == nil)

            testing.expect(t, ecs.view_init(&view, &db, {&healths}, any_of={&enemy, &boss}) == nil)
            defer ecs.view_terminate(&view)

            for i in 0..<10 {
                eid, _ := ecs.create_entity(&db)
                _, err := ecs.add_component(&healths, eid)
                testing.expect(t, err == nil)
                testing.expect(t, ecs.add_tag(&enemy, eid) == nil)
            }

            it: ecs.Iterator
            testing.expect(t, ecs.iterator_init(&it, &view) == nil)
            testing.expect(t, view.dense_state == ecs.View_Dense_State.Aligned, "any_of must not prevent the dense fast path")
    }

    // Terminating an any_of table invalidates the view; the same view struct can
    // then be terminated and re-init'd (issue #8) without stale any_of_bits.
    @(test)
    view_any_of_terminate_reinit__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(OHealth)
            enemy: ecs.Tag_Table
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&enemy, &db, 10) == nil)

            testing.expect(t, ecs.view_init(&view, &db, {&healths}, any_of={&enemy}) == nil)

            // Terminating the any_of table invalidates the view
            testing.expect(t, ecs.tag_table__terminate(&enemy) == nil)
            testing.expect(t, view.state == ecs.Object_State.Invalid)

            // Re-init the same structs; the view now has NO any_of — stale
            // any_of_bits from the previous life must not leak in (it would
            // otherwise make every entity fail the any_of check forever).
            testing.expect(t, ecs.view_terminate(&view) == nil)
            testing.expect(t, ecs.tag_table__init(&enemy, &db, 10) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&healths}) == nil)
            defer ecs.view_terminate(&view)

            e1, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)

            _, err := ecs.add_component(&healths, e1)
            testing.expect(t, err == nil)

            // No any_of on this view anymore — plain AND-only membership
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, any_of_view_has_entity(&view, e1))
    }

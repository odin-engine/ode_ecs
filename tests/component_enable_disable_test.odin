/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for component enable/disable: a soft toggle that excludes a
    component from query matching (view__components_match) without moving
    or removing it.
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

    EHealth :: struct { hp: int }
    EArmor :: struct { armor: int }

///////////////////////////////////////////////////////////////////////////////
// Helpers

    @(private="file")
    ed_view_has_entity :: proc(view: ^ecs.View, eid: ecs.entity_id) -> bool {
        it: ecs.Iterator
        if ecs.iterator_init(&it, view) != nil do return false
        for ecs.iterator_next(&it) {
            if ecs.get_entity(&it) == eid do return true
        }
        return false
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    // Basic disable/enable: disabling a view's included table evicts the entity; re-enabling
    // restores it. The component itself is untouched throughout (still readable, same value).
    @(test)
    component_disable_enable__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // no allocations outside provided allocator

            db: ecs.Database
            healths: ecs.Table(EHealth)
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&healths}) == nil)

            e1, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)

            h, herr := ecs.add_component(&healths, e1)
            testing.expect(t, herr == nil)
            h.hp = 42

            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, ed_view_has_entity(&view, e1))
            testing.expect(t, !ecs.is_component_disabled(&healths, e1))

            // Disable: evicted from the view, component data untouched
            testing.expect(t, ecs.disable_component(&healths, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)
            testing.expect(t, !ed_view_has_entity(&view, e1))
            testing.expect(t, ecs.is_component_disabled(&healths, e1))
            testing.expect(t, ecs.get_component(&healths, e1).hp == 42) // still there, unchanged
            testing.expect(t, ecs.has_component(&healths, e1)) // still "has" the component

            // Re-enable: restored
            testing.expect(t, ecs.enable_component(&healths, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, ed_view_has_entity(&view, e1))
            testing.expect(t, !ecs.is_component_disabled(&healths, e1))
            testing.expect(t, ecs.get_component(&healths, e1).hp == 42)
    }

    // Disabling a table that a view does NOT include must not affect that view at all.
    @(test)
    component_disable_unrelated_table_is_noop__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(EHealth)
            armors: ecs.Table(EArmor)
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.table_init(&armors, &db, 10) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&healths}) == nil) // armors not included

            e1, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)

            _, herr := ecs.add_component(&healths, e1)
            testing.expect(t, herr == nil)
            _, aerr := ecs.add_component(&armors, e1)
            testing.expect(t, aerr == nil)

            testing.expect(t, ecs.view_len(&view) == 1)

            // Disabling armor (not in `view`'s includes) must not evict e1 from `view`
            testing.expect(t, ecs.disable_component(&armors, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, ed_view_has_entity(&view, e1))
            testing.expect(t, ecs.is_component_disabled(&armors, e1))
            testing.expect(t, !ecs.is_component_disabled(&healths, e1))
    }

    // An entity with two views (one per included table) — disabling one table only evicts
    // it from the view that actually includes that table.
    @(test)
    component_disable_only_affects_subscribed_views__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(EHealth)
            armors: ecs.Table(EArmor)
            health_view: ecs.View
            armor_view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.table_init(&armors, &db, 10) == nil)
            testing.expect(t, ecs.view_init(&health_view, &db, {&healths}) == nil)
            testing.expect(t, ecs.view_init(&armor_view, &db, {&armors}) == nil)

            e1, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)

            _, herr := ecs.add_component(&healths, e1)
            testing.expect(t, herr == nil)
            _, aerr := ecs.add_component(&armors, e1)
            testing.expect(t, aerr == nil)

            testing.expect(t, ecs.view_len(&health_view) == 1)
            testing.expect(t, ecs.view_len(&armor_view) == 1)

            testing.expect(t, ecs.disable_component(&healths, e1) == nil)
            testing.expect(t, ecs.view_len(&health_view) == 0)
            testing.expect(t, ecs.view_len(&armor_view) == 1) // untouched

            testing.expect(t, ecs.enable_component(&healths, e1) == nil)
            testing.expect(t, ecs.view_len(&health_view) == 1)
            testing.expect(t, ecs.view_len(&armor_view) == 1)
    }

    // Disabling twice / enabling twice is idempotent (uni_bits__add/remove on an already
    // set/cleared bit is a no-op), and rebuild reaches the same, correct membership.
    @(test)
    component_disable_idempotent_and_rebuild_consistent__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(EHealth)
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&healths}) == nil)

            e1, _ := ecs.create_entity(&db)
            _, herr := ecs.add_component(&healths, e1)
            testing.expect(t, herr == nil)

            testing.expect(t, ecs.disable_component(&healths, e1) == nil)
            testing.expect(t, ecs.disable_component(&healths, e1) == nil) // idempotent
            testing.expect(t, ecs.view_len(&view) == 0)

            // rebuild must reach the same (empty) membership from scratch
            testing.expect(t, ecs.rebuild(&view) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)

            testing.expect(t, ecs.enable_component(&healths, e1) == nil)
            testing.expect(t, ecs.enable_component(&healths, e1) == nil) // idempotent
            testing.expect(t, ecs.view_len(&view) == 1)

            testing.expect(t, ecs.rebuild(&view) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
    }

    // Destroying an entity must clear its disabled-bits — a freshly created entity that
    // reuses the same index must not inherit a stale disabled state.
    @(test)
    component_disable_cleared_on_destroy__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(EHealth)
            view: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.table_init(&healths, &db, 10) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&healths}) == nil)

            e1, _ := ecs.create_entity(&db)
            _, herr := ecs.add_component(&healths, e1)
            testing.expect(t, herr == nil)
            testing.expect(t, ecs.disable_component(&healths, e1) == nil)
            testing.expect(t, ecs.is_component_disabled(&healths, e1))

            testing.expect(t, ecs.destroy_entity(&db, e1) == nil)

            // New entity, most likely reusing e1's freed index
            e2, _ := ecs.create_entity(&db)
            _, herr2 := ecs.add_component(&healths, e2)
            testing.expect(t, herr2 == nil)

            testing.expect(t, !ecs.is_component_disabled(&healths, e2))
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, ed_view_has_entity(&view, e2))
    }

    // Combined with excludes and any_of in one view — disable interacts correctly with the
    // other two structural combinators (all four are ANDed together in components_match).
    @(test)
    component_disable_combined_with_excludes_and_any_of__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            healths: ecs.Table(EHealth)
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
            _, herr := ecs.add_component(&healths, e1)
            testing.expect(t, herr == nil)
            testing.expect(t, ecs.add_tag(&enemy, e1) == nil)

            testing.expect(t, ecs.view_len(&view) == 1)

            // Disabling healths (the AND-required table) evicts it, same as excludes/any_of failing
            testing.expect(t, ecs.disable_component(&healths, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)

            testing.expect(t, ecs.enable_component(&healths, e1) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
    }

    // Exercises the remaining three proc-group members not covered above (Table and Tag_Table
    // already are) — Compact_Table, Tiny_Table and Arch_Table — so a per-type signature mistake
    // in any wrapper would fail to compile here rather than only surfacing at first real use.
    @(test)
    component_disable_enable_compact_tiny_arch__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            compact_healths: ecs.Compact_Table(EHealth)
            tiny_armors: ecs.Tiny_Table(EArmor)
            arch: ecs.Arch_Table

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.compact_table__init(&compact_healths, &db, 10) == nil)
            testing.expect(t, ecs.tiny_table__init(&tiny_armors, &db) == nil)
            testing.expect(t, ecs.arch_table__init(&arch, &db, 10, {EHealth, EArmor}) == nil)

            e1, _ := ecs.create_entity(&db)

            _, cherr := ecs.add_component(&compact_healths, e1)
            testing.expect(t, cherr == nil)
            _, tierr := ecs.add_component(&tiny_armors, e1)
            testing.expect(t, tierr == nil)
            testing.expect(t, ecs.arch_table__add_entity(&arch, e1) == nil)

            testing.expect(t, !ecs.is_component_disabled(&compact_healths, e1))
            testing.expect(t, !ecs.is_component_disabled(&tiny_armors, e1))
            testing.expect(t, !ecs.is_component_disabled(&arch, e1))

            testing.expect(t, ecs.disable_component(&compact_healths, e1) == nil)
            testing.expect(t, ecs.disable_component(&tiny_armors, e1) == nil)
            testing.expect(t, ecs.disable_component(&arch, e1) == nil)

            testing.expect(t, ecs.is_component_disabled(&compact_healths, e1))
            testing.expect(t, ecs.is_component_disabled(&tiny_armors, e1))
            testing.expect(t, ecs.is_component_disabled(&arch, e1))

            testing.expect(t, ecs.enable_component(&compact_healths, e1) == nil)
            testing.expect(t, ecs.enable_component(&tiny_armors, e1) == nil)
            testing.expect(t, ecs.enable_component(&arch, e1) == nil)

            testing.expect(t, !ecs.is_component_disabled(&compact_healths, e1))
            testing.expect(t, !ecs.is_component_disabled(&tiny_armors, e1))
            testing.expect(t, !ecs.is_component_disabled(&arch, e1))
    }

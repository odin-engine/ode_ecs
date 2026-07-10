/*
    2026 (c) Oleh, https://github.com/zm69

    Regression tests for stale-state bugs around the terminate + re-init
    pattern (issue #8) and a few API consistency fixes.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs ".."
    import oc "../ode_core"

///////////////////////////////////////////////////////////////////////////////
// Re-init (issue #8) must not leak state from the previous life

    // view__init must clear `bits`: a view re-init'd over a DIFFERENT table
    // set used to keep the old tables' bits OR-ed in and stopped matching.
    @(test)
    view_reinit_resets_bits__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // no allocations outside provided allocator

        db: ecs.Database
        positions: ecs.Table(Position)
        ais: ecs.Table(AI)
        view: ecs.View

        // Cycle 1: view over two tables -> view.bits = {0, 1}
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions, &ais}) == nil)
        testing.expect(t, ecs.terminate(&db) == nil)

        // Cycle 2: same structs without zeroing, view now over ONE table
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        _, err2 := ecs.add_component(&positions, eid)
        testing.expect(t, err2 == nil)

        // Entity has Position, view includes only positions -> must match
        testing.expect(t, ecs.view_components_match(&view, eid))
        testing.expect_value(t, ecs.view_len(&view), 1)

        testing.expect(t, ecs.terminate(&db) == nil)
    }

    // view__init must clear `suspended`: a view suspended in a previous life
    // used to stay silently dead after re-init.
    @(test)
    view_reinit_resets_suspended__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        view: ecs.View

        // Cycle 1: suspend the view, then terminate everything
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)
        ecs.suspend(&view)
        testing.expect(t, ecs.terminate(&db) == nil)

        // Cycle 2: a freshly init'd view must receive updates
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        _, err2 := ecs.add_component(&positions, eid)
        testing.expect(t, err2 == nil)

        testing.expect_value(t, ecs.view_len(&view), 1)

        testing.expect(t, ecs.terminate(&db) == nil)
    }

    // database__init and database__clear must reset `tail_swap_paused`:
    // a database terminated (or cleared) while paused used to keep removals
    // on the deferred-hole path.
    @(test)
    database_reinit_resets_tail_swap_pause__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)

        // Terminate while paused, then re-init
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        ecs.pause_packing(&db)
        testing.expect(t, ecs.terminate(&db) == nil)

        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, db.tail_swap_paused == false)

        // Normal (unpaused) removal must tail-swap, not leave a hole
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        e1, _ := ecs.create_entity(&db)
        e2, _ := ecs.create_entity(&db)
        _, _ = ecs.add_component(&positions, e1)
        _, _ = ecs.add_component(&positions, e2)

        testing.expect(t, ecs.remove_component(&positions, e1) == nil)
        testing.expect_value(t, ecs.table_len(&positions), 1)

        // clear() returns the database to its post-init state, unpaused
        ecs.pause_packing(&db)
        testing.expect(t, ecs.clear(&db) == nil)
        testing.expect(t, db.tail_swap_paused == false)

        testing.expect(t, ecs.terminate(&db) == nil)
    }

    // Tiny_Table's fixed subscribers array must be cleared on re-init:
    // it used to keep notifying views from a previous life.
    @(test)
    tiny_table_reinit_clears_subscribers__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        tiny: ecs.Tiny_Table(Position)
        view: ecs.View

        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.tiny_table__init(&tiny, &db) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&tiny}) == nil)

        // Terminate the TABLE while the view is alive (view becomes Invalid),
        // then re-init the same tiny table struct.
        testing.expect(t, ecs.tiny_table__terminate(&tiny) == nil)
        testing.expect(t, view.state == ecs.Object_State.Invalid)
        testing.expect(t, ecs.tiny_table__init(&tiny, &db) == nil)

        // The Invalid view from the previous life must not still be subscribed
        testing.expect(t, tiny.subscribers[0] == nil)

        // ...and must not receive rows from the re-init'd table
        e1, _ := ecs.create_entity(&db)
        _, aerr := ecs.add_component(&tiny, e1)
        testing.expect(t, aerr == nil)
        testing.expect_value(t, ecs.view_len(&view), 0)

        testing.expect(t, ecs.terminate(&db) == nil)
    }

///////////////////////////////////////////////////////////////////////////////
// API consistency

    // Re-adding an existing tag on a FULL tag table must be a no-op (nil),
    // matching the component tables; it used to return Container_Is_Full.
    @(test)
    tag_table_full_readd_is_noop__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        tags: ecs.Tag_Table

        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.tag_table__init(&tags, &db, 1) == nil)

        e1, _ := ecs.create_entity(&db)
        e2, _ := ecs.create_entity(&db)

        testing.expect(t, ecs.add_tag(&tags, e1) == nil)   // table now full
        testing.expect(t, ecs.add_tag(&tags, e1) == nil)   // re-add: no-op
        testing.expect_value(t, ecs.table_len(&tags), 1)

        // a genuinely new tag on a full table still fails
        testing.expect(t, ecs.add_tag(&tags, e2) == ecs.Error(oc.Core_Error.Container_Is_Full))

        testing.expect(t, ecs.terminate(&db) == nil)
    }

    // An iterator with an explicit end_row must clamp to the current view
    // length on reset; it used to walk cleared rows after the view shrank.
    @(test)
    iterator_explicit_end_row_clamps__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        view: ecs.View
        it: ecs.Iterator

        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        e1, _ := ecs.create_entity(&db)
        e2, _ := ecs.create_entity(&db)
        e3, _ := ecs.create_entity(&db)
        _, _ = ecs.add_component(&positions, e1)
        _, _ = ecs.add_component(&positions, e2)
        _, _ = ecs.add_component(&positions, e3)

        testing.expect(t, ecs.iterator_init(&it, &view, 0, 3) == nil)

        count := 0
        for ecs.iterator_next(&it) do count += 1
        testing.expect_value(t, count, 3)

        // Shrink the view, then reset the same batched iterator
        testing.expect(t, ecs.remove_component(&positions, e1) == nil)
        testing.expect(t, ecs.remove_component(&positions, e2) == nil)
        testing.expect_value(t, ecs.view_len(&view), 1)

        testing.expect(t, ecs.iterator_reset(&it) == nil)

        count = 0
        for ecs.iterator_next(&it) {
            count += 1
            eid := ecs.get_entity(&it)
            testing.expect(t, eid.ix != ecs.DELETED_INDEX) // never a cleared row
        }
        testing.expect_value(t, count, 1)

        // A batch that now starts past the end is simply empty
        it2: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it2, &view, 1, 1) == nil)
        testing.expect(t, ecs.iterator_next(&it2) == false)

        testing.expect(t, ecs.terminate(&db) == nil)
    }

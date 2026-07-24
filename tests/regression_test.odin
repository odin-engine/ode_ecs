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

    // A database-wide resume must not silently clear an independently-paused
    // table: it still packs the table (safe, matches pack's "mid-pause"
    // guarantee), but the table's own pause_packing flag survives so a later
    // removal on it still defers — one actor's database-wide resume must not
    // break another actor's independent table-level pause.
    @(test)
    table_pause_survives_database_resume__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

        eids: [3]ecs.entity_id
        for i in 0..<3 {
            eids[i], _ = ecs.create_entity(&db)
            _, _ = ecs.add_component(&positions, eids[i])
        }

        ecs.pause_packing(&db)
        testing.expect(t, ecs.pause_packing(&positions) == nil)

        testing.expect(t, ecs.remove_component(&positions, eids[1]) == nil)
        testing.expect(t, positions.holes_count == 1)

        // db-wide resume packs the still-individually-paused table...
        testing.expect(t, ecs.resume_packing(&db) == nil)
        testing.expect(t, db.tail_swap_paused == false)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 2)

        // ...but does not clear the table's own pause: a later removal on it
        // still defers via a hole instead of tail-swapping
        testing.expect(t, ecs.remove_component(&positions, eids[0]) == nil)
        testing.expect(t, positions.holes_count == 1)
        testing.expect(t, ecs.table_len(&positions) == 2) // row span unchanged: hole, not tail-swapped

        testing.expect(t, ecs.resume_packing(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 1)
    }

    // Same as table_pause_survives_database_resume__test, but for a Group:
    // a database-wide resume packs the group's owned tables (rebuild is a
    // deferred no-op while the group is still independently paused) without
    // clearing the group's own pause_packing.
    @(test)
    group_pause_survives_database_resume__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        group: ecs.Group

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 10) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)

        eids: [3]ecs.entity_id
        for i in 0..<3 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(eids[i].ix), 1 }
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(eids[i].ix), 2 }
        }
        testing.expect(t, ecs.group_len(&group) == 3)

        ecs.pause_packing(&db)
        testing.expect(t, ecs.pause_packing(&group) == nil)

        // membership change deferred by the group's own pause
        testing.expect(t, ecs.remove_component(&vel, eids[1]) == nil)
        testing.expect(t, ecs.group_dense_slice(&group, &pos) == nil)

        // db-wide resume packs owned tables but the group stays dirty: it is
        // still independently paused, so group__rebuild re-defers
        testing.expect(t, ecs.resume_packing(&db) == nil)
        testing.expect(t, db.tail_swap_paused == false)
        testing.expect(t, ecs.group_dense_slice(&group, &pos) == nil, "group must still be dirty: its own pause survived")

        testing.expect(t, ecs.resume_packing(&group) == nil)
        testing.expect(t, ecs.group_len(&group) == 2)
        group__verify(t, &group, &pos, &vel)
    }

    // Shared_Table.pause_packing must be reset on re-init (issue #8 pattern),
    // but preserved across a data-only clear() — clear resets row data, not
    // caller-set mode.
    @(test)
    table_pause_packing_reinit_clear__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)

        // Terminate while table-paused, then re-init: flag must reset
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, ecs.terminate(&db) == nil)

        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, positions.pause_packing == false)

        // clear() is a data-only reset: the pause must survive it
        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, ecs.clear(&positions) == nil)
        testing.expect(t, positions.pause_packing == true)

        testing.expect(t, ecs.resume_packing(&positions) == nil)
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
// Suspended-view stale guard

    // A view that misses a MEMBER removal while suspended holds rows that
    // reference table rows no longer backing them — it must come back from
    // resume flagged `stale`, and rebuild must clear the flag and restore
    // correct content. Missed ADDS must NOT flag it: they only leave the view
    // incomplete, which is the documented suspend semantic.
    @(test)
    view_suspend_missed_removal_sets_stale__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        view: ecs.View

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        e1, _ := ecs.create_entity(&db)
        e2, _ := ecs.create_entity(&db)
        _, _ = ecs.add_component(&positions, e1)
        _, _ = ecs.add_component(&positions, e2)
        testing.expect_value(t, ecs.view_len(&view), 2)

        // Missed adds: safe, no stale flag
        ecs.suspend(&view)
        e3, _ := ecs.create_entity(&db)
        _, _ = ecs.add_component(&positions, e3)
        ecs.resume(&view)
        testing.expect(t, view.stale == false)
        testing.expect_value(t, ecs.view_len(&view), 2) // incomplete but valid

        testing.expect(t, ecs.rebuild(&view) == nil)
        testing.expect_value(t, ecs.view_len(&view), 3)

        // Missed member removal: view row for e1 now points at moved data
        ecs.suspend(&view)
        testing.expect(t, ecs.remove_component(&positions, e1) == nil)
        ecs.resume(&view)
        testing.expect(t, view.stale == true)

        // rebuild restores trust and correct content
        testing.expect(t, ecs.rebuild(&view) == nil)
        testing.expect(t, view.stale == false)
        testing.expect_value(t, ecs.view_len(&view), 2)

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        visited := 0
        for ecs.iterator_next(&it) {
            eid := ecs.get_entity(&it)
            testing.expect(t, eid == e2 || eid == e3)
            visited += 1
        }
        testing.expect_value(t, visited, 2)

        // Missed destroy_entity is also a member removal — must flag stale
        ecs.suspend(&view)
        testing.expect(t, ecs.destroy_entity(&db, e2) == nil)
        ecs.resume(&view)
        testing.expect(t, view.stale == true)
        testing.expect(t, ecs.rebuild(&view) == nil)
        testing.expect(t, view.stale == false)
        testing.expect_value(t, ecs.view_len(&view), 1)
    }

///////////////////////////////////////////////////////////////////////////////
// view__rebuild / view__refilter over every table type (pins the
// shared_table__rid_to_eid_slice scan paths, including mid-pause holes)

    @(test)
    view_rebuild_all_table_types__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        N :: 200

        db: ecs.Database
        positions: ecs.Table(Position)
        ais: ecs.Compact_Table(AI)
        marked: ecs.Tag_Table
        tiny_ais: ecs.Tiny_Table(AI)
        view: ecs.View      // Table + Compact + Tag columns
        tiny_view: ecs.View // Tiny column (rebuild scans the smallest table — the tiny one)

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = N, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, N) == nil)
        testing.expect(t, ecs.compact_table__init(&ais, &db, N) == nil)
        testing.expect(t, ecs.tag_table__init(&marked, &db, N) == nil)
        testing.expect(t, ecs.tiny_table__init(&tiny_ais, &db) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions, &ais, &marked}) == nil)
        testing.expect(t, ecs.view_init(&tiny_view, &db, {&tiny_ais, &positions}) == nil)

        eids: [N]ecs.entity_id
        for i in 0..<N {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            eids[i] = eid

            _, err1 := ecs.add_component(&positions, eid)
            testing.expect(t, err1 == nil)
            if i % 2 == 0 {
                _, err2 := ecs.add_component(&ais, eid)
                testing.expect(t, err2 == nil)
            }
            if i % 3 == 0 do testing.expect(t, ecs.add_tag(&marked, eid) == nil)
            if i < 8 {
                _, err3 := ecs.add_component(&tiny_ais, eid)
                testing.expect(t, err3 == nil)
            }
        }

        expected := 0
        for i in 0..<N do if i % 2 == 0 && i % 3 == 0 do expected += 1

        testing.expect_value(t, ecs.view_len(&view), expected)
        testing.expect(t, ecs.rebuild(&view) == nil) // full re-scan must agree with incremental
        testing.expect_value(t, ecs.view_len(&view), expected)

        testing.expect_value(t, ecs.view_len(&tiny_view), 8)
        testing.expect(t, ecs.rebuild(&tiny_view) == nil)
        testing.expect_value(t, ecs.view_len(&tiny_view), 8)

        // Rebuild mid-pause: the scan slices now contain holes that must be
        // skipped, and removed entities must drop out of the rebuilt view.
        ecs.pause_packing(&db)
        removed := 0
        for i in 0..<N {
            if i % 12 == 0 { // half of the members (members are the multiples of 6)
                testing.expect(t, ecs.remove_component(&ais, eids[i]) == nil)
                removed += 1
            }
        }
        testing.expect(t, ais.holes_count > 0) // scan really sees holes

        testing.expect(t, ecs.rebuild(&view) == nil)
        testing.expect_value(t, ecs.view_len(&view), expected - removed)

        testing.expect(t, ecs.resume_packing(&db) == nil)
        testing.expect(t, ecs.rebuild(&view) == nil)
        testing.expect_value(t, ecs.view_len(&view), expected - removed)

        // membership spot check after all rebuilds (VIEW_NO_RID == max(u32))
        for i in 0..<N {
            in_view := view.eid_to_rid[eids[i].ix] != ecs.view_record_id(max(u32))
            should := i % 6 == 0 && i % 12 != 0
            testing.expect(t, in_view == should)
        }
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

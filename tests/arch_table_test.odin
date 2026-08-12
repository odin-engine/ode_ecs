/*
    2025 (c) Oleh, https://github.com/zm69
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
// Arch_Table

    @(test)
    arch_table__init_terminate__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)

        testing.expect(t, ecs.arch_table__init(&at, &db, 5, {Position, AI}) == nil)
        testing.expect(t, ecs.arch_table__is_valid(&at))
        testing.expect(t, ecs.table_len(&at) == 0)
        testing.expect(t, ecs.table_cap(&at) == 5)
        testing.expect(t, at.type == ecs.Table_Type.Arch_Table)

        // table id recycling: terminate + re-init should reuse the same slot
        id_before := at.id
        testing.expect(t, ecs.arch_table__terminate(&at) == nil)
        testing.expect(t, ecs.arch_table__init(&at, &db, 5, {Position, AI}) == nil)
        testing.expect(t, at.id == id_before)
    }

    @(test)
    arch_table__init_errors__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&at, &db, 5, {}) == ecs.API_Error.Tables_Array_Should_Not_Be_Empty)
    }

    // arch_table__init asserts every component is non-zero-sized (use Tag_Table
    // for markers). No test here: catching the assert hangs this sandbox's
    // test runner — covered by manual verification only.

    @(test)
    arch_table__create_entity_and_get_component__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&at)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.table_len(&at) == 1)
        testing.expect(t, ecs.has_component(&at, eid))

        pos := ecs.get_component(&at, eid, Position)
        testing.expect(t, pos != nil)
        pos.x = 1
        pos.y = 2

        ai := ecs.get_component(&at, eid, AI)
        testing.expect(t, ai != nil)
        ai.IQ = 100
        ai.neurons_count = 42

        // reads round-trip
        pos2 := ecs.get_component(&at, eid, Position)
        testing.expect(t, pos2.x == 1 && pos2.y == 2)
        ai2 := ecs.get_component(&at, eid, AI)
        testing.expect(t, ai2.IQ == 100 && ai2.neurons_count == 42)

        aerr := ecs.arch_table__add_entity(&at, eid)
        testing.expect(t, aerr == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, ecs.table_len(&at) == 1)

        other, oerr := ecs.create_entity(&db)
        testing.expect(t, oerr == nil)
        testing.expect(t, !ecs.has_component(&at, other))
        testing.expect(t, ecs.get_component(&at, other, Position) == nil)
    }

    @(test)
    arch_table__add_entity_to_existing__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        testing.expect(t, !ecs.has_component(&at, eid))

        testing.expect(t, ecs.arch_table__add_entity(&at, eid) == nil)
        testing.expect(t, ecs.has_component(&at, eid))
        testing.expect(t, ecs.table_len(&at) == 1)
    }

    @(test)
    // Guards against only one column getting swapped on a middle-row removal.
    arch_table__remove_entity_swaps_every_column__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)
        e2, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 100
        ecs.get_component(&at, e0, AI).neurons_count = 1000

        ecs.get_component(&at, e1, Position).x = 200
        ecs.get_component(&at, e1, AI).neurons_count = 2000

        ecs.get_component(&at, e2, Position).x = 300
        ecs.get_component(&at, e2, AI).neurons_count = 3000

        // remove the middle entity (e1) — e2 (the tail) must tail-swap into e1's row
        testing.expect(t, ecs.arch_table__remove_entity(&at, e1) == nil)

        testing.expect(t, ecs.table_len(&at) == 2)
        testing.expect(t, !ecs.has_component(&at, e1))
        testing.expect(t, ecs.has_component(&at, e0))
        testing.expect(t, ecs.has_component(&at, e2))

        testing.expect(t, ecs.get_component(&at, e0, Position).x == 100)
        testing.expect(t, ecs.get_component(&at, e0, AI).neurons_count == 1000)

        // e2 moved — both columns must carry over to its new row
        testing.expect(t, ecs.get_component(&at, e2, Position).x == 300)
        testing.expect(t, ecs.get_component(&at, e2, AI).neurons_count == 3000)

        // removing the tail is a simpler path (no swap) — exercise it too
        testing.expect(t, ecs.arch_table__remove_entity(&at, e2) == nil)
        testing.expect(t, ecs.table_len(&at) == 1)
        testing.expect(t, !ecs.has_component(&at, e2))
        testing.expect(t, ecs.get_component(&at, e0, Position).x == 100)
    }

    @(test)
    arch_table__pause_resume_packing__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)
        e2, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 1
        ecs.get_component(&at, e1, Position).x = 2
        ecs.get_component(&at, e2, Position).x = 3

        testing.expect(t, ecs.pause_packing(&at) == nil)

        // removing the middle row while paused leaves a hole; no row moves
        testing.expect(t, ecs.arch_table__remove_entity(&at, e1) == nil)
        testing.expect(t, ecs.get_component(&at, e0, Position).x == 1)
        testing.expect(t, ecs.get_component(&at, e2, Position).x == 3)
        testing.expect(t, !ecs.has_component(&at, e1))

        testing.expect(t, ecs.resume_packing(&at) == nil)

        // after resume, the table is packed: e0 and e2 remain, values intact
        testing.expect(t, ecs.table_len(&at) == 2)
        testing.expect(t, ecs.get_component(&at, e0, Position).x == 1)
        testing.expect(t, ecs.get_component(&at, e2, Position).x == 3)
    }

    @(test)
    // Hole-check is guarded behind holes_count > 0 for perf; proves it still
    // skips a paused-removal hole via ecs.next(), not just direct access.
    arch_iterator__skips_hole_while_paused__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)
        e2, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 1
        ecs.get_component(&at, e1, Position).x = 2
        ecs.get_component(&at, e2, Position).x = 3

        testing.expect(t, ecs.pause_packing(&at) == nil)
        testing.expect(t, ecs.arch_table__remove_entity(&at, e1) == nil) // leaves a hole at e1's old row

        it: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it, &at) == nil)

        seen_x := 0
        visited := 0
        for _, pos in ecs.next(&it, Position) {
            testing.expect(t, pos.x == 1 || pos.x == 3) // never the hole's stale/zeroed row
            seen_x += pos.x
            visited += 1
        }
        testing.expect(t, visited == 2)
        testing.expect(t, seen_x == 4)

        testing.expect(t, ecs.resume_packing(&at) == nil)
    }

    @(test)
    arch_table__destroy_entity_removes_row__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        eid, _ := ecs.create_entity(&at)
        testing.expect(t, ecs.table_len(&at) == 1)

        // destroy_entity walks eid_to_bits generically; no Arch_Table-specific code needed
        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
        testing.expect(t, ecs.table_len(&at) == 0)
        testing.expect(t, !ecs.has_component(&at, eid))
    }

    @(test)
    arch_iterator__next_sugar__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)
        e2, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 1
        ecs.get_component(&at, e1, Position).x = 2
        ecs.get_component(&at, e2, Position).x = 3

        ecs.get_component(&at, e0, AI).neurons_count = 10
        ecs.get_component(&at, e1, AI).neurons_count = 20
        ecs.get_component(&at, e2, AI).neurons_count = 30

        it: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it, &at) == nil)

        count := 0
        sum_x := 0
        sum_neurons := 0
        for eid, pos, ai in ecs.next(&it, Position, AI) {
            testing.expect(t, pos != nil)
            testing.expect(t, ai != nil)
            pos.x += 100
            sum_x += pos.x
            sum_neurons += ai.neurons_count
            count += 1
            _ = eid
        }

        testing.expect(t, count == 3)
        testing.expect(t, sum_x == 101 + 102 + 103)
        testing.expect(t, sum_neurons == 10 + 20 + 30)

        // mutation through the loop persisted
        testing.expect(t, ecs.get_component(&at, e0, Position).x == 101)
        testing.expect(t, ecs.get_component(&at, e2, Position).x == 103)

        // non-for-loop direct call form, mirroring Table's iterate() precedent
        it2: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it2, &at) == nil)
        eid, pos, cond := ecs.next(&it2, Position)
        testing.expect(t, cond == true)
        testing.expect(t, pos != nil)
        _ = eid
    }

    @(test)
    arch_iterator__batches_and_column_not_found__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        for i in 0 ..< 6 {
            eid, _ := ecs.create_entity(&at)
            ecs.get_component(&at, eid, Position).x = i
        }

        // batch [0, 3)
        it: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it, &at, start_row = 0, end_row = 3) == nil)
        count := 0
        for eid, pos in ecs.next(&it, Position) {
            _ = eid
            _ = pos
            count += 1
        }
        testing.expect(t, count == 3)

        it2: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it2, &at, start_row = 3, end_row = 6) == nil)
        count2 := 0
        for eid2, pos2 in ecs.next(&it2, Position) {
            _ = eid2
            _ = pos2
            count2 += 1
        }
        testing.expect(t, count2 == 3)

        // a type not in this archetype: next() is "contextless" so it can't
        // assert — cond stays false forever instead of erroring (see arch_iterator.odin)
        no_ai: ecs.Arch_Table
        defer ecs.arch_table__terminate(&no_ai)
        testing.expect(t, ecs.arch_table__init(&no_ai, &db, 5, {Position}) == nil)

        _, _ = ecs.create_entity(&no_ai)

        it3: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it3, &no_ai) == nil)
        _, _, cond3 := ecs.next(&it3, AI)
        testing.expect(t, cond3 == false)
    }

    @(test)
    arch_iterator__type_free_next__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 11
        ecs.get_component(&at, e0, AI).neurons_count = 111
        ecs.get_component(&at, e1, Position).x = 22
        ecs.get_component(&at, e1, AI).neurons_count = 222

        it: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it, &at) == nil)

        seen := 0
        sum_x := 0
        sum_neurons := 0
        // no column types passed at all — get_component is called manually per entity
        for eid in ecs.next(&it) {
            pos := ecs.arch_table__get_component(&at, eid, Position)
            ai := ecs.arch_table__get_component(&at, eid, AI)
            testing.expect(t, pos != nil && ai != nil)
            sum_x += pos.x
            sum_neurons += ai.neurons_count
            seen += 1
        }
        testing.expect(t, seen == 2)
        testing.expect(t, sum_x == 33)
        testing.expect(t, sum_neurons == 333)

        // manual step form (no for-loop)
        it2: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it2, &at) == nil)
        eid, cond := ecs.next(&it2)
        testing.expect(t, cond == true)
        testing.expect(t, ecs.arch_table__get_component(&at, eid, Position) != nil)
    }

    @(test)
    arch_iterator__wide_arity__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        C1 :: struct { v: int }
        C2 :: struct { v: int }
        C3 :: struct { v: int }
        C4 :: struct { v: int }
        C5 :: struct { v: int }
        C6 :: struct { v: int }
        C7 :: struct { v: int }

        wide: ecs.Arch_Table
        defer ecs.arch_table__terminate(&wide)
        testing.expect(t, ecs.arch_table__init(&wide, &db, 5, {C1, C2, C3, C4, C5, C6, C7}) == nil)

        eid, err := ecs.create_entity(&wide)
        testing.expect(t, err == nil)
        ecs.get_component(&wide, eid, C1).v = 1
        ecs.get_component(&wide, eid, C2).v = 2
        ecs.get_component(&wide, eid, C3).v = 3
        ecs.get_component(&wide, eid, C4).v = 4
        ecs.get_component(&wide, eid, C5).v = 5
        ecs.get_component(&wide, eid, C6).v = 6
        ecs.get_component(&wide, eid, C7).v = 7

        it: ecs.Arch_Iterator
        testing.expect(t, ecs.arch_iterator_init(&it, &wide) == nil)

        count := 0
        for _, c1, c2, c3, c4, c5, c6, c7 in ecs.next(&it, C1, C2, C3, C4, C5, C6, C7) {
            testing.expect(t, c1.v == 1 && c2.v == 2 && c3.v == 3 && c4.v == 4 && c5.v == 5 && c6.v == 6 && c7.v == 7)
            count += 1
        }
        testing.expect(t, count == 1)
    }

    @(test)
    arch_table__command_buffer_add_and_remove__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        cb: ecs.Command_Buffer
        defer ecs.command_buffer_terminate(&cb)
        testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 16, payload_cap = 512) == nil)

        // record: add a fresh entity's row via the buffer, not the database yet
        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.cmd_arch_add_entity(&cb, &at, eid, Position{x = 7, y = 8}, AI{IQ = 99, neurons_count = 5}) == nil)
        testing.expect(t, ecs.table_len(&at) == 0) // untouched until replay

        skipped, rerr := ecs.replay(&cb)
        testing.expect(t, rerr == nil)
        testing.expect(t, skipped == 0)

        testing.expect(t, ecs.table_len(&at) == 1)
        pos := ecs.get_component(&at, eid, Position)
        testing.expect(t, pos.x == 7 && pos.y == 8)
        ai := ecs.get_component(&at, eid, AI)
        testing.expect(t, ai.IQ == 99 && ai.neurons_count == 5)

        // record: overwrite the same row ("last write wins")
        testing.expect(t, ecs.cmd_arch_add_entity(&cb, &at, eid, Position{x = 1, y = 1}, AI{IQ = 1, neurons_count = 1}) == nil)
        skipped2, rerr2 := ecs.replay(&cb)
        testing.expect(t, rerr2 == nil)
        testing.expect(t, skipped2 == 0) // overwrite counts as applied, not skipped
        testing.expect(t, ecs.table_len(&at) == 1) // still one row, not two
        testing.expect(t, ecs.get_component(&at, eid, Position).x == 1)

        // record: remove the row via the buffer
        testing.expect(t, ecs.cmd_remove_component(&cb, &at, eid) == nil)
        testing.expect(t, ecs.has_component(&at, eid)) // untouched until replay

        skipped3, rerr3 := ecs.replay(&cb)
        testing.expect(t, rerr3 == nil)
        testing.expect(t, skipped3 == 0)
        testing.expect(t, ecs.table_len(&at) == 0)
        testing.expect(t, !ecs.has_component(&at, eid))

        // removing again is idempotent (skipped, not an error)
        testing.expect(t, ecs.cmd_remove_component(&cb, &at, eid) == nil)
        skipped4, rerr4 := ecs.replay(&cb)
        testing.expect(t, rerr4 == nil)
        testing.expect(t, skipped4 == 1)
    }

    @(test)
    arch_table__command_buffer_terminated_table_is_skipped__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position}) == nil)

        cb: ecs.Command_Buffer
        defer ecs.command_buffer_terminate(&cb)
        testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 16, payload_cap = 512) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.cmd_arch_add_entity(&cb, &at, eid, Position{x = 1, y = 1}) == nil)

        // table terminated between record and replay — command__table_matches must reject it
        testing.expect(t, ecs.arch_table__terminate(&at) == nil)

        skipped, rerr := ecs.replay(&cb)
        testing.expect(t, rerr == nil)
        testing.expect(t, skipped == 1)
    }

    @(test)
    arch_table__serialization_round_trip__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        src_db: ecs.Database
        defer ecs.terminate(&src_db)
        testing.expect(t, ecs.init(&src_db, entities_cap = 20, allocator = allocator) == nil)

        src_at: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&src_at, &src_db, 10, {Position, AI}) == nil)

        eids: [5]ecs.entity_id
        for i in 0 ..< 5 {
            eid, err := ecs.create_entity(&src_at)
            testing.expect(t, err == nil)
            eids[i] = eid
            ecs.get_component(&src_at, eid, Position).x = i * 10
            ecs.get_component(&src_at, eid, AI).neurons_count = i * 100
        }

        size, serr := ecs.serialized_size(&src_db)
        testing.expect(t, serr == nil)
        buf := make([]byte, size, allocator)
        defer delete(buf, allocator)

        written, werr := ecs.serialize(&src_db, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, written == size)

        dst_db: ecs.Database
        defer ecs.terminate(&dst_db)
        testing.expect(t, ecs.init(&dst_db, entities_cap = 20, allocator = allocator) == nil)

        dst_at: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&dst_at, &dst_db, 10, {Position, AI}) == nil)

        testing.expect(t, ecs.deserialize(&dst_db, buf) == nil)

        testing.expect(t, ecs.table_len(&dst_at) == 5)
        for i in 0 ..< 5 {
            eid := eids[i]
            testing.expect(t, ecs.has_component(&dst_at, eid))
            testing.expect(t, ecs.get_component(&dst_at, eid, Position).x == i * 10)
            testing.expect(t, ecs.get_component(&dst_at, eid, AI).neurons_count == i * 100)
        }
    }

    @(test)
    arch_table__serialization_schema_mismatch__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        src_db: ecs.Database
        defer ecs.terminate(&src_db)
        testing.expect(t, ecs.init(&src_db, entities_cap = 10, allocator = allocator) == nil)

        src_at: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&src_at, &src_db, 5, {Position, AI}) == nil)

        _, cerr := ecs.create_entity(&src_at)
        testing.expect(t, cerr == nil)

        size, serr := ecs.serialized_size(&src_db)
        testing.expect(t, serr == nil)
        buf := make([]byte, size, allocator)
        defer delete(buf, allocator)
        _, werr := ecs.serialize(&src_db, buf)
        testing.expect(t, werr == nil)

        dst_db: ecs.Database
        defer ecs.terminate(&dst_db)
        testing.expect(t, ecs.init(&dst_db, entities_cap = 10, allocator = allocator) == nil)

        // different column count than the source archetype
        dst_at: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&dst_at, &dst_db, 5, {Position}) == nil)

        testing.expect(t, ecs.deserialize(&dst_db, buf) == ecs.API_Error.Snapshot_Schema_Mismatch)
    }

    @(test)
    // Arch_Table mixed into a View with a regular Table; Arch_Table columns
    // aren't part of iterator__next1..7, so they're read via get_component(&table, &it, $T).
    arch_table__mixed_view_with_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        speeds: ecs.Table(Speed)
        at: ecs.Arch_Table
        view: ecs.View

        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&speeds, &db, 10) == nil)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&speeds, &at}) == nil)

        // e0: Speed + archetype row -> matches the view
        e0, _ := ecs.create_entity(&db)
        spd0, sperr0 := ecs.add_component(&speeds, e0)
        testing.expect(t, sperr0 == nil)
        spd0.value = 7
        testing.expect(t, ecs.arch_table__add_entity(&at, e0) == nil)
        ecs.get_component(&at, e0, Position).x = 11
        ecs.get_component(&at, e0, AI).neurons_count = 111

        // e1: Speed only -> not a member (missing the archetype row)
        e1, _ := ecs.create_entity(&db)
        _, sperr1 := ecs.add_component(&speeds, e1)
        testing.expect(t, sperr1 == nil)

        // e2: archetype row only -> not a member (missing Speed)
        e2, _ := ecs.create_entity(&db)
        testing.expect(t, ecs.arch_table__add_entity(&at, e2) == nil)

        testing.expect(t, ecs.view_len(&view) == 1)

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)

        visited := 0
        for ecs.iterator_next(&it) {
            eid := ecs.get_entity(&it)
            testing.expect(t, eid == e0)

            spd := ecs.get_component(&speeds, &it)
            testing.expect(t, spd.value == 7)

            pos := ecs.get_component(&at, &it, Position)
            testing.expect(t, pos.x == 11)

            ai := ecs.get_component(&at, &it, AI)
            testing.expect(t, ai.neurons_count == 111)

            visited += 1
        }
        testing.expect(t, visited == 1)

        // adding the archetype row to e1 now brings it into the view (live updates)
        testing.expect(t, ecs.arch_table__add_entity(&at, e1) == nil)
        testing.expect(t, ecs.view_len(&view) == 2)
    }

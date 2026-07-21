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

///////////////////////////////////////////////////////////////////////////////
// ecs.iterate — for-in sugar over Iterator + Table($T) columns

    @(test)
    iterate_one_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        view: ecs.View

        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        for i in 0 ..< 5 {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            pos, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)
            pos^ = Position{x = i, y = 0}
        }

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)

        count := 0
        for pos in ecs.iterate(&it, &positions) {
            pos.x += 100
            count += 1
        }
        testing.expect(t, count == 5)

        // Values were actually mutated through the sugar loop.
        sum := 0
        for &pos in positions.rows {
            sum += pos.x
        }
        testing.expect(t, sum == 100 * 5 + (0 + 1 + 2 + 3 + 4))
    }

    @(test)
    iterate_two_tables__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        ais: ecs.Table(AI)
        view: ecs.View

        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions, &ais}) == nil)

        for i in 0 ..< 3 {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            pos, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)
            pos^ = Position{x = i, y = i}
            ai, aerr := ecs.add_component(&ais, eid)
            testing.expect(t, aerr == nil)
            ai^ = AI{IQ = 1, neurons_count = i}
        }

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)

        count := 0
        for pos, ai in ecs.iterate(&it, &positions, &ais) {
            pos.x += ai.neurons_count
            count += 1
        }
        testing.expect(t, count == 3)

        expected_x := 0 + (0 + 0) // i=0: x=0, +neurons(0)
        expected_x += 1 + 1       // i=1: x=1, +neurons(1)
        expected_x += 2 + 2       // i=2: x=2, +neurons(2)

        sum := 0
        for &pos in positions.rows {
            sum += pos.x
        }
        testing.expect(t, sum == expected_x)
    }

    @(test)
    iterate_empty_view__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        view: ecs.View

        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)

        count := 0
        for pos in ecs.iterate(&it, &positions) {
            count += 1
        }
        testing.expect(t, count == 0)
    }

    // ecs.iterate shares the same Iterator state as the manual iterator_next +
    // get_component form — they must be freely mixable on the same `it`.
    @(test)
    iterate_mixed_with_manual_next__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table(Position)
        ais: ecs.Table(AI)
        view: ecs.View

        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&positions, &ais}) == nil)

        for i in 0 ..< 4 {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            pos, _ := ecs.add_component(&positions, eid)
            pos^ = Position{x = i}
            ai, _ := ecs.add_component(&ais, eid)
            ai^ = AI{neurons_count = 1}
        }

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)

        // First row via the sugar...
        pos, ai, cond := ecs.iterate(&it, &positions, &ais)
        testing.expect(t, cond == true)
        pos.x += ai.neurons_count

        // ...remaining rows via the manual form, continuing the same cursor.
        remaining := 0
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&positions, &it)
            p.x += 1
            remaining += 1
        }
        testing.expect(t, remaining == 3)

        sum := 0
        for &p in positions.rows {
            sum += p.x
        }
        // one row got +1 (neurons_count), three rows got +1 each (manual loop)
        testing.expect(t, sum == (0 + 1 + 2 + 3) + 1 + 3)
    }

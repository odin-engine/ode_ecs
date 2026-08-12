/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for ecs.next(&it, ...) over a View-based Iterator (iterator.odin's
    iterator__next0..next7) — like ecs.iterate, but also returns the entity id
    and goes up to arity 7 instead of 4.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs ".."

///////////////////////////////////////////////////////////////////////////////
// ecs.next — for-in sugar over Iterator + Table($T) columns

    @(test)
    // ecs.next(&it) with no table args is plain iterator__next (bool advance,
    // now in the same `next` group) — get_entity/get_component called manually.
    iterator_next0_type_free__test :: proc(t: ^testing.T) {
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

        eids: [5]ecs.entity_id
        for i in 0 ..< 5 {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            eids[i] = eid
            pos, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)
            pos^ = Position{x = i, y = 0}
        }

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)

        count := 0
        for ecs.next(&it) {
            eid := ecs.get_entity(&it)
            pos := ecs.get_component(&positions, eid)
            testing.expect(t, pos != nil)
            pos.x += 100
            count += 1
        }
        testing.expect(t, count == 5)

        sum := 0
        for &pos in positions.rows {
            sum += pos.x
        }
        testing.expect(t, sum == 100 * 5 + (0 + 1 + 2 + 3 + 4))
    }

    @(test)
    iterator_next1_one_table__test :: proc(t: ^testing.T) {
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
        for eid, pos in ecs.next(&it, &positions) {
            testing.expect(t, ecs.get_component(&positions, eid) == pos)
            pos.x += 100
            count += 1
        }
        testing.expect(t, count == 5)

        sum := 0
        for &pos in positions.rows {
            sum += pos.x
        }
        testing.expect(t, sum == 100 * 5 + (0 + 1 + 2 + 3 + 4))
    }

    @(test)
    iterator_next2_two_tables__test :: proc(t: ^testing.T) {
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
        for eid, pos, ai in ecs.next(&it, &positions, &ais) {
            testing.expect(t, ecs.get_component(&ais, eid) == ai)
            pos.x += ai.neurons_count
            count += 1
        }
        testing.expect(t, count == 3)

        expected_x := (0 + 0) + (1 + 1) + (2 + 2)
        sum := 0
        for &pos in positions.rows {
            sum += pos.x
        }
        testing.expect(t, sum == expected_x)
    }

    @(test)
    iterator_next_empty_view__test :: proc(t: ^testing.T) {
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
        for eid, pos in ecs.next(&it, &positions) {
            _ = eid
            _ = pos
            count += 1
        }
        testing.expect(t, count == 0)
    }

    // ecs.next shares the same Iterator state as the manual iterator_next +
    // get_component form — they must be freely mixable on the same `it`.
    @(test)
    iterator_next_mixed_with_manual_next__test :: proc(t: ^testing.T) {
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

        // First row via the next() sugar...
        eid, pos, ai, cond := ecs.next(&it, &positions, &ais)
        testing.expect(t, cond == true)
        testing.expect(t, ecs.get_component(&ais, eid) == ai)
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
        testing.expect(t, sum == (0 + 1 + 2 + 3) + 1 + 3)
    }

    // Proves the extended arity (beyond iterate1..4's cap of 4) actually works.
    @(test)
    iterator_next7_wide_arity__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        C1 :: struct { v: int }
        C2 :: struct { v: int }
        C3 :: struct { v: int }
        C4 :: struct { v: int }
        C5 :: struct { v: int }
        C6 :: struct { v: int }
        C7 :: struct { v: int }

        db: ecs.Database
        t1: ecs.Table(C1)
        t2: ecs.Table(C2)
        t3: ecs.Table(C3)
        t4: ecs.Table(C4)
        t5: ecs.Table(C5)
        t6: ecs.Table(C6)
        t7: ecs.Table(C7)
        view: ecs.View

        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&t1, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t2, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t3, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t4, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t5, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t6, &db, 10) == nil)
        testing.expect(t, ecs.table_init(&t7, &db, 10) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&t1, &t2, &t3, &t4, &t5, &t6, &t7}) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        ecs.add_component(&t1, eid)
        ecs.get_component(&t1, eid).v = 1
        ecs.add_component(&t2, eid)
        ecs.get_component(&t2, eid).v = 2
        ecs.add_component(&t3, eid)
        ecs.get_component(&t3, eid).v = 3
        ecs.add_component(&t4, eid)
        ecs.get_component(&t4, eid).v = 4
        ecs.add_component(&t5, eid)
        ecs.get_component(&t5, eid).v = 5
        ecs.add_component(&t6, eid)
        ecs.get_component(&t6, eid).v = 6
        ecs.add_component(&t7, eid)
        ecs.get_component(&t7, eid).v = 7

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)

        count := 0
        for _, c1, c2, c3, c4, c5, c6, c7 in ecs.next(&it, &t1, &t2, &t3, &t4, &t5, &t6, &t7) {
            testing.expect(t, c1.v == 1 && c2.v == 2 && c3.v == 3 && c4.v == 4 && c5.v == 5 && c6.v == 6 && c7.v == 7)
            count += 1
        }
        testing.expect(t, count == 1)
    }

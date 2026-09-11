/*
    2026 (c) Oleh, https://github.com/zm69
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// get_component_unchecked / get_component_mut_unchecked
//
// NOTE: the one behavior these procs intentionally do NOT guard against —
// a stale (recycled) entity_id silently returning the wrong entity's data
// instead of nil or crashing — is not exercised here. That's the documented
// hazard of "unchecked": the caller opts out of the generation check, so
// there is nothing for a test to assert other than "the library trusts you".

    @(test)
    unchecked_access__table__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        positions: ecs.Table(Position)
        defer ecs.table_terminate(&positions)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

        with_pos, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        p, perr := ecs.add_component(&positions, with_pos)
        testing.expect(t, perr == nil)
        p.x = 1
        p.y = 2

        without_pos, oerr := ecs.create_entity(&db)
        testing.expect(t, oerr == nil)

        checked := ecs.get_component(&positions, with_pos)
        unchecked := ecs.get_component_unchecked(&positions, with_pos)
        testing.expect(t, unchecked == checked)
        testing.expect(t, unchecked.x == 1 && unchecked.y == 2)

        testing.expect(t, ecs.get_component_unchecked(&positions, without_pos) == nil)

        checked_mut := ecs.get_component_mut(&positions, with_pos)
        unchecked_mut := ecs.get_component_mut_unchecked(&positions, with_pos)
        testing.expect(t, unchecked_mut == checked_mut)
        testing.expect(t, ecs.get_component_mut_unchecked(&positions, without_pos) == nil)
    }

    @(test)
    unchecked_access__compact_table__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        ais: ecs.Compact_Table(AI)
        defer ecs.compact_table__terminate(&ais)
        testing.expect(t, ecs.compact_table__init(&ais, &db, 10) == nil)

        with_ai, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        a, aerr := ecs.add_component(&ais, with_ai)
        testing.expect(t, aerr == nil)
        a.neurons_count = 42

        without_ai, oerr := ecs.create_entity(&db)
        testing.expect(t, oerr == nil)

        checked := ecs.get_component(&ais, with_ai)
        unchecked := ecs.get_component_unchecked(&ais, with_ai)
        testing.expect(t, unchecked == checked)
        testing.expect(t, unchecked.neurons_count == 42)

        testing.expect(t, ecs.get_component_unchecked(&ais, without_ai) == nil)

        checked_mut := ecs.get_component_mut(&ais, with_ai)
        unchecked_mut := ecs.get_component_mut_unchecked(&ais, with_ai)
        testing.expect(t, unchecked_mut == checked_mut)
        testing.expect(t, ecs.get_component_mut_unchecked(&ais, without_ai) == nil)
    }

    @(test)
    unchecked_access__tiny_table__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        ais: ecs.Tiny_Table(AI)
        defer ecs.tiny_table__terminate(&ais)
        testing.expect(t, ecs.tiny_table__init(&ais, &db) == nil)

        with_ai, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        a, aerr := ecs.add_component(&ais, with_ai)
        testing.expect(t, aerr == nil)
        a.neurons_count = 7

        without_ai, oerr := ecs.create_entity(&db)
        testing.expect(t, oerr == nil)

        checked := ecs.get_component(&ais, with_ai)
        unchecked := ecs.get_component_unchecked(&ais, with_ai)
        testing.expect(t, unchecked == checked)
        testing.expect(t, unchecked.neurons_count == 7)

        testing.expect(t, ecs.get_component_unchecked(&ais, without_ai) == nil)

        checked_mut := ecs.get_component_mut(&ais, with_ai)
        unchecked_mut := ecs.get_component_mut_unchecked(&ais, with_ai)
        testing.expect(t, unchecked_mut == checked_mut)
        testing.expect(t, ecs.get_component_mut_unchecked(&ais, without_ai) == nil)
    }

    @(test)
    unchecked_access__arch_table__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        with_row, err := ecs.create_entity(&at)
        testing.expect(t, err == nil)
        pos := ecs.get_component(&at, with_row, Position)
        pos.x = 3
        pos.y = 4

        without_row, oerr := ecs.create_entity(&db)
        testing.expect(t, oerr == nil)

        checked := ecs.get_component(&at, with_row, Position)
        unchecked := ecs.get_component_unchecked(&at, with_row, Position)
        testing.expect(t, unchecked == checked)
        testing.expect(t, unchecked.x == 3 && unchecked.y == 4)

        testing.expect(t, ecs.get_component_unchecked(&at, without_row, Position) == nil)
    }

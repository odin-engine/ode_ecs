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
// remove_components / destroy_entities

    @(test)
    batch_remove__table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        N :: 20

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, N, allocator) == nil)

        positions: ecs.Table(Position)
        defer ecs.table_terminate(&positions)
        testing.expect(t, ecs.table_init(&positions, &db, N) == nil)

        view: ecs.View
        defer ecs.view_terminate(&view)
        testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)

        eids: [N]ecs.entity_id
        for i in 0..<N {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            p, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)
            p.x = i
            eids[i] = eid
        }

        // An expired eid: capture, then destroy — a stale copy of an id whose slot has since
        // been freed (generation bump happens on reuse, not on free, but the free itself already
        // makes the captured id read as expired against the now-DELETED_INDEX slot).
        stale_id := eids[19]
        testing.expect(t, ecs.destroy_entity(&db, eids[19]) == nil)

        // Scattered batch: 7 unique targets, a duplicate (already removed mid-batch), and the
        // now-expired id — all three "skip, not fatal" cases the plan calls for in one call.
        removed_indices := []int{0, 3, 6, 9, 12, 15, 18}
        batch := make([]ecs.entity_id, len(removed_indices) + 2, allocator)
        defer delete(batch, allocator)
        for idx, i in removed_indices do batch[i] = eids[idx]
        batch[len(removed_indices)] = eids[0]  // duplicate
        batch[len(removed_indices) + 1] = stale_id  // expired

        removed, rerr := ecs.remove_components(&positions, batch)
        testing.expect(t, rerr == nil)
        testing.expect(t, removed == len(removed_indices))

        removed_set: [N]bool
        for idx in removed_indices do removed_set[idx] = true

        testing.expect(t, ecs.table_len(&positions) == N - 1 - len(removed_indices)) // -1 for the destroyed entity
        for i in 0..<19 { // 19 was destroyed, its own component is gone regardless
            expect_present := !removed_set[i]
            testing.expect(t, ecs.has_component(&positions, eids[i]) == expect_present)
            if expect_present {
                testing.expect(t, ecs.get_component(&positions, eids[i]).x == i)
            }
        }

        // View reflects the same surviving set, order-independent.
        testing.expect(t, ecs.view_len(&view) == N - 1 - len(removed_indices))
        seen: [N]bool
        for p in ecs.slice(&view, Position) {
            testing.expect(t, !seen[p.x]) // no duplicates in the view
            seen[p.x] = true
        }
        for i in 0..<19 {
            testing.expect(t, seen[i] == !removed_set[i])
        }
    }

    @(test)
    batch_remove__table_full_population__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        N :: 16

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, N, allocator) == nil)

        positions: ecs.Table(Position)
        defer ecs.table_terminate(&positions)
        testing.expect(t, ecs.table_init(&positions, &db, N) == nil)

        eids := make([]ecs.entity_id, N, allocator)
        defer delete(eids, allocator)
        for i in 0..<N {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            _, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)
            eids[i] = eid
        }

        // The scenario table__remove_components is actually optimized for: removing the table's
        // entire current population in one call.
        removed, rerr := ecs.remove_components(&positions, eids)
        testing.expect(t, rerr == nil)
        testing.expect(t, removed == N)
        testing.expect(t, ecs.table_len(&positions) == 0)
        for eid in eids do testing.expect(t, !ecs.has_component(&positions, eid))
    }

    @(test)
    batch_remove__table_with_group__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        N :: 10

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, N, allocator) == nil)

        positions: ecs.Table(Position)
        ais: ecs.Table(AI)
        defer ecs.table_terminate(&positions)
        defer ecs.table_terminate(&ais)
        testing.expect(t, ecs.table_init(&positions, &db, N) == nil)
        testing.expect(t, ecs.table_init(&ais, &db, N) == nil)

        group: ecs.Group
        defer ecs.group_terminate(&group)
        testing.expect(t, ecs.group_init(&group, &db, {&positions, &ais}) == nil)

        eids: [N]ecs.entity_id
        for i in 0..<N {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            p, _ := ecs.add_component(&positions, eid)
            p.x = i
            a, _ := ecs.add_component(&ais, eid)
            a.neurons_count = i
            eids[i] = eid
        }
        testing.expect(t, ecs.group_len(&group) == N)

        removed_indices := []int{1, 4, 7}
        batch := make([]ecs.entity_id, len(removed_indices), allocator)
        defer delete(batch, allocator)
        for idx, i in removed_indices do batch[i] = eids[idx]

        removed, rerr := ecs.remove_components(&positions, batch)
        testing.expect(t, rerr == nil)
        testing.expect(t, removed == len(removed_indices))

        // Removing Position drops these entities out of the group (they no longer own both
        // owned tables); the AI component itself is untouched.
        testing.expect(t, ecs.group_len(&group) == N - len(removed_indices))
        for idx in removed_indices {
            testing.expect(t, ecs.has_component(&ais, eids[idx])) // AI untouched
            testing.expect(t, !ecs.has_component(&positions, eids[idx]))
        }
    }

    @(test)
    batch_remove__compact_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        N :: 20

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, N, allocator) == nil)

        ais: ecs.Compact_Table(AI)
        defer ecs.compact_table__terminate(&ais)
        testing.expect(t, ecs.compact_table__init(&ais, &db, N) == nil)

        eids: [N]ecs.entity_id
        for i in 0..<N {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            a, aerr := ecs.add_component(&ais, eid)
            testing.expect(t, aerr == nil)
            a.neurons_count = i
            eids[i] = eid
        }

        stale_id := eids[19]
        testing.expect(t, ecs.destroy_entity(&db, eids[19]) == nil)

        removed_indices := []int{0, 2, 5, 9, 13, 17}
        batch := make([]ecs.entity_id, len(removed_indices) + 2, allocator)
        defer delete(batch, allocator)
        for idx, i in removed_indices do batch[i] = eids[idx]
        batch[len(removed_indices)] = eids[0]
        batch[len(removed_indices) + 1] = stale_id

        removed, rerr := ecs.remove_components(&ais, batch)
        testing.expect(t, rerr == nil)
        testing.expect(t, removed == len(removed_indices))

        removed_set: [N]bool
        for idx in removed_indices do removed_set[idx] = true

        testing.expect(t, ecs.compact_table__len(&ais) == N - 1 - len(removed_indices))
        for i in 0..<19 {
            expect_present := !removed_set[i]
            testing.expect(t, ecs.has_component(&ais, eids[i]) == expect_present)
            if expect_present {
                testing.expect(t, ecs.get_component(&ais, eids[i]).neurons_count == i)
            }
        }
    }

    @(test)
    batch_remove__tiny_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        N :: ecs.TINY_TABLE__ROW_CAP // 8

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, N, allocator) == nil)

        ais: ecs.Tiny_Table(AI)
        defer ecs.tiny_table__terminate(&ais)
        testing.expect(t, ecs.tiny_table__init(&ais, &db) == nil)

        eids: [N]ecs.entity_id
        for i in 0..<N {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            a, aerr := ecs.add_component(&ais, eid)
            testing.expect(t, aerr == nil)
            a.neurons_count = i
            eids[i] = eid
        }

        stale_id := eids[N - 1]
        testing.expect(t, ecs.destroy_entity(&db, eids[N - 1]) == nil)

        removed_indices := []int{0, 2, 4}
        batch := make([]ecs.entity_id, len(removed_indices) + 2, allocator)
        defer delete(batch, allocator)
        for idx, i in removed_indices do batch[i] = eids[idx]
        batch[len(removed_indices)] = eids[0]
        batch[len(removed_indices) + 1] = stale_id

        removed, rerr := ecs.remove_components(&ais, batch)
        testing.expect(t, rerr == nil)
        testing.expect(t, removed == len(removed_indices))

        removed_set: [N]bool
        for idx in removed_indices do removed_set[idx] = true

        testing.expect(t, ecs.tiny_table__len(&ais) == N - 1 - len(removed_indices))
        for i in 0..<N - 1 {
            expect_present := !removed_set[i]
            testing.expect(t, ecs.has_component(&ais, eids[i]) == expect_present)
            if expect_present {
                testing.expect(t, ecs.get_component(&ais, eids[i]).neurons_count == i)
            }
        }
    }

    @(test)
    destroy_entities__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        N :: 10

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, N, allocator) == nil)

        positions: ecs.Table(Position)
        defer ecs.table_terminate(&positions)
        testing.expect(t, ecs.table_init(&positions, &db, N) == nil)

        eids: [N]ecs.entity_id
        for i in 0..<N {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            _, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)
            eids[i] = eid
        }

        stale_id := eids[9]
        testing.expect(t, ecs.destroy_entity(&db, eids[9]) == nil)

        to_destroy_indices := []int{0, 2, 4, 6}
        batch := make([]ecs.entity_id, len(to_destroy_indices) + 2, allocator)
        defer delete(batch, allocator)
        for idx, i in to_destroy_indices do batch[i] = eids[idx]
        batch[len(to_destroy_indices)] = eids[0] // already destroyed by this same call
        batch[len(to_destroy_indices) + 1] = stale_id // already expired before this call

        destroyed, derr := ecs.destroy_entities(&db, batch)
        testing.expect(t, derr == nil)
        testing.expect(t, destroyed == len(to_destroy_indices))

        for idx in to_destroy_indices {
            testing.expect(t, ecs.is_expired(&db, eids[idx]))
        }
        for i in ([]int{1, 3, 5, 7, 8}) {
            testing.expect(t, !ecs.is_expired(&db, eids[i]))
            testing.expect(t, ecs.has_component(&positions, eids[i]))
        }
    }

/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Observer (observer.odin): structural-change callbacks. The
    feature is off by default (see ecs.OBSERVERS_ENABLED's doc comment) — this
    whole file only exists when it's compiled in: run with
    -define:ECS_OBSERVERS_ENABLED=true.
*/
package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs ".."
    import oc "../ode_core"

when ecs.OBSERVERS_ENABLED {

///////////////////////////////////////////////////////////////////////////////
// Shared recording helper

    Observer_Log_Entry :: struct {
        kind:          ecs.Observer_Event_Kind,
        eid:           ecs.entity_id,
        table_id:      ecs.table_id,
        pair_table_id: ecs.pair_table_id,
        related:       ecs.entity_id,
        // *(^int)event.data at fire time, when event.data != nil; 0 otherwise.
        // Valid because every payload type used in these tests (Position,
        // Likes_Data) has an int as its first field.
        data_int: int,
    }

    Observer_Log :: struct {
        entries: [32]Observer_Log_Entry,
        count:   int,
    }

    observer_log_callback :: proc(event: ^ecs.Observer_Event, user_data: rawptr) {
        log := cast(^Observer_Log) user_data
        if log.count >= len(log.entries) do return

        data_int := 0
        if event.data != nil do data_int = (cast(^int) event.data)^

        log.entries[log.count] = Observer_Log_Entry{
            kind = event.kind, eid = event.eid, table_id = event.table_id,
            pair_table_id = event.pair_table_id, related = event.related, data_int = data_int,
        }
        log.count += 1
    }

    // Search helper for tests where event order isn't guaranteed (e.g. the
    // target-destroy pair cascade, whose order depends on target-side
    // linked-list insertion order, not test code).
    observer_log__has :: proc(log: ^Observer_Log, kind: ecs.Observer_Event_Kind, eid: ecs.entity_id, related: ecs.entity_id) -> bool {
        for i in 0..<log.count {
            e := log.entries[i]
            if e.kind == kind && e.eid == eid && e.related == related do return true
        }
        return false
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    observer__structural_lifecycle_events__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        positions: ecs.Table(Position)
        defer ecs.table_terminate(&positions)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

        rec: Observer_Log
        obs: ecs.Observer
        defer ecs.observer_terminate(&obs)
        testing.expect(t, ecs.observer_init(&obs, &db, observer_log_callback, user_data = &rec) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)

        // add_component hands back a pointer for the CALLER to fill in — the
        // Component_Added observer fires before that write, so it sees the
        // freshly-zeroed slot (data_int == 0). This mirrors Sync's own
        // notify_sync_add timing, not a bug.
        pos, aerr := ecs.add_component(&positions, eid)
        testing.expect(t, aerr == nil)
        pos^ = Position{x = 7, y = 8}

        // Component_Removed fires BEFORE the swap/zero, so it must still see 7 —
        // this is the actual regression test for that timing decision.
        rerr := ecs.remove_component(&positions, eid)
        testing.expect(t, rerr == nil)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)

        testing.expect(t, rec.count == 4)
        testing.expect(t, rec.entries[0].kind == .Entity_Created && rec.entries[0].eid == eid)
        testing.expect(t, rec.entries[1].kind == .Component_Added && rec.entries[1].table_id == positions.id)
        testing.expect(t, rec.entries[2].kind == .Component_Removed && rec.entries[2].table_id == positions.id && rec.entries[2].data_int == 7)
        testing.expect(t, rec.entries[3].kind == .Entity_Destroyed && rec.entries[3].eid == eid)
    }

    @(test)
    observer__tag_and_arch_events__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        alive: ecs.Tag_Table
        defer ecs.tag_table__terminate(&alive)
        testing.expect(t, ecs.tag_table__init(&alive, &db, 10) == nil)

        arch: ecs.Arch_Table
        defer ecs.arch_table__terminate(&arch)
        testing.expect(t, ecs.arch_table__init(&arch, &db, 10, {Position}) == nil)

        rec: Observer_Log
        obs: ecs.Observer
        defer ecs.observer_terminate(&obs)
        testing.expect(t, ecs.observer_init(&obs, &db, observer_log_callback, user_data = &rec) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.tag(&alive, eid) == nil)
        testing.expect(t, ecs.untag(&alive, eid) == nil)

        testing.expect(t, ecs.arch_table__add_entity(&arch, eid) == nil)
        testing.expect(t, ecs.arch_table__remove_entity(&arch, eid) == nil)

        testing.expect(t, rec.count == 5)
        testing.expect(t, rec.entries[1].kind == .Tag_Added && rec.entries[1].table_id == alive.id)
        testing.expect(t, rec.entries[2].kind == .Tag_Removed && rec.entries[2].table_id == alive.id)
        testing.expect(t, rec.entries[3].kind == .Arch_Entity_Added && rec.entries[3].table_id == arch.id)
        testing.expect(t, rec.entries[4].kind == .Arch_Entity_Removed && rec.entries[4].table_id == arch.id)
    }

    @(test)
    observer__enable_disable_events__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        positions: ecs.Table(Position)
        defer ecs.table_terminate(&positions)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

        rec: Observer_Log
        obs: ecs.Observer
        defer ecs.observer_terminate(&obs)
        testing.expect(t, ecs.observer_init(&obs, &db, observer_log_callback, user_data = &rec) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        _, aerr := ecs.add_component(&positions, eid)
        testing.expect(t, aerr == nil)

        testing.expect(t, ecs.disable_component(&positions, eid) == nil)
        testing.expect(t, ecs.enable_component(&positions, eid) == nil)

        testing.expect(t, rec.count == 4)
        testing.expect(t, rec.entries[2].kind == .Component_Disabled && rec.entries[2].table_id == positions.id)
        testing.expect(t, rec.entries[3].kind == .Component_Enabled && rec.entries[3].table_id == positions.id)
    }

    @(test)
    observer__relations_events__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        rt: ecs.Relations_Table
        defer ecs.relations_table__terminate(&rt)
        testing.expect(t, ecs.relations_init(&rt, &db, 10) == nil)

        rec: Observer_Log
        obs: ecs.Observer
        defer ecs.observer_terminate(&obs)
        testing.expect(t, ecs.observer_init(&obs, &db, observer_log_callback, user_data = &rec) == nil)

        parent, perr := ecs.create_entity(&db)
        testing.expect(t, perr == nil)
        child, cerr := ecs.create_entity(&db)
        testing.expect(t, cerr == nil)

        testing.expect(t, ecs.set_parent(&db, child, parent) == nil)

        // No-fire edge case: re-parenting to the SAME parent is a documented no-op.
        count_after_set := rec.count
        testing.expect(t, ecs.set_parent(&db, child, parent) == nil)
        testing.expect(t, rec.count == count_after_set)

        testing.expect(t, ecs.remove_parent(&db, child) == nil)

        // No-fire edge case: remove_parent on a now-childless entity is Not_Found.
        count_after_remove := rec.count
        testing.expect(t, ecs.remove_parent(&db, child) == oc.Core_Error.Not_Found)
        testing.expect(t, rec.count == count_after_remove)

        testing.expect(t, rec.count == 4) // 2x Entity_Created, Parent_Set, Parent_Removed
        testing.expect(t, rec.entries[2].kind == .Parent_Set && rec.entries[2].eid == child && rec.entries[2].related == parent)
        testing.expect(t, rec.entries[3].kind == .Parent_Removed && rec.entries[3].eid == child && rec.entries[3].related == parent)
    }

    @(test)
    observer__pair_events__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        pt: ecs.Pair_Table(Likes_Data)
        defer ecs.pair_table__terminate(&pt)
        testing.expect(t, ecs.pair_init(&pt, &db, holders_cap = 10, pairs_cap = 10) == nil)

        rec: Observer_Log
        obs: ecs.Observer
        defer ecs.observer_terminate(&obs)
        testing.expect(t, ecs.observer_init(&obs, &db, observer_log_callback, user_data = &rec) == nil)

        alice, aerr := ecs.create_entity(&db)
        testing.expect(t, aerr == nil)
        bob, berr := ecs.create_entity(&db)
        testing.expect(t, berr == nil)
        carol, cerr := ecs.create_entity(&db)
        testing.expect(t, cerr == nil)

        _, err1 := ecs.pair_add(&pt, alice, bob, Likes_Data{strength = 5})
        testing.expect(t, err1 == nil)
        _, err2 := ecs.pair_add(&pt, carol, bob, Likes_Data{strength = 9})
        testing.expect(t, err2 == nil)

        testing.expect(t, observer_log__has(&rec, .Pair_Added, alice, bob))
        testing.expect(t, observer_log__has(&rec, .Pair_Added, carol, bob))

        // Destroying the TARGET cascades through pair_table_base__unlink_row for
        // every referencing holder — the single-hook design means both alice's
        // and carol's pairs fire Pair_Removed, with no extra plumbing.
        testing.expect(t, ecs.destroy_entity(&db, bob) == nil)

        testing.expect(t, observer_log__has(&rec, .Pair_Removed, alice, bob))
        testing.expect(t, observer_log__has(&rec, .Pair_Removed, carol, bob))

        // Each pair_add is alice/carol's FIRST pair, so it also tags `presence`
        // (Tag_Added); each cascade removal is their LAST pair, so it also
        // untags it (Tag_Removed) — presence is an ordinary Tag_Table (see
        // pair_table.md), so it fires observer events like any other.
        testing.expect(t, rec.count == 3 /*created*/ + 2*2 /*added + presence tag*/ + 1 /*bob destroyed*/ + 2*2 /*removed + presence untag*/)
    }

    @(test)
    observer__interested_in_filter__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        rec: Observer_Log
        obs: ecs.Observer
        defer ecs.observer_terminate(&obs)
        testing.expect(t, ecs.observer_init(&obs, &db, observer_log_callback, interested_in = {.Entity_Created}, user_data = &rec) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.destroy_entity(&db, eid) == nil) // must NOT be logged

        testing.expect(t, rec.count == 1)
        testing.expect(t, rec.entries[0].kind == .Entity_Created)
    }

    @(test)
    observer__database_auto_terminate__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        rec: Observer_Log
        obs: ecs.Observer
        testing.expect(t, ecs.observer_init(&obs, &db, observer_log_callback, user_data = &rec) == nil)

        _, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)

        // No explicit observer_terminate — database termination alone must free it.
        testing.expect(t, ecs.terminate(&db) == nil)
        testing.expect(t, obs.state == ecs.Object_State.Not_Initialized)

        // Explicitly terminating an already-database-terminated Observer is a
        // clean, expected no-op error, not a crash/double-free.
        testing.expect(t, ecs.observer_terminate(&obs) == ecs.API_Error.Object_Invalid)
    }

    @(test)
    observer__command_buffer_replay_fires_events__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        positions: ecs.Table(Position)
        defer ecs.table_terminate(&positions)
        testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

        cb: ecs.Command_Buffer
        defer ecs.command_buffer_terminate(&cb)
        testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 256) == nil)

        rec: Observer_Log
        obs: ecs.Observer
        defer ecs.observer_terminate(&obs)
        testing.expect(t, ecs.observer_init(&obs, &db, observer_log_callback, user_data = &rec) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)

        count_before_record := rec.count
        testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{x = 3, y = 4}) == nil)
        testing.expect(t, rec.count == count_before_record) // recording alone must not fire anything

        skipped, rerr := ecs.replay(&cb)
        testing.expect(t, rerr == nil && skipped == 0)

        testing.expect(t, rec.count == count_before_record + 1)
        last := rec.entries[rec.count - 1]
        // Unlike direct add_component (test 1 above), cmd_add_component supplies
        // the value up front, so the observer sees it immediately, not zeroed.
        testing.expect(t, last.kind == .Component_Added && last.table_id == positions.id && last.data_int == 3)
    }

} // when ecs.OBSERVERS_ENABLED

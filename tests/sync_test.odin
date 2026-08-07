/*
    2026 (c) Oleh, https://github.com/zm69

    Public-surface tests for delta-change replication (sync.odin), exercising
    only ecs.sync_register/collect_delta/apply_delta/get_component_mut through
    their public aliases — mirrors how serialization_test.odin relates to the
    internal serialization tests.

    No context.logger override here on purpose: testing.expect's pass/fail
    tracking relies on the test runner's own logger (see core:testing's
    test_logger_proc) — overriding context.logger with a plain console logger
    silently breaks that tracking, so failures would print but not fail the run.
*/
package ode_ecs__tests

// Core
    import "core:testing"
    import "core:mem"

// ODE
    import ecs ".."

// The sync feature is off by default (see ecs.SYNC_ENABLED's doc comment) —
// with it off, ecs.sync_register always returns Sync_Feature_Disabled, so
// these tests' setup helper (which doesn't check that return value further
// than one testing.expect) goes on to dereference state that was never
// actually registered. Rather than harden every call site against a
// deliberately-unsupported configuration, this whole file only exists when
// the feature is compiled in: run with -define:ECS_SYNC_ENABLED=true.
when ecs.SYNC_ENABLED {

///////////////////////////////////////////////////////////////////////////////
// Sender + receiver share entity identity via a common Overbase — mirrors how
// two real processes in a client/server pair agree on entity ids.

    Sync_Pub_World :: struct {
        ob:        ecs.Overbase,
        db_send:   ecs.Database,
        db_recv:   ecs.Database,
        pos_send:  ecs.Table(Position),
        pos_recv:  ecs.Table(Position),
        ai_send:   ecs.Compact_Table(AI),
        ai_recv:   ecs.Compact_Table(AI),
        alive_send: ecs.Tag_Table,
        alive_recv: ecs.Tag_Table,
        ch:  ecs.Sync_Channel,
        dec: ecs.Sync_Decoder,
    }

    sync_pub_world__init :: proc(t: ^testing.T, w: ^Sync_Pub_World, entities_cap: int, allocator: mem.Allocator) {
        testing.expect(t, ecs.overbase_init(&w.ob, entities_cap, 2, allocator) == nil)
        testing.expect(t, ecs.init_from_overbase(&w.db_send, &w.ob) == nil)
        testing.expect(t, ecs.init_from_overbase(&w.db_recv, &w.ob) == nil)

        testing.expect(t, ecs.table_init(&w.pos_send, &w.db_send, entities_cap) == nil)
        testing.expect(t, ecs.table_init(&w.pos_recv, &w.db_recv, entities_cap) == nil)
        testing.expect(t, ecs.compact_table__init(&w.ai_send, &w.db_send, entities_cap) == nil)
        testing.expect(t, ecs.compact_table__init(&w.ai_recv, &w.db_recv, entities_cap) == nil)
        testing.expect(t, ecs.tag_table__init(&w.alive_send, &w.db_send, entities_cap) == nil)
        testing.expect(t, ecs.tag_table__init(&w.alive_recv, &w.db_recv, entities_cap) == nil)

        testing.expect(t, ecs.sync_channel_init(&w.ch, &w.db_send, 4) == nil)
        testing.expect(t, ecs.sync_decoder_init(&w.dec, &w.db_recv, 4) == nil)

        testing.expect(t, ecs.sync_register(&w.ch, &w.pos_send) == nil)
        testing.expect(t, ecs.sync_register(&w.ch, &w.ai_send) == nil)
        testing.expect(t, ecs.sync_register(&w.ch, &w.alive_send) == nil)
        testing.expect(t, ecs.sync_register(&w.dec, &w.pos_recv) == nil)
        testing.expect(t, ecs.sync_register(&w.dec, &w.ai_recv) == nil)
        testing.expect(t, ecs.sync_register(&w.dec, &w.alive_recv) == nil)
    }

    sync_pub_world__terminate :: proc(w: ^Sync_Pub_World) {
        ecs.sync_channel_terminate(&w.ch)
        ecs.sync_decoder_terminate(&w.dec)
        ecs.terminate(&w.db_send)
        ecs.terminate(&w.db_recv)
        ecs.overbase_terminate(&w.ob)
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    // Field-level diffs across a Table and a Compact_Table converge the
    // receiver's values to the sender's after collect_delta -> apply_delta,
    // and only the mutated field's bytes make it onto the wire.
    @(test)
    sync_public_field_diff_round_trip__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        w: Sync_Pub_World
        defer sync_pub_world__terminate(&w)
        sync_pub_world__init(t, &w, 20, allocator)

        eid, eerr := ecs.create_entity(&w.ob)
        testing.expect(t, eerr == nil)

        pos, perr := ecs.add_component(&w.pos_send, eid)
        testing.expect(t, perr == nil)
        pos.x = 1
        pos.y = 2

        ai, aierr := ecs.add_component(&w.ai_send, eid)
        testing.expect(t, aierr == nil)
        ai.IQ = 100
        ai.neurons_count = 1000

        buf := make([]byte, ecs.delta_max_size(&w.ch), allocator)
        defer delete(buf, allocator)

        written, werr := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, ecs.apply_delta(&w.dec, buf[:written]) == nil)

        rpos := ecs.get_component(&w.pos_recv, eid)
        testing.expect(t, rpos != nil)
        testing.expect(t, rpos.x == 1 && rpos.y == 2)

        rai := ecs.get_component(&w.ai_recv, eid)
        testing.expect(t, rai != nil)
        testing.expect(t, rai.IQ == 100 && rai.neurons_count == 1000)

        // mutate only Position.y through get_component_mut; only that field's
        // bytes should cross, and the receiver's other values stay put
        mpos := ecs.get_component_mut(&w.pos_send, eid)
        mpos.y = 999

        written2, werr2 := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, werr2 == nil)
        testing.expect(t, ecs.apply_delta(&w.dec, buf[:written2]) == nil)

        rpos2 := ecs.get_component(&w.pos_recv, eid)
        testing.expect(t, rpos2.x == 1, "untouched field must not have been overwritten")
        testing.expect(t, rpos2.y == 999, "touched field must have converged")
    }

    // Tag_Table is structural-only (no component data) — add/remove tag
    // round-trips as presence, not bytes.
    @(test)
    sync_public_tag_table_structural__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        w: Sync_Pub_World
        defer sync_pub_world__terminate(&w)
        sync_pub_world__init(t, &w, 20, allocator)

        eid, eerr := ecs.create_entity(&w.ob)
        testing.expect(t, eerr == nil)

        testing.expect(t, ecs.add_tag(&w.alive_send, eid) == nil)

        buf := make([]byte, ecs.delta_max_size(&w.ch), allocator)
        defer delete(buf, allocator)

        written, werr := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, ecs.apply_delta(&w.dec, buf[:written]) == nil)
        testing.expect(t, ecs.has_tag(&w.alive_recv, eid))

        testing.expect(t, ecs.remove_tag(&w.alive_send, eid) == nil)
        written2, werr2 := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, werr2 == nil)
        testing.expect(t, ecs.apply_delta(&w.dec, buf[:written2]) == nil)
        testing.expect(t, !ecs.has_tag(&w.alive_recv, eid))
    }

    // resync composes with a full snapshot: after driving the receiver to the
    // sender's current state out-of-band (simulated here by hand-copying the
    // one component, standing in for database__serialize/deserialize), resync
    // must stop the channel from re-sending values the receiver already has.
    @(test)
    sync_public_resync_after_snapshot__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        w: Sync_Pub_World
        defer sync_pub_world__terminate(&w)
        sync_pub_world__init(t, &w, 20, allocator)

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        // baseline: header-only size with nothing pending, learned from the
        // channel itself rather than assuming its private wire-format layout
        header_only_size, hoerr := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, hoerr == nil)

        eid, eerr := ecs.create_entity(&w.ob)
        testing.expect(t, eerr == nil)

        pos, perr := ecs.add_component(&w.pos_send, eid)
        testing.expect(t, perr == nil)
        pos.x = 7
        pos.y = 8

        // simulate an out-of-band full snapshot having already delivered {7,8}
        rpos, rperr := ecs.add_component(&w.pos_recv, eid)
        testing.expect(t, rperr == nil)
        rpos^ = pos^

        testing.expect(t, ecs.resync(&w.ch) == nil)

        // nothing pending: resync dropped the structural-add + touch that
        // add_component generated, since the snapshot already covers them
        written, werr := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, written == header_only_size, "resync must leave no pending structural/value records behind")
    }

} // when ecs.SYNC_ENABLED

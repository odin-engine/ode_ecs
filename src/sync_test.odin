/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for sync.odin; run with `odin test . -define:ECS_SYNC_ENABLED=true`
*/
#+build !js
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:testing"

// ODE_CORE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Tests — only compiled in when SYNC_ENABLED, since with it off sync_register always returns Sync_Feature_Disabled and these tests' assumptions don't hold.

when SYNC_ENABLED {

    @(private="file")
    Sync_XY :: struct { x: int, y: int }

    // A structural "add" already marks the entity touched; repeated
    // get_component_mut calls on the same entity before the next collect must not add a duplicate touched entry.
    @(test)
    sync__mark_touched_dedup__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        tbl: Table(Sync_XY)
        ch: Sync_Channel
        defer database__terminate(&db)
        defer sync_channel__terminate(&ch)

        testing.expect(t, database__init(&db, 10, allocator) == nil)
        testing.expect(t, table__init(&tbl, &db, 10) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &tbl) == nil)

        eid_a, aerr := database__create_entity(&db)
        testing.expect(t, aerr == nil)
        ca, caerr := table__add_component(&tbl, eid_a)
        testing.expect(t, caerr == nil)
        ca.x = 1
        ca.y = 2

        _ = table__get_component_mut(&tbl, eid_a)
        _ = table__get_component_mut(&tbl, eid_a)
        _ = table__get_component_mut(&tbl, eid_a)

        testing.expect(t, len(ch.entries[0].touched.items) == 1)
        testing.expect(t, ch.entries[0].touched.items[0] == eid_a)

        eid_b, berr := database__create_entity(&db)
        testing.expect(t, berr == nil)
        _, cberr := table__add_component(&tbl, eid_b)
        testing.expect(t, cberr == nil)

        testing.expect(t, len(ch.entries[0].touched.items) == 2) // a genuinely different entity DOES add a second entry
    }

    // Only changed fields' bytes go on the wire — verified by exact byte-count.
    @(test)
    sync__field_mask_single_field_change__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        tbl: Table(Sync_XY)
        ch: Sync_Channel
        defer database__terminate(&db)
        defer sync_channel__terminate(&ch)

        testing.expect(t, database__init(&db, 10, allocator) == nil)
        testing.expect(t, table__init(&tbl, &db, 10) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &tbl) == nil)

        eid, eerr := database__create_entity(&db)
        testing.expect(t, eerr == nil)
        c, cerr := table__add_component(&tbl, eid)
        testing.expect(t, cerr == nil)
        c.x = 1
        c.y = 2

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        // brand new entity: both fields differ from the zeroed shadow, plus
        // the structural "added" event add_component itself queued
        written1, werr1 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr1 == nil)
        expected1 := size_of(Sync_Header) + size_of(Sync_Structural_Wire) + size_of(Sync_Table_Section_Header) + size_of(entity_id) + size_of(u32) + 2 * size_of(int)
        testing.expect(t, written1 == expected1, "expected both fields on the wire for a brand new component")

        // mutate only x
        mc := table__get_component_mut(&tbl, eid)
        mc.x = 100

        written2, werr2 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr2 == nil)
        expected2 := size_of(Sync_Header) + size_of(Sync_Table_Section_Header) + size_of(entity_id) + size_of(u32) + 1 * size_of(int)
        testing.expect(t, written2 == expected2, "expected exactly one field's bytes on the wire")

        // nothing touched since -> header only
        written3, werr3 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr3 == nil)
        testing.expect(t, written3 == size_of(Sync_Header))
    }

    // Regression test: shadow must be keyed by entity_id.ix, not row id, so a departed entity's bytes never leak to whoever reuses that ix — entities_cap=1 forces ix reuse, and the new entity writes identical bytes and must still be reported as "changed".
    @(test)
    sync__shadow_not_leaked_across_reused_entity_id__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        tbl: Table(Sync_XY)
        ch: Sync_Channel
        defer database__terminate(&db)
        defer sync_channel__terminate(&ch)

        testing.expect(t, database__init(&db, 1, allocator) == nil) // cap 1: forces ix reuse
        testing.expect(t, table__init(&tbl, &db, 1) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &tbl) == nil)

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        eid_a, aerr := database__create_entity(&db)
        testing.expect(t, aerr == nil)
        ca, caerr := table__add_component(&tbl, eid_a)
        testing.expect(t, caerr == nil)
        ca.x = 5
        ca.y = 5

        _, cerr1 := sync_collect_delta(&ch, buf) // shadow[eid_a.ix] := {5, 5}
        testing.expect(t, cerr1 == nil)

        testing.expect(t, database__destroy_entity(&db, eid_a) == nil) // removes the component -> zeroes the shadow slot

        eid_z, zerr := database__create_entity(&db) // reuses the same ix, bumped generation
        testing.expect(t, zerr == nil)
        testing.expect(t, eid_z.ix == eid_a.ix)
        testing.expect(t, eid_z != eid_a)

        cz, czerr := table__add_component(&tbl, eid_z)
        testing.expect(t, czerr == nil)
        cz.x = 5 // identical bytes to what A had
        cz.y = 5

        written, werr := sync_collect_delta(&ch, buf)
        testing.expect(t, werr == nil)
        // 2 structural events pending (A's removal, Z's add) plus Z's value record
        expected := size_of(Sync_Header) + 2 * size_of(Sync_Structural_Wire) + size_of(Sync_Table_Section_Header) + size_of(entity_id) + size_of(u32) + 2 * size_of(int)
        testing.expect(t, written == expected, "a reused entity id's matching-old-bytes value must still be reported as changed")
    }

    // An undersized buffer must flush exactly as much as fits, in order, and leave the rest correctly queued for the next call.
    @(test)
    sync__partial_collect_undersized_buffer__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        tbl: Table(Sync_XY)
        ch: Sync_Channel
        defer database__terminate(&db)
        defer sync_channel__terminate(&ch)

        testing.expect(t, database__init(&db, 10, allocator) == nil)
        testing.expect(t, table__init(&tbl, &db, 10) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &tbl) == nil)

        big_buf := make([]byte, 4096, allocator)
        defer delete(big_buf, allocator)

        eids: [3]entity_id
        for i in 0..<3 {
            eid, eerr := database__create_entity(&db)
            testing.expect(t, eerr == nil)
            eids[i] = eid
            c, cerr := table__add_component(&tbl, eid)
            testing.expect(t, cerr == nil)
            c.x = i + 1
            c.y = i + 1
        }

        // drain the 3 structural-add events + their initial values first, so
        // the partial-collect phase below deals with pure value records only
        _, derr := sync_collect_delta(&ch, big_buf)
        testing.expect(t, derr == nil)
        testing.expect(t, len(ch.entries[0].touched.items) == 0)
        testing.expect(t, len(ch.structural_events.items) == 0)

        // mutate BOTH fields: collect_delta's fit-check is a conservative worst-case, so small_buf sized to one record only lines up with reality when the record equals that worst case.
        for i in 0..<3 {
            mc := table__get_component_mut(&tbl, eids[i])
            mc.x = 100 + i
            mc.y = 100 + i
        }
        testing.expect(t, len(ch.entries[0].touched.items) == 3)

        record_size := size_of(entity_id) + size_of(u32) + 2 * size_of(int)
        small_buf := make([]byte, size_of(Sync_Header) + size_of(Sync_Table_Section_Header) + record_size, allocator)
        defer delete(small_buf, allocator)

        written1, werr1 := sync_collect_delta(&ch, small_buf)
        testing.expect(t, werr1 == nil)
        testing.expect(t, written1 == len(small_buf), "exactly one record should have fit")
        testing.expect(t, len(ch.entries[0].touched.items) == 2, "the other two must remain queued")

        written2, werr2 := sync_collect_delta(&ch, big_buf)
        testing.expect(t, werr2 == nil)
        expected2 := size_of(Sync_Header) + size_of(Sync_Table_Section_Header) + 2 * record_size
        testing.expect(t, written2 == expected2, "the second call must flush exactly the remaining two")
        testing.expect(t, len(ch.entries[0].touched.items) == 0)
    }

    // Structural add/remove round-trips through a Sync_Decoder onto a separate mirrored Database sharing the same Overbase (entity ids valid on both sides), also covering the "unknown/expired entity_id on apply is a tolerated skip" contract via a hand-crafted buffer.
    @(test)
    sync__structural_roundtrip_and_tolerated_skip__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        ob: Overbase
        db_send: Database
        db_recv: Database
        tag_send: Tag_Table
        tag_recv: Tag_Table
        ch: Sync_Channel
        dec: Sync_Decoder
        defer overbase__terminate(&ob)
        defer database__terminate(&db_send)
        defer database__terminate(&db_recv)
        defer sync_channel__terminate(&ch)
        defer sync_decoder__terminate(&dec)

        testing.expect(t, overbase__init(&ob, 10, 2, allocator) == nil)
        testing.expect(t, database__init_from_overbase(&db_send, &ob) == nil)
        testing.expect(t, database__init_from_overbase(&db_recv, &ob) == nil)

        testing.expect(t, tag_table__init(&tag_send, &db_send, 10) == nil)
        testing.expect(t, tag_table__init(&tag_recv, &db_recv, 10) == nil)

        testing.expect(t, sync_channel__init(&ch, &db_send, 4) == nil)
        testing.expect(t, sync_channel__register_tag_table(&ch, &tag_send) == nil)
        testing.expect(t, sync_decoder__init(&dec, &db_recv, 4) == nil)
        testing.expect(t, sync_decoder__register_tag_table(&dec, &tag_recv) == nil)

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        eid, eerr := overbase__create_entity(&ob)
        testing.expect(t, eerr == nil)

        testing.expect(t, tag_table__add_tag(&tag_send, eid) == nil)

        written, werr := sync_collect_delta(&ch, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, sync_apply_delta(&dec, buf[:written]) == nil)
        testing.expect(t, tag_table__has_tag(&tag_recv, eid))

        // tolerated skip: a structural event naming an entity the receiver
        // doesn't (yet) recognize as live must not error
        bogus := entity_id{ ix = 9999 }
        testing.expect(t, database__is_entity_correct(&db_recv, bogus) != nil) // sanity: really is invalid

        hdr := Sync_Header{ magic = SYNC_MAGIC, version = SYNC_VERSION, structural_count = 1 }
        mem.copy(&buf[0], &hdr, size_of(hdr))
        wire := Sync_Structural_Wire{ eid = bogus, table_id = u16(tag_send.id) | SYNC_STRUCTURAL_TAG_FLAG, added = 1 }
        mem.copy(&buf[size_of(Sync_Header)], &wire, size_of(wire))
        testing.expect(t, sync_apply_delta(&dec, buf[:size_of(Sync_Header) + size_of(Sync_Structural_Wire)]) == nil)

        testing.expect(t, tag_table__remove_tag(&tag_send, eid) == nil)
        written2, werr2 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr2 == nil)
        testing.expect(t, sync_apply_delta(&dec, buf[:written2]) == nil)
        testing.expect(t, !tag_table__has_tag(&tag_recv, eid))
    }

    // Arch_Table is out of scope for v1 — registering one must return a clear, documented error on both sides, not silently do nothing.
    @(test)
    sync__arch_table_registration_rejected__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        arch: Arch_Table
        ch: Sync_Channel
        dec: Sync_Decoder
        defer database__terminate(&db)
        defer arch_table__terminate(&arch)
        defer sync_channel__terminate(&ch)
        defer sync_decoder__terminate(&dec)

        testing.expect(t, database__init(&db, 10, allocator) == nil)
        testing.expect(t, arch_table__init(&arch, &db, 10, {Sync_XY}) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_decoder__init(&dec, &db, 4) == nil)

        testing.expect(t, sync_channel__register_arch_table(&ch, &arch) == API_Error.Sync_Table_Type_Not_Supported)
        testing.expect(t, sync_decoder__register_arch_table(&dec, &arch) == API_Error.Sync_Table_Type_Not_Supported)
    }

} // when SYNC_ENABLED

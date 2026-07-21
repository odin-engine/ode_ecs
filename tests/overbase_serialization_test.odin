/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Overbase serialization (overbase_serialization.odin) and for how
    Database's own serialize/deserialize behaves once attached to a shared
    Overbase (serialization.odin's owns_overbase gating). Together these
    replace the old "Serialization caveat" documented in docs/overbase.md: a
    shared Overbase's id-space is now saved/restored only through
    overbase_serialize/overbase_deserialize, and a sibling Database's own
    deserialize can no longer clobber it.

    Reuses Ob_Position/Ob_Sprite from overbase_test.odin.
*/
package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs ".."

///////////////////////////////////////////////////////////////////////////////
// Overbase-only round trip

    @(test)
    overbase_serialize_standalone__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // no allocations outside provided allocator

            ob: ecs.Overbase
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, allocator = allocator) == nil)

            eids: [5]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 5; i += 1 {
                eids[i], err = ecs.create_entity(&ob)
                testing.expect(t, err == nil)
            }
            testing.expect(t, ecs.destroy_entity(&ob, eids[2]) == nil)

            size, size_err := ecs.overbase_serialized_size(&ob)
            testing.expect(t, size_err == nil)
            testing.expect(t, size > 0)

            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)

            written, werr := ecs.overbase_serialize(&ob, buf)
            testing.expect(t, werr == nil)
            testing.expect(t, written == size)

            // Mutate after the snapshot: recycle eids[2]'s freed slot, then
            // free a currently-alive one too.
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            testing.expect(t, new_eid.ix == eids[2].ix)
            testing.expect(t, ecs.destroy_entity(&ob, eids[0]) == nil)

            // Restore
            testing.expect(t, ecs.overbase_deserialize(&ob, buf) == nil)

            testing.expect(t, ecs.entities_len(&ob) == 4)
            testing.expect(t, ecs.is_expired(&ob, eids[2])) // destroyed before the snapshot, still gone
            testing.expect(t, !ecs.is_expired(&ob, eids[0])) // destroyed only after the snapshot -> alive again
            testing.expect(t, !ecs.is_expired(&ob, eids[1]))
            testing.expect(t, !ecs.is_expired(&ob, eids[3]))
            testing.expect(t, !ecs.is_expired(&ob, eids[4]))
            testing.expect(t, ecs.is_expired(&ob, new_eid)) // created only after the snapshot -> rolled back

            // Deterministic: creating anew reproduces the exact same id that
            // new_eid had, since the factory state is byte-identical again.
            new_eid_2, nerr2 := ecs.create_entity(&ob)
            testing.expect(t, nerr2 == nil)
            testing.expect(t, new_eid_2 == new_eid)
    }

    @(test)
    overbase_serialize_robustness__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, allocator = allocator) == nil)

            _, err := ecs.create_entity(&ob)
            testing.expect(t, err == nil)

            size, _ := ecs.overbase_serialized_size(&ob)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.overbase_serialize(&ob, buf)
            testing.expect(t, serr == nil)

            // buffer too small for serialize
            {
                small := make([]byte, size - 1, allocator)
                defer delete(small, allocator)
                _, e := ecs.overbase_serialize(&ob, small)
                testing.expect(t, e == ecs.API_Error.Serialize_Buffer_Too_Small)
            }

            // truncated buffer
            testing.expect(t, ecs.overbase_deserialize(&ob, buf[:len(buf) - 10]) == ecs.API_Error.Snapshot_Invalid)

            // trailing garbage
            {
                bigger := make([]byte, size + 8, allocator)
                defer delete(bigger, allocator)
                copy(bigger, buf)
                testing.expect(t, ecs.overbase_deserialize(&ob, bigger) == ecs.API_Error.Snapshot_Invalid)
            }

            // bad magic
            {
                corrupt := make([]byte, size, allocator)
                defer delete(corrupt, allocator)
                copy(corrupt, buf)
                corrupt[0] ~= 0xFF
                testing.expect(t, ecs.overbase_deserialize(&ob, corrupt) == ecs.API_Error.Snapshot_Invalid)
            }

            // wrong version (version is the u32 right after the u64 magic)
            {
                corrupt := make([]byte, size, allocator)
                defer delete(corrupt, allocator)
                copy(corrupt, buf)
                corrupt[8] = 0xFF
                testing.expect(t, ecs.overbase_deserialize(&ob, corrupt) == ecs.API_Error.Snapshot_Version_Mismatch)
            }

            // capacity too small
            {
                small_ob: ecs.Overbase
                defer ecs.overbase_terminate(&small_ob)
                testing.expect(t, ecs.overbase_init(&small_ob, entities_cap = 1, allocator = allocator) == nil)
                testing.expect(t, ecs.overbase_deserialize(&small_ob, buf) == ecs.API_Error.Snapshot_Capacity_Too_Small)
            }

            // missing file
            testing.expect(t, ecs.overbase_load_from_file(&ob, "does_not_exist_overbase.snap", allocator) == ecs.API_Error.File_Error)

            // the original buffer still loads fine after all the failed attempts
            testing.expect(t, ecs.overbase_deserialize(&ob, buf) == nil)
            testing.expect(t, ecs.entities_len(&ob) == 1)
    }

///////////////////////////////////////////////////////////////////////////////
// Database serialize/deserialize on a SHARED Overbase never touches the
// shared id-space — this is the fix for docs/overbase.md's old "Serialization
// caveat".

    @(test)
    overbase_deserialize_shared_never_touches_id_space__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            render_db: ecs.Database
            positions: ecs.Table(Ob_Position)
            sprites: ecs.Table(Ob_Sprite)
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 2, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)
            testing.expect(t, ecs.table_init(&positions, &world_db, 10) == nil)
            testing.expect(t, ecs.table_init(&sprites, &render_db, 10) == nil)

            eids: [3]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 3; i += 1 {
                eids[i], err = ecs.create_entity(&ob)
                testing.expect(t, err == nil)
                pos, perr := ecs.add_component(&positions, eids[i])
                testing.expect(t, perr == nil)
                pos^ = Ob_Position{ x = i, y = 0 }
                _, serr := ecs.add_component(&sprites, eids[i])
                testing.expect(t, serr == nil)
            }

            // world_db's snapshot carries no entity-id section at all (it
            // doesn't own ob) — only its own positions table.
            size, size_err := ecs.serialized_size(&world_db)
            testing.expect(t, size_err == nil)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, werr := ecs.serialize(&world_db, buf)
            testing.expect(t, werr == nil)

            // Mutate the shared id-space: destroy eids[1] (cascades to both
            // Databases), then recycle its freed slot into a brand-new entity
            // that gets its own sprite on render_db.
            testing.expect(t, ecs.destroy_entity(&world_db, eids[1]) == nil)
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            testing.expect(t, new_eid.ix == eids[1].ix) // LIFO reuse
            _, nsprerr := ecs.add_component(&sprites, new_eid)
            testing.expect(t, nsprerr == nil)
            testing.expect(t, ecs.entities_len(&render_db) == 3) // eids[0], eids[2], new_eid

            // Safety net: world_db's snapshot still references the ORIGINAL
            // eids[1] (now a stale id — its slot was recycled into new_eid).
            // deserialize must reject this rather than silently writing
            // eids[1]'s saved position back under whatever entity now sits at
            // that recycled slot.
            derr := ecs.deserialize(&world_db, buf)
            testing.expect(t, derr == ecs.API_Error.Snapshot_Invalid)

            // Rejected load must not have touched anything: shared id-space
            // (as seen through the sibling render_db) is exactly as it was
            // right before the attempt, and so is world_db's own data.
            testing.expect(t, ecs.entities_len(&render_db) == 3)
            testing.expect(t, ecs.is_expired(&render_db, eids[1]))
            testing.expect(t, !ecs.is_expired(&render_db, new_eid))
            testing.expect(t, ecs.get_component(&positions, eids[0]).x == 0)

            // Now take a fresh snapshot of world_db's CURRENT state (only
            // references eids[0]/eids[2], both still valid) and mutate again.
            size2, _ := ecs.serialized_size(&world_db)
            buf2 := make([]byte, size2, allocator)
            defer delete(buf2, allocator)
            _, werr2 := ecs.serialize(&world_db, buf2)
            testing.expect(t, werr2 == nil)

            pos0 := ecs.get_component(&positions, eids[0])
            pos0.x = 9999

            // This restore succeeds (rows are valid against the live shared
            // factory) and rolls back world_db's own table — but must still
            // leave the shared id-space (and render_db) completely alone.
            testing.expect(t, ecs.deserialize(&world_db, buf2) == nil)
            testing.expect(t, ecs.get_component(&positions, eids[0]).x == 0)
            testing.expect(t, ecs.entities_len(&render_db) == 3)
            testing.expect(t, ecs.is_expired(&render_db, eids[1]))
            testing.expect(t, !ecs.is_expired(&render_db, new_eid))
            testing.expect(t, ecs.has_component(&sprites, new_eid))
    }

    // The full, correct workflow for saving/restoring a multi-Database shared
    // Overbase: overbase_serialize/overbase_deserialize for the shared
    // id-space, plus each Database's own serialize/deserialize for its
    // tables — and the Overbase MUST be restored first, since a Database's
    // own rows validate against whatever id-space is live at the time.
    @(test)
    overbase_serialize_with_attached_databases__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            render_db: ecs.Database
            positions: ecs.Table(Ob_Position)
            sprites: ecs.Table(Ob_Sprite)
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 2, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)
            testing.expect(t, ecs.table_init(&positions, &world_db, 10) == nil)
            testing.expect(t, ecs.table_init(&sprites, &render_db, 10) == nil)

            eids: [3]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 3; i += 1 {
                eids[i], err = ecs.create_entity(&ob)
                testing.expect(t, err == nil)
                pos, perr := ecs.add_component(&positions, eids[i])
                testing.expect(t, perr == nil)
                pos^ = Ob_Position{ x = 100 + i, y = 0 }
                spr, serr := ecs.add_component(&sprites, eids[i])
                testing.expect(t, serr == nil)
                spr.texture_id = 200 + i
            }

            // Save all three pieces.
            ob_size, _ := ecs.overbase_serialized_size(&ob)
            buf_ob := make([]byte, ob_size, allocator)
            defer delete(buf_ob, allocator)
            _, ob_err := ecs.overbase_serialize(&ob, buf_ob)
            testing.expect(t, ob_err == nil)

            world_size, _ := ecs.serialized_size(&world_db)
            buf_world := make([]byte, world_size, allocator)
            defer delete(buf_world, allocator)
            _, world_err := ecs.serialize(&world_db, buf_world)
            testing.expect(t, world_err == nil)

            render_size, _ := ecs.serialized_size(&render_db)
            buf_render := make([]byte, render_size, allocator)
            defer delete(buf_render, allocator)
            _, render_err := ecs.serialize(&render_db, buf_render)
            testing.expect(t, render_err == nil)

            // Diverge significantly: destroy eids[1] (cascades), recycle its
            // slot into a new entity with components on both Databases, and
            // mutate eids[0]'s data in place.
            testing.expect(t, ecs.destroy_entity(&world_db, eids[1]) == nil)
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            _, perr := ecs.add_component(&positions, new_eid)
            testing.expect(t, perr == nil)
            _, serr := ecs.add_component(&sprites, new_eid)
            testing.expect(t, serr == nil)
            ecs.get_component(&positions, eids[0]).x = -1
            ecs.get_component(&sprites, eids[0]).texture_id = -1

            // Restore — Overbase FIRST (rolls the shared id-space back so
            // eids[1] is valid again and new_eid no longer is), THEN each
            // Database's own tables.
            testing.expect(t, ecs.overbase_deserialize(&ob, buf_ob) == nil)
            testing.expect(t, ecs.deserialize(&world_db, buf_world) == nil)
            testing.expect(t, ecs.deserialize(&render_db, buf_render) == nil)

            testing.expect(t, ecs.entities_len(&ob) == 3)
            for i := 0; i < 3; i += 1 {
                testing.expect(t, !ecs.is_expired(&ob, eids[i]))
                testing.expect(t, ecs.get_component(&positions, eids[i]).x == 100 + i)
                testing.expect(t, ecs.get_component(&sprites, eids[i]).texture_id == 200 + i)
            }
            testing.expect(t, ecs.is_expired(&ob, new_eid)) // rolled back away
    }

///////////////////////////////////////////////////////////////////////////////
// Reconnecting a Database that was originally serialized standalone (its own
// private Overbase, full id+tables snapshot) into a freshly restored shared
// Overbase.

    @(test)
    overbase_reconnect_previously_standalone_database__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            standalone_db: ecs.Database
            standalone_positions: ecs.Table(Ob_Position)
        //
        // Test
        //
            // A plain, standalone Database (owns its own private Overbase) —
            // serialized the ordinary way, full id+tables snapshot.
            testing.expect(t, ecs.init(&standalone_db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&standalone_positions, &standalone_db, 10) == nil)

            e0, e0_err := ecs.create_entity(&standalone_db)
            testing.expect(t, e0_err == nil)
            e1, e1_err := ecs.create_entity(&standalone_db)
            testing.expect(t, e1_err == nil)

            pos0, p0err := ecs.add_component(&standalone_positions, e0)
            testing.expect(t, p0err == nil)
            pos0^ = Ob_Position{ x = 7, y = 0 }
            pos1, p1err := ecs.add_component(&standalone_positions, e1)
            testing.expect(t, p1err == nil)
            pos1^ = Ob_Position{ x = 8, y = 0 }

            standalone_size, _ := ecs.serialized_size(&standalone_db)
            buf_standalone := make([]byte, standalone_size, allocator)
            defer delete(buf_standalone, allocator)
            _, sderr := ecs.serialize(&standalone_db, buf_standalone)
            testing.expect(t, sderr == nil)

            ecs.terminate(&standalone_db) // done with it — only its bytes matter now

            // Separately: an Overbase serialized "without linked Databases",
            // populated with the SAME two entities (deterministic ix/gen
            // sequence from a fresh id_factory reproduces e0/e1 exactly).
            ob_source: ecs.Overbase
            testing.expect(t, ecs.overbase_init(&ob_source, entities_cap = 10, allocator = allocator) == nil)
            src_e0, src_e0_err := ecs.create_entity(&ob_source)
            testing.expect(t, src_e0_err == nil)
            src_e1, src_e1_err := ecs.create_entity(&ob_source)
            testing.expect(t, src_e1_err == nil)
            testing.expect(t, src_e0 == e0 && src_e1 == e1)

            ob_size, _ := ecs.overbase_serialized_size(&ob_source)
            buf_ob := make([]byte, ob_size, allocator)
            defer delete(buf_ob, allocator)
            _, oberr := ecs.overbase_serialize(&ob_source, buf_ob)
            testing.expect(t, oberr == nil)
            ecs.overbase_terminate(&ob_source)

            // Load side: a fresh shared Overbase restored from that
            // Overbase-only snapshot, a fresh Database attached to it (same
            // table schema/order as standalone_db had), then the ORIGINAL
            // standalone full snapshot deserialized into it.
            ob2: ecs.Overbase
            defer ecs.overbase_terminate(&ob2)
            testing.expect(t, ecs.overbase_init(&ob2, entities_cap = 10, databases_cap = 1, allocator = allocator) == nil)
            testing.expect(t, ecs.overbase_deserialize(&ob2, buf_ob) == nil)

            db2: ecs.Database
            defer ecs.terminate(&db2)
            testing.expect(t, ecs.init_from_overbase(&db2, &ob2) == nil)

            positions2: ecs.Table(Ob_Position)
            testing.expect(t, ecs.table_init(&positions2, &db2, 10) == nil)

            entities_len_before := ecs.entities_len(&ob2)

            // db2 does not own ob2 -> the standalone snapshot's embedded
            // id-section is ignored; rows are validated against ob2's live
            // (already-matching) factory instead.
            testing.expect(t, ecs.deserialize(&db2, buf_standalone) == nil)

            testing.expect(t, ecs.get_component(&positions2, e0).x == 7)
            testing.expect(t, ecs.get_component(&positions2, e1).x == 8)

            // ob2's shared id-space was not touched by db2's deserialize.
            testing.expect(t, ecs.entities_len(&ob2) == entities_len_before)
    }

///////////////////////////////////////////////////////////////////////////////
// Relations_Table and Tag_Table on a shared-Overbase Database — the row/link
// validation branches for these two table kinds are separate code paths from
// the named-component branch and were untouched by any test above.

    // Relations links (parent/first_child/next_sibling/prev_sibling) go
    // through the same snapshot__validate_row_eid helper as table rows, but
    // via their own code path in database__deserialize.
    @(test)
    overbase_deserialize_shared_relations__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            render_db: ecs.Database
            positions: ecs.Table(Ob_Position)
            rt: ecs.Relations_Table
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 2, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)
            testing.expect(t, ecs.table_init(&positions, &world_db, 10) == nil)
            testing.expect(t, ecs.relations_table__init(&rt, &world_db, 10) == nil)

            parent, perr := ecs.create_entity(&ob)
            testing.expect(t, perr == nil)
            child, cerr := ecs.create_entity(&ob)
            testing.expect(t, cerr == nil)

            pos_p, pperr := ecs.add_component(&positions, parent)
            testing.expect(t, pperr == nil)
            pos_p^ = Ob_Position{ x = 1, y = 0 }
            _, pcerr := ecs.add_component(&positions, child)
            testing.expect(t, pcerr == nil)

            testing.expect(t, ecs.set_parent(&world_db, child, parent) == nil)

            // world_db's snapshot carries positions + the parent/child link,
            // but no entity-id section at all (it doesn't own ob).
            size, _ := ecs.serialized_size(&world_db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&world_db, buf)
            testing.expect(t, serr == nil)

            //
            // (a) Happy path: mutate unrelated state, restore — the relation
            // round-trips and the shared id-space stays untouched.
            //
            pos_p.x = -1
            testing.expect(t, ecs.deserialize(&world_db, buf) == nil)

            testing.expect(t, ecs.get_component(&positions, parent).x == 1)
            is_child, icerr := ecs.is_child_of(&world_db, child, parent)
            testing.expect(t, icerr == nil && is_child)
            testing.expect(t, ecs.entities_len(&render_db) == 2)
            testing.expect(t, !ecs.is_expired(&render_db, parent))
            testing.expect(t, !ecs.is_expired(&render_db, child))

            //
            // (b) Stale rejection: destroy+recycle child's slot, then try to
            // restore the SAME buf again — its saved first_child link now
            // references a stale id; deserialize must reject, not write it.
            //
            testing.expect(t, ecs.destroy_entity(&world_db, child) == nil)
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            testing.expect(t, new_eid.ix == child.ix) // LIFO reuse

            derr := ecs.deserialize(&world_db, buf)
            testing.expect(t, derr == ecs.API_Error.Snapshot_Invalid)

            // Rejected load touched nothing.
            testing.expect(t, ecs.entities_len(&render_db) == 2) // parent, new_eid
            testing.expect(t, ecs.is_expired(&render_db, child))
            testing.expect(t, !ecs.is_expired(&render_db, new_eid))
    }

    // Tag_Table rows are entity ids directly (no component payload) — a
    // separate branch in the validation loop from the named-component case.
    // Also exercises defensive behavior: has_tag must read as false for a
    // stale id rather than reporting stale data, during the transient window
    // where world_db's own tag table hasn't caught up with the live Overbase.
    @(test)
    overbase_deserialize_shared_tag_table__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            render_db: ecs.Database
            is_alive: ecs.Tag_Table
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 2, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)
            testing.expect(t, ecs.tag_table__init(&is_alive, &world_db, 10) == nil)

            e0, e0err := ecs.create_entity(&ob)
            testing.expect(t, e0err == nil)
            e1, e1err := ecs.create_entity(&ob)
            testing.expect(t, e1err == nil)

            testing.expect(t, ecs.add_tag(&is_alive, e0) == nil)
            testing.expect(t, ecs.add_tag(&is_alive, e1) == nil)

            size, _ := ecs.serialized_size(&world_db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&world_db, buf)
            testing.expect(t, serr == nil)

            //
            // (a) Happy path
            //
            testing.expect(t, ecs.deserialize(&world_db, buf) == nil)
            testing.expect(t, ecs.table_len(&is_alive) == 2)
            testing.expect(t, ecs.has_tag(&is_alive, e0))
            testing.expect(t, ecs.has_tag(&is_alive, e1))
            testing.expect(t, ecs.entities_len(&render_db) == 2)

            //
            // (b) Stale rejection: destroy+recycle e1 before restoring buf
            // again — its saved tag row now references a stale id.
            //
            testing.expect(t, ecs.destroy_entity(&world_db, e1) == nil)
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            testing.expect(t, new_eid.ix == e1.ix) // LIFO reuse

            derr := ecs.deserialize(&world_db, buf)
            testing.expect(t, derr == ecs.API_Error.Snapshot_Invalid)

            // Rejected load touched nothing: shared id-space unaffected...
            testing.expect(t, ecs.entities_len(&render_db) == 2) // e0, new_eid
            testing.expect(t, ecs.is_expired(&render_db, e1))
            testing.expect(t, !ecs.is_expired(&render_db, new_eid))

            // ...and world_db's own (untouched, still-from-(a)) tag table
            // correctly reports the stale id as absent rather than serving
            // its old row — is_entity_correct guards it, same as any other
            // table kind.
            testing.expect(t, ecs.has_tag(&is_alive, e1) == false)
    }

///////////////////////////////////////////////////////////////////////////////
// serialized_size/serialize buffer-sizing for a shared Database — the branch
// that omits the id-section cost.

    @(test)
    overbase_shared_database_serialize_buffer_too_small__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            positions: ecs.Table(Ob_Position)

            standalone_db: ecs.Database
            standalone_positions: ecs.Table(Ob_Position)
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&standalone_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 1, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.table_init(&positions, &world_db, 10) == nil)

            testing.expect(t, ecs.init(&standalone_db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&standalone_positions, &standalone_db, 10) == nil)

            // Same schema, same data, on both.
            for i := 0; i < 3; i += 1 {
                eid, err := ecs.create_entity(&world_db)
                testing.expect(t, err == nil)
                pos, perr := ecs.add_component(&positions, eid)
                testing.expect(t, perr == nil)
                pos^ = Ob_Position{ x = i, y = 0 }

                seid, serr2 := ecs.create_entity(&standalone_db)
                testing.expect(t, serr2 == nil)
                spos, sperr := ecs.add_component(&standalone_positions, seid)
                testing.expect(t, sperr == nil)
                spos^ = Ob_Position{ x = i, y = 0 }
            }

            shared_size, shared_size_err := ecs.serialized_size(&world_db)
            testing.expect(t, shared_size_err == nil)
            standalone_size, standalone_size_err := ecs.serialized_size(&standalone_db)
            testing.expect(t, standalone_size_err == nil)

            // The id-section is genuinely omitted from the shared Database's
            // buffer, not merely ignored when reading it back.
            testing.expect(t, shared_size < standalone_size)

            // Buffer-too-small still fires correctly for the smaller
            // (tables-only) format.
            small := make([]byte, shared_size - 1, allocator)
            defer delete(small, allocator)
            _, e := ecs.serialize(&world_db, small)
            testing.expect(t, e == ecs.API_Error.Serialize_Buffer_Too_Small)

            // And the correctly-sized buffer still works.
            buf := make([]byte, shared_size, allocator)
            defer delete(buf, allocator)
            written, werr := ecs.serialize(&world_db, buf)
            testing.expect(t, werr == nil)
            testing.expect(t, written == shared_size)
    }

///////////////////////////////////////////////////////////////////////////////
// Adversarial: flipping SNAPSHOT_FLAG__HAS_ENTITY_ID_SECTION itself

    // Every other corruption test in the suite flips magic/version/length
    // bytes. None flips this new flag bit, which changes how many bytes
    // deserialize expects between the header and the first table section —
    // exercise it directly in both directions and confirm a clean Error,
    // never a panic, and that the database stays usable afterward.
    @(test)
    overbase_serialize_flag_bit_corruption__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            standalone_db: ecs.Database
            standalone_positions: ecs.Table(Ob_Position)

            ob: ecs.Overbase
            world_db: ecs.Database
            positions: ecs.Table(Ob_Position)
        //
        // Test
        //
            defer ecs.terminate(&standalone_db)
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)

            // Standalone (owns_overbase == true) — buffer legitimately HAS
            // the entity-id section (flag byte is at offset 16: magic:8 +
            // version:4 + endian_check:4; bit value 0x02).
            testing.expect(t, ecs.init(&standalone_db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&standalone_positions, &standalone_db, 10) == nil)
            s_eid, s_err := ecs.create_entity(&standalone_db)
            testing.expect(t, s_err == nil)
            _, s_perr := ecs.add_component(&standalone_positions, s_eid)
            testing.expect(t, s_perr == nil)

            s_size, _ := ecs.serialized_size(&standalone_db)
            s_buf := make([]byte, s_size, allocator)
            defer delete(s_buf, allocator)
            _, s_serr := ecs.serialize(&standalone_db, s_buf)
            testing.expect(t, s_serr == nil)

            s_corrupt := make([]byte, s_size, allocator)
            defer delete(s_corrupt, allocator)
            copy(s_corrupt, s_buf)
            s_corrupt[16] ~= 0x02 // flip HAS_ENTITY_ID_SECTION off

            // Exact resulting error variant depends on incidental byte
            // values downstream (the reader misinterprets id-section bytes
            // as a table header); what matters is a clean Error, never a
            // panic, and that the database is left usable afterward.
            testing.expect(t, ecs.deserialize(&standalone_db, s_corrupt) != nil)
            testing.expect(t, ecs.deserialize(&standalone_db, s_buf) == nil)

            // Shared (owns_overbase == false) — buffer legitimately has NO
            // entity-id section.
            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 1, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.table_init(&positions, &world_db, 10) == nil)

            w_eid, w_err := ecs.create_entity(&ob)
            testing.expect(t, w_err == nil)
            _, w_perr := ecs.add_component(&positions, w_eid)
            testing.expect(t, w_perr == nil)

            w_size, _ := ecs.serialized_size(&world_db)
            w_buf := make([]byte, w_size, allocator)
            defer delete(w_buf, allocator)
            _, w_serr := ecs.serialize(&world_db, w_buf)
            testing.expect(t, w_serr == nil)

            w_corrupt := make([]byte, w_size, allocator)
            defer delete(w_corrupt, allocator)
            copy(w_corrupt, w_buf)
            w_corrupt[16] ~= 0x02 // flip HAS_ENTITY_ID_SECTION on

            testing.expect(t, ecs.deserialize(&world_db, w_corrupt) != nil)
            testing.expect(t, ecs.deserialize(&world_db, w_buf) == nil)
    }

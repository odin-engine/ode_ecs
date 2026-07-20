/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for binary snapshot serialization (serialization.odin).
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:slice"
    import "core:mem"
    import "core:os"

// ODE
    import ecs ".."

///////////////////////////////////////////////////////////////////////////////
// Components (Position and AI are defined in ecs_test.odin)

    Speed :: struct {
        value: f32,
    }

    Non_Pod :: struct {
        target: ^int,
        value: int,
    }

///////////////////////////////////////////////////////////////////////////////
// Helpers

    // Schema shared by the round-trip tests. Init order matters: table ids of
    // source and target databases must coincide.
    Snapshot_World :: struct {
        db: ecs.Database,
        positions: ecs.Table(Position),
        speeds: ecs.Table(Speed),
        ais: ecs.Compact_Table(AI),
        tiny_ais: ecs.Tiny_Table(AI),
        is_alive: ecs.Tag_Table,
        relations: ecs.Relations_Table,
        group: ecs.Group,
    }

    snapshot_world__init :: proc(t: ^testing.T, w: ^Snapshot_World, entities_cap: int, allocator: mem.Allocator) {
        testing.expect(t, ecs.init(&w.db, entities_cap = entities_cap, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&w.positions, &w.db, 20) == nil)
        testing.expect(t, ecs.table_init(&w.speeds, &w.db, 20) == nil)
        testing.expect(t, ecs.compact_table__init(&w.ais, &w.db, 8) == nil)
        testing.expect(t, ecs.tiny_table__init(&w.tiny_ais, &w.db) == nil)
        testing.expect(t, ecs.tag_table__init(&w.is_alive, &w.db, 20) == nil)
        testing.expect(t, ecs.relations_table__init(&w.relations, &w.db, 10) == nil)
        testing.expect(t, ecs.group_init(&w.group, &w.db, {&w.positions, &w.speeds}) == nil)
    }

    snapshot_world__terminate :: proc(w: ^Snapshot_World) {
        ecs.terminate(&w.db)
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    serialization_round_trip__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // no allocations outside provided allocator

            a: Snapshot_World
            b: Snapshot_World

        //
        // Test
        //
            defer snapshot_world__terminate(&a)
            defer snapshot_world__terminate(&b)

            snapshot_world__init(t, &a, 20, allocator)

            eids: [20]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 20; i += 1 {
                eids[i], err = ecs.create_entity(&a.db)
                testing.expect(t, err == nil)
            }

            // Components across all table kinds
            for i := 0; i < 12; i += 1 {
                pos, perr := ecs.add_component(&a.positions, eids[i])
                testing.expect(t, perr == nil)
                pos^ = Position{ x = i, y = i * 10 }
            }
            for i := 4; i < 10; i += 1 {
                spd, serr := ecs.add_component(&a.speeds, eids[i])
                testing.expect(t, serr == nil)
                spd.value = f32(i) * 0.5
            }
            for i := 0; i < 6; i += 1 {
                ai, aerr := ecs.add_component(&a.ais, eids[i])
                testing.expect(t, aerr == nil)
                ai^ = AI{ IQ = f32(100 + i), neurons_count = i * 1000 }
            }
            for i := 8; i < 13; i += 1 {
                tai, terr := ecs.add_component(&a.tiny_ais, eids[i])
                testing.expect(t, terr == nil)
                tai^ = AI{ IQ = f32(i), neurons_count = i }
            }
            for i := 0; i < 15; i += 3 {
                testing.expect(t, ecs.add_tag(&a.is_alive, eids[i]) == nil)
            }

            // Relations: eids[0] parents eids[1] and eids[2]; eids[1] parents eids[3]
            testing.expect(t, ecs.set_parent(&a.db, eids[1], eids[0]) == nil)
            testing.expect(t, ecs.set_parent(&a.db, eids[2], eids[0]) == nil)
            testing.expect(t, ecs.set_parent(&a.db, eids[3], eids[1]) == nil)

            // Destroy a few entities so the factory freelist and generations round-trip
            testing.expect(t, ecs.destroy_entity(&a.db, eids[5]) == nil)
            testing.expect(t, ecs.destroy_entity(&a.db, eids[11]) == nil)
            testing.expect(t, ecs.destroy_entity(&a.db, eids[16]) == nil)

            //
            // Serialize A
            //
            size, size_err := ecs.serialized_size(&a.db)
            testing.expect(t, size_err == nil)
            testing.expect(t, size > 0)

            buf_a := make([]byte, size, allocator)
            defer delete(buf_a, allocator)

            written, werr := ecs.serialize(&a.db, buf_a)
            testing.expect(t, werr == nil)
            testing.expect(t, written == size)

            //
            // Deserialize into B (same schema, same init order)
            //
            snapshot_world__init(t, &b, 20, allocator)
            testing.expect(t, ecs.deserialize(&b.db, buf_a) == nil)

            testing.expect(t, ecs.entities_len(&b.db) == ecs.entities_len(&a.db))

            for i := 0; i < 20; i += 1 {
                eid := eids[i]
                expired_a := ecs.is_expired(&a.db, eid)
                expired_b := ecs.is_expired(&b.db, eid)
                testing.expect(t, expired_a == expired_b)
                if expired_a do continue

                pa := ecs.get_component(&a.positions, eid)
                pb := ecs.get_component(&b.positions, eid)
                testing.expect(t, (pa == nil) == (pb == nil))
                if pa != nil do testing.expect(t, pa^ == pb^)

                sa := ecs.get_component(&a.speeds, eid)
                sb := ecs.get_component(&b.speeds, eid)
                testing.expect(t, (sa == nil) == (sb == nil))
                if sa != nil do testing.expect(t, sa^ == sb^)

                aa := ecs.get_component(&a.ais, eid)
                ab := ecs.get_component(&b.ais, eid)
                testing.expect(t, (aa == nil) == (ab == nil))
                if aa != nil do testing.expect(t, aa^ == ab^)

                ta := ecs.get_component(&a.tiny_ais, eid)
                tb := ecs.get_component(&b.tiny_ais, eid)
                testing.expect(t, (ta == nil) == (tb == nil))
                if ta != nil do testing.expect(t, ta^ == tb^)
            }

            // Tags: same count and same entity set (row order round-trips exactly)
            testing.expect(t, ecs.table_len(&b.is_alive) == ecs.table_len(&a.is_alive))
            for i := 0; i < ecs.table_len(&a.is_alive); i += 1 {
                testing.expect(t, ecs.get_entity(&b.is_alive, i) == ecs.get_entity(&a.is_alive, i))
            }

            // Relations
            for i := 0; i < 20; i += 1 {
                eid := eids[i]
                if ecs.is_expired(&a.db, eid) do continue

                parent_a, pa_err := ecs.parent_of(&a.db, eid)
                parent_b, pb_err := ecs.parent_of(&b.db, eid)
                testing.expect(t, pa_err == nil && pb_err == nil)
                testing.expect(t, parent_a == parent_b)

                count_a, _ := ecs.children_count(&a.db, eid)
                count_b, _ := ecs.children_count(&b.db, eid)
                testing.expect(t, count_a == count_b)
            }
            is_child, cerr := ecs.is_child_of(&b.db, eids[3], eids[1])
            testing.expect(t, cerr == nil && is_child)

            // Group: same size, same member rows in the aligned prefix
            testing.expect(t, ecs.group_len(&b.group) == ecs.group_len(&a.group))
            testing.expect(t, ecs.group_len(&b.group) > 0)
            for i := 0; i < ecs.group_len(&a.group); i += 1 {
                testing.expect(t, ecs.get_entity(&b.positions, i) == ecs.get_entity(&a.positions, i))
                testing.expect(t, ecs.get_entity(&b.speeds, i) == ecs.get_entity(&a.speeds, i))
            }

            // Canonical form: serializing B again yields a byte-identical buffer
            size_b, size_b_err := ecs.serialized_size(&b.db)
            testing.expect(t, size_b_err == nil)
            testing.expect(t, size_b == size)

            buf_b := make([]byte, size_b, allocator)
            defer delete(buf_b, allocator)

            written_b, werr_b := ecs.serialize(&b.db, buf_b)
            testing.expect(t, werr_b == nil)
            testing.expect(t, written_b == written)
            testing.expect(t, slice.equal(buf_a, buf_b))
    }

    @(test)
    serialization_expired_ids__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db_a: ecs.Database
            db_b: ecs.Database
            positions_a: ecs.Table(Position)
            positions_b: ecs.Table(Position)

        //
        // Test
        //
            defer ecs.terminate(&db_a)
            defer ecs.terminate(&db_b)

            testing.expect(t, ecs.init(&db_a, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions_a, &db_a, 10) == nil)

            eids: [5]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 5; i += 1 {
                eids[i], err = ecs.create_entity(&db_a)
                testing.expect(t, err == nil)
            }
            testing.expect(t, ecs.destroy_entity(&db_a, eids[2]) == nil)

            size, _ := ecs.serialized_size(&db_a)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db_a, buf)
            testing.expect(t, serr == nil)

            testing.expect(t, ecs.init(&db_b, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions_b, &db_b, 10) == nil)
            testing.expect(t, ecs.deserialize(&db_b, buf) == nil)

            // The destroyed id is expired in B, live ids are not
            testing.expect(t, ecs.is_expired(&db_b, eids[2]))
            testing.expect(t, !ecs.is_expired(&db_b, eids[0]))
            testing.expect(t, !ecs.is_expired(&db_b, eids[4]))

            // Creating a new entity behaves identically in A and B:
            // same recycled index, same bumped generation
            new_a, aerr := ecs.create_entity(&db_a)
            new_b, berr := ecs.create_entity(&db_b)
            testing.expect(t, aerr == nil && berr == nil)
            testing.expect(t, new_a == new_b)
            testing.expect(t, new_b.ix == eids[2].ix)
            testing.expect(t, new_b.gen == eids[2].gen + 1)
    }

    @(test)
    serialization_views_after_load__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db_a: ecs.Database
            db_b: ecs.Database
            positions_a, speeds_a: ecs.Table(Position)
            positions_b, speeds_b: ecs.Table(Position)
            tag_a, tag_b: ecs.Tag_Table
            view_b, view_excl_b, view_filter_b: ecs.View

        //
        // Test
        //
            defer ecs.terminate(&db_a)
            defer ecs.terminate(&db_b)

            testing.expect(t, ecs.init(&db_a, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions_a, &db_a, 10) == nil)
            testing.expect(t, ecs.table_init(&speeds_a, &db_a, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&tag_a, &db_a, 10) == nil)

            eids: [6]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 6; i += 1 {
                eids[i], err = ecs.create_entity(&db_a)
                testing.expect(t, err == nil)
            }

            // positions on all 6, speeds on first 4, tag on 0 and 1
            for i := 0; i < 6; i += 1 {
                pos, perr := ecs.add_component(&positions_a, eids[i])
                testing.expect(t, perr == nil)
                pos^ = Position{ x = i, y = 0 }
            }
            for i := 0; i < 4; i += 1 {
                _, serr := ecs.add_component(&speeds_a, eids[i])
                testing.expect(t, serr == nil)
            }
            testing.expect(t, ecs.add_tag(&tag_a, eids[0]) == nil)
            testing.expect(t, ecs.add_tag(&tag_a, eids[1]) == nil)

            size, _ := ecs.serialized_size(&db_a)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db_a, buf)
            testing.expect(t, serr == nil)

            // B: same schema, plus views created BEFORE the load
            testing.expect(t, ecs.init(&db_b, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions_b, &db_b, 10) == nil)
            testing.expect(t, ecs.table_init(&speeds_b, &db_b, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&tag_b, &db_b, 10) == nil)

            filter :: proc(row: ^ecs.View_Row, user_data: rawptr) -> bool {
                positions := cast(^ecs.Table(Position)) user_data
                pos := ecs.get_component(positions, row)
                return pos.x >= 3
            }

            testing.expect(t, ecs.view_init(&view_b, &db_b, {&positions_b, &speeds_b}) == nil)
            testing.expect(t, ecs.view_init(&view_excl_b, &db_b, {&positions_b}, excludes = {&tag_b}) == nil)
            testing.expect(t, ecs.view_init(&view_filter_b, &db_b, {&positions_b}, filter = filter) == nil)
            view_filter_b.user_data = &positions_b

            testing.expect(t, ecs.deserialize(&db_b, buf) == nil)

            // positions AND speeds: entities 0..3
            testing.expect(t, ecs.view_len(&view_b) == 4)
            // positions WITHOUT tag: entities 2..5
            testing.expect(t, ecs.view_len(&view_excl_b) == 4)
            // positions with x >= 3: entities 3..5
            testing.expect(t, ecs.view_len(&view_filter_b) == 3)

            // Check contents through an iterator
            it: ecs.Iterator
            testing.expect(t, ecs.iterator_init(&it, &view_excl_b) == nil)
            for ecs.iterator_next(&it) {
                eid := ecs.get_entity(&it)
                pos := ecs.get_component(&positions_b, &it)
                testing.expect(t, pos.x >= 2) // tagged entities 0 and 1 excluded
                testing.expect(t, !ecs.is_expired(&db_b, eid))
            }
    }

    @(test)
    serialization_capacity_and_schema__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db_a: ecs.Database
            positions_a: ecs.Table(Position)
            ais_a: ecs.Table(AI)

        //
        // Test
        //
            defer ecs.terminate(&db_a)

            testing.expect(t, ecs.init(&db_a, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions_a, &db_a, 10) == nil)
            testing.expect(t, ecs.table_init(&ais_a, &db_a, 10) == nil)

            eids: [6]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 6; i += 1 {
                eids[i], err = ecs.create_entity(&db_a)
                testing.expect(t, err == nil)
                _, perr := ecs.add_component(&positions_a, eids[i])
                testing.expect(t, perr == nil)
            }

            size, _ := ecs.serialized_size(&db_a)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db_a, buf)
            testing.expect(t, serr == nil)

            // entities_cap too small
            {
                db: ecs.Database
                positions: ecs.Table(Position)
                ais: ecs.Table(AI)
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 5, allocator = allocator) == nil)
                testing.expect(t, ecs.table_init(&positions, &db, 5) == nil)
                testing.expect(t, ecs.table_init(&ais, &db, 5) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Capacity_Too_Small)
            }

            // table cap smaller than saved row count
            {
                db: ecs.Database
                positions: ecs.Table(Position)
                ais: ecs.Table(AI)
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
                testing.expect(t, ecs.table_init(&positions, &db, 3) == nil) // 3 < 6 saved rows
                testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Capacity_Too_Small)
            }

            // larger entities_cap loads fine and stays usable
            {
                db: ecs.Database
                positions: ecs.Table(Position)
                ais: ecs.Table(AI)
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 30, allocator = allocator) == nil)
                testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
                testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == nil)
                testing.expect(t, ecs.entities_len(&db) == 6)
                testing.expect(t, ecs.table_len(&positions) == 6)

                new_eid, neerr := ecs.create_entity(&db)
                testing.expect(t, neerr == nil)
                testing.expect(t, new_eid.ix == 6) // continues after the loaded entities
            }

            // wrong table type at the same id
            {
                db: ecs.Database
                positions: ecs.Table(Position)
                ais: ecs.Compact_Table(AI)
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
                testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
                testing.expect(t, ecs.compact_table__init(&ais, &db, 10) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Schema_Mismatch)
            }

            // wrong component type at the same id (name/size differ)
            {
                db: ecs.Database
                positions: ecs.Table(Position)
                speeds: ecs.Table(Speed)
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
                testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
                testing.expect(t, ecs.table_init(&speeds, &db, 10) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Schema_Mismatch)
            }

            // missing table (table count differs)
            {
                db: ecs.Database
                positions: ecs.Table(Position)
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
                testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Schema_Mismatch)
            }
    }

    @(test)
    serialization_robustness__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            _, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)

            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == nil)

            // buffer too small for serialize
            {
                small := make([]byte, size - 1, allocator)
                defer delete(small, allocator)
                _, e := ecs.serialize(&db, small)
                testing.expect(t, e == ecs.API_Error.Serialize_Buffer_Too_Small)
            }

            // serialize refused while packing is paused
            {
                ecs.pause_packing(&db)
                _, e := ecs.serialize(&db, buf)
                testing.expect(t, e == ecs.API_Error.Cannot_Serialize_While_Packing_Paused)
                testing.expect(t, ecs.resume_packing(&db) == nil)
            }

            // truncated buffer
            testing.expect(t, ecs.deserialize(&db, buf[:len(buf) - 10]) == ecs.API_Error.Snapshot_Invalid)

            // trailing garbage
            {
                bigger := make([]byte, size + 8, allocator)
                defer delete(bigger, allocator)
                copy(bigger, buf)
                testing.expect(t, ecs.deserialize(&db, bigger) == ecs.API_Error.Snapshot_Invalid)
            }

            // bad magic
            {
                corrupt := make([]byte, size, allocator)
                defer delete(corrupt, allocator)
                copy(corrupt, buf)
                corrupt[0] ~= 0xFF
                testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            }

            // wrong version (version is the u32 right after the u64 magic)
            {
                corrupt := make([]byte, size, allocator)
                defer delete(corrupt, allocator)
                copy(corrupt, buf)
                corrupt[8] = 0xFF
                testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Version_Mismatch)
            }

            // missing file
            testing.expect(t, ecs.load_from_file(&db, "does_not_exist.snap", allocator) == ecs.API_Error.File_Error)

            // the original buffer still loads fine after all the failed attempts
            testing.expect(t, ecs.deserialize(&db, buf) == nil)
            testing.expect(t, ecs.entities_len(&db) == 1)
    }

    // v1 (pre owns_overbase-gated entity-id section) snapshots are rejected
    // outright — not silently misparsed under the new v2 layout, which added
    // SNAPSHOT_FLAG__HAS_ENTITY_ID_SECTION and changed what a set/unset flag
    // means for cursor advancement in deserialize.
    @(test)
    serialization_old_version_rejected__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            _, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)

            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == nil)

            // Rewrite the version field (u32 right after the u64 magic) to 1,
            // simulating a buffer produced by the pre-Overbase-serialization
            // library version.
            v1 := make([]byte, size, allocator)
            defer delete(v1, allocator)
            copy(v1, buf)
            v1[8] = 1

            testing.expect(t, ecs.deserialize(&db, v1) == ecs.API_Error.Snapshot_Version_Mismatch)
    }

    @(test)
    serialization_non_pod__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            non_pods: ecs.Table(Non_Pod)

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&non_pods, &db, 10) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            _, perr := ecs.add_component(&non_pods, eid)
            testing.expect(t, perr == nil)

            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)

            // a component with a pointer field is rejected...
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == ecs.API_Error.Snapshot_Component_Not_POD)

            // ...unless explicitly allowed
            written, serr2 := ecs.serialize(&db, buf, allow_non_pod = true)
            testing.expect(t, serr2 == nil)
            testing.expect(t, written == size)
    }

    @(test)
    serialization_in_place_restore__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            is_alive: ecs.Tag_Table

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&is_alive, &db, 10) == nil)

            eids: [3]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 3; i += 1 {
                eids[i], err = ecs.create_entity(&db)
                testing.expect(t, err == nil)
                pos, perr := ecs.add_component(&positions, eids[i])
                testing.expect(t, perr == nil)
                pos^ = Position{ x = 100 + i, y = 0 }
            }
            testing.expect(t, ecs.add_tag(&is_alive, eids[0]) == nil)

            // Save
            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == nil)

            // Mutate: destroy an entity, change a component, add a tag
            testing.expect(t, ecs.destroy_entity(&db, eids[1]) == nil)
            pos0 := ecs.get_component(&positions, eids[0])
            pos0.x = 9999
            testing.expect(t, ecs.add_tag(&is_alive, eids[2]) == nil)

            // Restore the snapshot into the SAME database
            testing.expect(t, ecs.deserialize(&db, buf) == nil)

            testing.expect(t, ecs.entities_len(&db) == 3)
            testing.expect(t, !ecs.is_expired(&db, eids[1])) // alive again

            pos0 = ecs.get_component(&positions, eids[0])
            testing.expect(t, pos0 != nil && pos0.x == 100) // value restored

            pos1 := ecs.get_component(&positions, eids[1])
            testing.expect(t, pos1 != nil && pos1.x == 101)

            testing.expect(t, ecs.table_len(&is_alive) == 1) // eids[2] tag rolled back
    }

    // save_to_file → load_from_file round trip through an actual file on disk
    // (the in-memory buffer path is covered by serialization_round_trip__test).
    @(test)
    serialization_save_load_file__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            a: Snapshot_World
            b: Snapshot_World

        //
        // Test
        //
            defer snapshot_world__terminate(&a)
            defer snapshot_world__terminate(&b)

            snapshot_world__init(t, &a, 20, allocator)

            eids: [10]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 10; i += 1 {
                eids[i], err = ecs.create_entity(&a.db)
                testing.expect(t, err == nil)
            }
            for i := 0; i < 8; i += 1 {
                pos, perr := ecs.add_component(&a.positions, eids[i])
                testing.expect(t, perr == nil)
                pos^ = Position{ x = i, y = -i }
            }
            for i := 2; i < 6; i += 1 {
                spd, serr := ecs.add_component(&a.speeds, eids[i])
                testing.expect(t, serr == nil)
                spd.value = f32(i)
            }
            testing.expect(t, ecs.add_tag(&a.is_alive, eids[0]) == nil)
            testing.expect(t, ecs.set_parent(&a.db, eids[1], eids[0]) == nil)

            // cwd-relative: works both from tests/ (odin test .) and tests/out/
            // (the ECS Tests task); *.snap is gitignored and removed below
            path :: "save_load_round_trip.snap"
            defer os.remove(path)

            testing.expect(t, ecs.save_to_file(&a.db, path, allocator) == nil)

            // Load into a fresh database with the same schema
            snapshot_world__init(t, &b, 20, allocator)
            testing.expect(t, ecs.load_from_file(&b.db, path, allocator) == nil)

            testing.expect(t, ecs.entities_len(&b.db) == ecs.entities_len(&a.db))
            for i := 0; i < 10; i += 1 {
                pa := ecs.get_component(&a.positions, eids[i])
                pb := ecs.get_component(&b.positions, eids[i])
                testing.expect(t, (pa == nil) == (pb == nil))
                if pa != nil && pb != nil do testing.expect(t, pa^ == pb^)

                sa := ecs.get_component(&a.speeds, eids[i])
                sb := ecs.get_component(&b.speeds, eids[i])
                testing.expect(t, (sa == nil) == (sb == nil))
                if sa != nil && sb != nil do testing.expect(t, sa^ == sb^)
            }
            testing.expect(t, ecs.has_tag(&b.is_alive, eids[0]))

            is_child, cerr := ecs.is_child_of(&b.db, eids[1], eids[0])
            testing.expect(t, cerr == nil && is_child)
    }

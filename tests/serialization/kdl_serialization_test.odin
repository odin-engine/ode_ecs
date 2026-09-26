/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for KDL folder snapshots (kdl_serialization.odin).
*/

package ode_ecs__serialization_tests

// Core
    import "core:testing"
    import "core:os"
    import "core:slice"

// ODE
    import ecs "../../src"

///////////////////////////////////////////////////////////////////////////////
// Components

    Kdl_Mode :: enum u8 { Idle, Walk, Run }

    Kdl_Modes :: bit_set[Kdl_Mode]

    Kdl_Packed :: bit_field u16 {
        lo:  u8   | 4,
        neg: i8   | 4,
        on:  bool | 1,
    }

    Kdl_Inner :: struct {
        a: i16,
        b: [3]f32,
    }

    Kdl_Rich :: struct {
        small:  i8,
        big:    u64,
        huge:   i128,
        f32v:   f32,
        f64v:   f64,
        f16v:   f16,
        flag:   bool,
        r:      rune,
        mode:   Kdl_Mode,
        modes:  Kdl_Modes,
        inner:  Kdl_Inner,
        grid:   [2]Kdl_Inner,
        target: ecs.entity_id,
        u:      union { int, f32 },
        c:      complex64,
        be:     u32be,
        packed: Kdl_Packed,
    }

    File_Info :: struct {
        size: int,
    }

    Entity :: struct {
        v: int,
    }

///////////////////////////////////////////////////////////////////////////////
// Helpers

    Kdl_World :: struct {
        db:         ecs.Database,
        positions:  ecs.Table(Position),
        positions2: ecs.Compact_Table(Position),
        rich:       ecs.Table(Kdl_Rich),
        file_infos: ecs.Tiny_Table(File_Info),
        ents:       ecs.Tiny_Table(Entity),
        status:     ecs.Flags_Table,
        arch:       ecs.Arch_Table,
        alive:      ecs.Tag_Table,
        relations:  ecs.Relations_Table,
        likes:      ecs.Pair_Table(Likes_Data),
    }

    kdl_world__init :: proc(t: ^testing.T, w: ^Kdl_World) {
        testing.expect(t, ecs.init(&w.db, entities_cap = 32) == nil)
        testing.expect(t, ecs.table_init(&w.positions, &w.db, 32) == nil)
        testing.expect(t, ecs.compact_table__init(&w.positions2, &w.db, 8) == nil)
        testing.expect(t, ecs.table_init(&w.rich, &w.db, 8) == nil)
        testing.expect(t, ecs.tiny_table__init(&w.file_infos, &w.db) == nil)
        testing.expect(t, ecs.tiny_table__init(&w.ents, &w.db) == nil)
        testing.expect(t, ecs.flags_table_init(&w.status, &w.db, 8) == nil)
        testing.expect(t, ecs.arch_table__init(&w.arch, &w.db, 8, {Position, AI}) == nil)
        testing.expect(t, ecs.tag_table__init(&w.alive, &w.db, 32) == nil)
        testing.expect(t, ecs.relations_table__init(&w.relations, &w.db, 16) == nil)
        testing.expect(t, ecs.pair_init(&w.likes, &w.db, holders_cap = 8, pairs_cap = 8) == nil)
    }

    kdl_world__terminate :: proc(w: ^Kdl_World) {
        ecs.pair_table__terminate(&w.likes)
        ecs.terminate(&w.db)
    }

    kdl_world__fill :: proc(t: ^testing.T, w: ^Kdl_World) -> (eids: [12]ecs.entity_id) {
        err: ecs.Error
        for i in 0..<len(eids) {
            eids[i], err = ecs.create_entity(&w.db)
            testing.expect(t, err == nil)
        }
        // freed + recycled slots, so generations are non-trivial
        testing.expect(t, ecs.destroy_entity(&w.db, eids[3]) == nil)
        testing.expect(t, ecs.destroy_entity(&w.db, eids[10]) == nil)
        eids[3], err = ecs.create_entity(&w.db)
        testing.expect(t, err == nil)

        for i in 0..<8 {
            p, perr := ecs.add_component(&w.positions, eids[i])
            testing.expect(t, perr == nil)
            p^ = Position{ x = i, y = -i * 10 }
        }
        p2, p2err := ecs.add_component(&w.positions2, eids[1])
        testing.expect(t, p2err == nil)
        p2^ = Position{ x = 7, y = 8 }

        r, rerr := ecs.add_component(&w.rich, eids[0])
        testing.expect(t, rerr == nil)
        r^ = Kdl_Rich{
            small  = -5,
            big    = max(u64),
            huge   = min(i128),
            f32v   = 0.1,
            f64v   = 1.0 / 3.0,
            f16v   = 1.5,
            flag   = true,
            r      = 'é',
            mode   = .Run,
            modes  = {.Idle, .Run},
            inner  = { a = -300, b = { 1, 2.5, -3 } },
            grid   = { { a = 1, b = { 0, 0, 1 } }, { a = 2 } },
            target = eids[2],
            u      = f32(2.25),
            c      = complex(1, -2),
            be     = 0x01020304,
            packed = { lo = 9, neg = -3, on = true },
        }
        r2, r2err := ecs.add_component(&w.rich, eids[1])
        testing.expect(t, r2err == nil)
        r2^ = Kdl_Rich{ r = 1, mode = Kdl_Mode(7), u = 42 }

        fi, fierr := ecs.add_component(&w.file_infos, eids[2])
        testing.expect(t, fierr == nil)
        fi.size = 1024
        en, enerr := ecs.add_component(&w.ents, eids[2])
        testing.expect(t, enerr == nil)
        en.v = 3

        testing.expect(t, ecs.set_flags(&w.status, eids[4], ecs.flags_of(Ft_Status.Alert, Ft_Status.Wounded)) == nil)

        testing.expect(t, ecs.arch_table__add_entity(&w.arch, eids[9]) == nil)
        ecs.get_component(&w.arch, eids[9], Position)^ = Position{ x = 90, y = 91 }
        ecs.get_component(&w.arch, eids[9], AI)^ = AI{ IQ = 120.5, neurons_count = 3 }

        testing.expect(t, ecs.add_tag(&w.alive, eids[0]) == nil)
        testing.expect(t, ecs.add_tag(&w.alive, eids[1]) == nil)

        testing.expect(t, ecs.set_parent(&w.db, eids[1], eids[0]) == nil)
        testing.expect(t, ecs.set_parent(&w.db, eids[2], eids[0]) == nil)
        testing.expect(t, ecs.set_parent(&w.db, eids[4], eids[1]) == nil)

        _, lerr := ecs.pair_add(&w.likes, eids[0], eids[1], Likes_Data{ strength = 5 })
        testing.expect(t, lerr == nil)
        _, lerr = ecs.pair_add(&w.likes, eids[1], eids[0], Likes_Data{ strength = -1 })
        testing.expect(t, lerr == nil)

        testing.expect(t, ecs.disable_component(&w.positions, eids[6]) == nil)
        testing.expect(t, ecs.disable_component(&w.alive, eids[1]) == nil)

        return eids
    }

    kdl_binary :: proc(t: ^testing.T, db: ^ecs.Database) -> []byte {
        size, serr := ecs.serialized_size(db)
        testing.expect(t, serr == nil)
        buf := make([]byte, size)
        _, err := ecs.serialize(db, buf)
        testing.expect(t, err == nil)
        return buf
    }

    // test folders live under ./kdl_out, relative to the working directory
    kdl_fresh_folder :: proc(folder: string) {
        os.remove_all(folder)
        os.make_directory_all("kdl_out")
    }

    kdl_write :: proc(folder, name, text: string) {
        path, _ := os.join_path({folder, name}, context.temp_allocator)
        _ = os.write_entire_file(path, text)
    }

    kdl_exists :: proc(folder, name: string) -> bool {
        path, _ := os.join_path({folder, name}, context.temp_allocator)
        return os.exists(path)
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    kdl_snapshot__round_trip__test :: proc(t: ^testing.T) {
        folder := "kdl_out/kdl_round_trip"
        kdl_fresh_folder(folder)

        a, b: Kdl_World
        kdl_world__init(t, &a)
        defer kdl_world__terminate(&a)
        kdl_world__init(t, &b)
        defer kdl_world__terminate(&b)

        eids := kdl_world__fill(t, &a)
        testing.expect_value(t, ecs.save_to_kdl(&a.db, folder), nil)
        testing.expect_value(t, ecs.load_from_kdl(&b.db, folder), nil)

        bin_a := kdl_binary(t, &a.db)
        defer delete(bin_a)
        bin_b := kdl_binary(t, &b.db)
        defer delete(bin_b)
        testing.expect(t, slice.equal(bin_a, bin_b))

        r := ecs.get_component(&b.rich, eids[0])
        testing.expect(t, r != nil)
        if r != nil {
            testing.expect_value(t, r^, ecs.get_component(&a.rich, eids[0])^)
            testing.expect_value(t, r.packed.neg, -3)
            testing.expect_value(t, r.huge, min(i128))
        }
        // save -> load -> save is byte-stable
        folder2 := "kdl_out/kdl_round_trip2"
        kdl_fresh_folder(folder2)
        testing.expect_value(t, ecs.save_to_kdl(&b.db, folder2), nil)
        entries, _ := os.read_all_directory_by_path(folder, context.temp_allocator)
        testing.expect(t, len(entries) > 0)
        for e in entries {
            p1, _ := os.join_path({folder, e.name}, context.temp_allocator)
            p2, _ := os.join_path({folder2, e.name}, context.temp_allocator)
            d1, _ := os.read_entire_file(p1, context.temp_allocator)
            d2, _ := os.read_entire_file(p2, context.temp_allocator)
            testing.expectf(t, d1 != nil && slice.equal(d1, d2), "%s differs", e.name)
        }

        testing.expect(t, ecs.is_component_disabled(&b.positions, eids[6]))
        testing.expect(t, ecs.is_component_disabled(&b.alive, eids[1]))
        parent, perr := ecs.parent_of(&b.db, eids[4])
        testing.expect(t, perr == nil && parent == eids[1])
    }

    @(test)
    kdl_snapshot__file_names__test :: proc(t: ^testing.T) {
        folder := "kdl_out/kdl_file_names"
        kdl_fresh_folder(folder)

        w: Kdl_World
        kdl_world__init(t, &w)
        defer kdl_world__terminate(&w)
        kdl_world__fill(t, &w)

        testing.expect_value(t, ecs.save_to_kdl(&w.db, folder), nil)

        for name in ([]string{
            "_snapshot.kdl", "entities.kdl", "relations.kdl",
            "positions1.kdl", "positions2.kdl", "kdl_riches.kdl", "file_infos.kdl", "entities1.kdl",
            "flags.kdl", "archetypes.kdl", "tags1.kdl", "tags2.kdl", "likes_datas.kdl",
        }) {
            testing.expectf(t, kdl_exists(folder, name), "missing %s", name)
        }
        testing.expect(t, !kdl_exists(folder, "positions.kdl"))
    }

    @(test)
    kdl_snapshot__overwrite__test :: proc(t: ^testing.T) {
        folder := "kdl_out/kdl_overwrite"
        kdl_fresh_folder(folder)

        w: Kdl_World
        kdl_world__init(t, &w)
        defer kdl_world__terminate(&w)
        kdl_world__fill(t, &w)
        testing.expect_value(t, ecs.save_to_kdl(&w.db, folder), nil)
        kdl_write(folder, "notes.txt", "keep me")

        testing.expect_value(t, ecs.save_to_kdl(&w.db, folder), ecs.API_Error.Snapshot_Already_Exists)
        testing.expect_value(t, ecs.save_to_kdl(&w.db, folder, overwrite = true), nil)

        // A smaller schema: the old snapshot's extra files must go, unlisted files must stay.
        small: ecs.Database
        testing.expect(t, ecs.init(&small, entities_cap = 8) == nil)
        defer ecs.terminate(&small)
        positions: ecs.Table(Position)
        testing.expect(t, ecs.table_init(&positions, &small, 8) == nil)

        testing.expect_value(t, ecs.save_to_kdl(&small, folder, overwrite = true), nil)
        testing.expect(t, kdl_exists(folder, "positions.kdl"))
        testing.expect(t, !kdl_exists(folder, "archetypes.kdl"))
        testing.expect(t, !kdl_exists(folder, "positions1.kdl"))
        testing.expect(t, !kdl_exists(folder, "relations.kdl"))
        testing.expect(t, kdl_exists(folder, "notes.txt"))
    }

    @(test)
    kdl_snapshot__unowned_file_collision__test :: proc(t: ^testing.T) {
        folder := "kdl_out/kdl_collision"
        kdl_fresh_folder(folder)
        os.make_directory_all(folder)
        kdl_write(folder, "positions.kdl", "not ours")

        db: ecs.Database
        testing.expect(t, ecs.init(&db, entities_cap = 8) == nil)
        defer ecs.terminate(&db)
        positions: ecs.Table(Position)
        testing.expect(t, ecs.table_init(&positions, &db, 8) == nil)

        testing.expect_value(t, ecs.save_to_kdl(&db, folder), ecs.API_Error.Snapshot_Already_Exists)
        testing.expect_value(t, ecs.save_to_kdl(&db, folder, overwrite = true), ecs.API_Error.Snapshot_Already_Exists)
    }

    @(test)
    kdl_snapshot__unsafe_manifest__test :: proc(t: ^testing.T) {
        folder := "kdl_out/kdl_unsafe"
        kdl_fresh_folder(folder)
        os.make_directory_all(folder)
        kdl_write(folder, "_snapshot.kdl", "ode_ecs_snapshot version=1\nentities_cap 8\nfile \"../victim.kdl\"\n")
        kdl_write("kdl_out", "victim.kdl", "still here")
        defer os.remove("kdl_out/victim.kdl")

        db: ecs.Database
        testing.expect(t, ecs.init(&db, entities_cap = 8) == nil)
        defer ecs.terminate(&db)

        testing.expect_value(t, ecs.save_to_kdl(&db, folder, overwrite = true), ecs.API_Error.Snapshot_Invalid)
        testing.expect_value(t, ecs.load_from_kdl(&db, folder), ecs.API_Error.Snapshot_Invalid)
        testing.expect(t, os.exists("kdl_out/victim.kdl"))
        testing.expect(t, kdl_exists(folder, "_snapshot.kdl"))
    }

    @(test)
    kdl_snapshot__hand_edit__test :: proc(t: ^testing.T) {
        folder := "kdl_out/kdl_hand_edit"
        kdl_fresh_folder(folder)
        os.make_directory_all(folder)

        db: ecs.Database
        testing.expect(t, ecs.init(&db, entities_cap = 8) == nil)
        defer ecs.terminate(&db)
        positions: ecs.Table(Position)
        testing.expect(t, ecs.table_init(&positions, &db, 8) == nil)

        kdl_write(folder, "_snapshot.kdl", "ode_ecs_snapshot version=1\nentities_cap 8\nfile entities.kdl\nfile positions.kdl\n")
        kdl_write(folder, "entities.kdl", "entities created=2\n")

        // reordered fields, omitted field -> zero
        table_header :: "table id=0 type=Table component=\"ode_ecs__serialization_tests.Position\"\n"
        kdl_write(folder, "positions.kdl", table_header + "row 0 0 y=5 x=1\nrow 1 0 x=2 // y omitted\n")
        testing.expect_value(t, ecs.load_from_kdl(&db, folder), nil)

        e0 := ecs.entity_id{ ix = 0, gen = 0 }
        e1 := ecs.entity_id{ ix = 1, gen = 0 }
        p0 := ecs.get_component(&positions, e0)
        p1 := ecs.get_component(&positions, e1)
        testing.expect(t, p0 != nil && p1 != nil)
        if p0 != nil do testing.expect_value(t, p0^, Position{ x = 1, y = 5 })
        if p1 != nil do testing.expect_value(t, p1^, Position{ x = 2, y = 0 })

        kdl_write(folder, "positions.kdl", table_header + "row 0 0 x=1 z=3\n")
        testing.expect_value(t, ecs.load_from_kdl(&db, folder), ecs.API_Error.Snapshot_Invalid)

        kdl_write(folder, "positions.kdl", "table id=0 type=Table component=\"other.Thing\"\nrow 0 0 x=1\n")
        testing.expect_value(t, ecs.load_from_kdl(&db, folder), ecs.API_Error.Snapshot_Schema_Mismatch)

        kdl_write(folder, "positions.kdl", "table id=0 type=Compact_Table\nrow 0 0 x=1\n")
        testing.expect_value(t, ecs.load_from_kdl(&db, folder), ecs.API_Error.Snapshot_Schema_Mismatch)

        kdl_write(folder, "positions.kdl", table_header + "row 0 0 x=\"text\"\n")
        testing.expect_value(t, ecs.load_from_kdl(&db, folder), ecs.API_Error.Snapshot_Invalid)

        // a failed load leaves the previous state intact
        p0 = ecs.get_component(&positions, e0)
        testing.expect(t, p0 != nil && p0.x == 1 && p0.y == 5)
    }

    @(test)
    kdl_snapshot__no_manifest__test :: proc(t: ^testing.T) {
        db: ecs.Database
        testing.expect(t, ecs.init(&db, entities_cap = 8) == nil)
        defer ecs.terminate(&db)

        testing.expect_value(t, ecs.load_from_kdl(&db, "kdl_out/kdl_does_not_exist"), ecs.API_Error.File_Error)
    }

    @(test)
    kdl_snapshot__shared_overbase__test :: proc(t: ^testing.T) {
        folder := "kdl_out/kdl_shared_overbase"
        kdl_fresh_folder(folder)

        ob: ecs.Overbase
        testing.expect(t, ecs.overbase_init(&ob, entities_cap = 8) == nil)
        defer ecs.overbase_terminate(&ob)

        db: ecs.Database
        testing.expect(t, ecs.init_from_overbase(&db, &ob) == nil)
        defer ecs.terminate(&db)
        positions: ecs.Table(Position)
        testing.expect(t, ecs.table_init(&positions, &db, 8) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        p, _ := ecs.add_component(&positions, eid)
        p^ = Position{ x = 3, y = 4 }

        testing.expect_value(t, ecs.save_to_kdl(&db, folder), nil)
        testing.expect(t, !kdl_exists(folder, "entities.kdl"))

        p.x = 100
        testing.expect_value(t, ecs.load_from_kdl(&db, folder), nil)
        p = ecs.get_component(&positions, eid)
        testing.expect(t, p != nil && p^ == Position{ x = 3, y = 4 })
    }

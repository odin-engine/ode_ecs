/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for View's column-major (SoA) storage — column_slice/entities_slice bulk
    access.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:math/rand"

// ODE
    import ecs "../src"

    Exp_Pos :: struct { x, y: f64 }
    Exp_Vel :: struct { x, y: f64 }

    exp_view__verify :: proc(t: ^testing.T, view: ^ecs.View, pos: ^ecs.Table(Exp_Pos), vel: ^ecs.Table(Exp_Vel)) {
        pos_col := ecs.view_column_slice(view, Exp_Pos)
        vel_col := ecs.view_column_slice(view, Exp_Vel)
        entities := ecs.view_entities_slice(view)

        testing.expect(t, len(pos_col) == ecs.view_len(view))
        testing.expect(t, len(vel_col) == ecs.view_len(view))
        testing.expect(t, len(entities) == ecs.view_len(view))

        for i in 0..<ecs.view_len(view) {
            eid := entities[i]

            testing.expect(t, pos_col[i] == ecs.get_component(pos, eid), "View pos column != table lookup")
            testing.expect(t, vel_col[i] == ecs.get_component(vel, eid), "View vel column != table lookup")
            testing.expect(t, pos_col[i].x == vel_col[i].x, "Position and Velocity belong to different entities")
        }
    }

    @(test)
    exp_view__init_terminate__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Exp_Pos)
        vel: ecs.Table(Exp_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

        testing.expect(t, ecs.view_len(&view) == 0)
        testing.expect(t, view.tables[view.tid_to_cid[pos.id]] == &pos.shared, "pos must have its own column")
        testing.expect(t, view.tables[view.tid_to_cid[vel.id]] == &vel.shared, "vel must have its own column")

        testing.expect(t, ecs.view_terminate(&view) == nil)

        testing.expect(t, ecs.view_init(&view, &db, {&vel, &pos}) == nil)
        testing.expect(t, view.tables[view.tid_to_cid[vel.id]] == &vel.shared)
        testing.expect(t, view.tables[view.tid_to_cid[pos.id]] == &pos.shared)
        testing.expect(t, ecs.view_terminate(&view) == nil)
    }

    @(test)
    exp_view__only_starts_seeing_new_entities__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Exp_Pos)
        vel: ecs.Table(Exp_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)

        pre_eid, _ := ecs.create_entity(&db)
        ecs.add_component(&pos, pre_eid)
        ecs.add_component(&vel, pre_eid)

        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)
        defer ecs.view_terminate(&view)
        testing.expect(t, ecs.view_len(&view) == 0)

        post_eid, _ := ecs.create_entity(&db)
        ecs.add_component(&pos, post_eid)
        ecs.add_component(&vel, post_eid)

        testing.expect(t, ecs.view_len(&view) == 1)
    }

    @(test)
    exp_view__add_remove_tail_swap__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Exp_Pos)
        vel: ecs.Table(Exp_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)
        defer ecs.view_terminate(&view)

        eids: [30]ecs.entity_id
        for i in 0..<30 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(i), 0 }
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(i), 0 }
        }

        testing.expect(t, ecs.view_len(&view) == 30)
        exp_view__verify(t, &view, &pos, &vel)

        testing.expect(t, ecs.remove_component(&pos, eids[10]) == nil)
        testing.expect(t, ecs.view_len(&view) == 29)
        exp_view__verify(t, &view, &pos, &vel)

        ecs.destroy_entity(&db, eids[0])
        exp_view__verify(t, &view, &pos, &vel)

        ecs.destroy_entity(&db, eids[29])
        exp_view__verify(t, &view, &pos, &vel)

        p, _ := ecs.add_component(&pos, eids[10]); p^ = { 10, 0 }
        exp_view__verify(t, &view, &pos, &vel)
    }

    @(test)
    exp_view__pause_resume_packing__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Exp_Pos)
        vel: ecs.Table(Exp_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)
        defer ecs.view_terminate(&view)

        eids: [20]ecs.entity_id
        for i in 0..<20 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(i), 0 }
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(i), 0 }
        }

        testing.expect(t, ecs.pause_packing(&pos) == nil)

        for i in 0..<10 {
            ecs.remove_component(&pos, eids[i*2])
        }
        testing.expect(t, ecs.view_len(&view) == 10)
        exp_view__verify(t, &view, &pos, &vel)

        testing.expect(t, ecs.resume_packing(&pos) == nil)
        testing.expect(t, ecs.view_len(&view) == 10)
        exp_view__verify(t, &view, &pos, &vel)
    }

    @(test)
    exp_view__tag_table_column__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Exp_Pos)
        tag: ecs.Tag_Table
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.tag_table__init(&tag, &db, 100) == nil)

        testing.expect(t, ecs.view_init(&view, &db, {&pos, &tag}) == nil)
        defer ecs.view_terminate(&view)

        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&pos, eid); p^ = { 1, 2 }
        testing.expect(t, ecs.view_len(&view) == 0, "not a member until it also has the tag")

        testing.expect(t, ecs.add_tag(&tag, eid) == nil)
        testing.expect(t, ecs.view_len(&view) == 1)
        testing.expect(t, ecs.view_column_slice(&view, Exp_Pos)[0] == p)
    }

    @(test)
    exp_view__random_ops_fuzz__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Exp_Pos)
        vel: ecs.Table(Exp_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        N :: 128

        testing.expect(t, ecs.init(&db, N) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, N) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, N) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)
        defer ecs.view_terminate(&view)

        rng := rand.create(0xC0FFEE)
        context.random_generator = rand.default_random_generator(&rng)

        alive: [dynamic]ecs.entity_id
        defer delete(alive)

        for step in 0..<2000 {
            op := rand.int_max(10)

            if op < 5 || len(alive) == 0 {
                if len(alive) < N - 1 {
                    eid, err := ecs.create_entity(&db)
                    if err == nil {
                        which := rand.int_max(4)
                        if which != 1 { p, _ := ecs.add_component(&pos, eid); p^ = { f64(eid.ix), 1 } }
                        if which != 2 { v, _ := ecs.add_component(&vel, eid); v^ = { f64(eid.ix), 2 } }
                        append(&alive, eid)
                    }
                }
            } else if op < 8 {
                i := rand.int_max(len(alive))
                ecs.destroy_entity(&db, alive[i])
                unordered_remove(&alive, i)
            } else {
                i := rand.int_max(len(alive))
                eid := alive[i]
                if op == 8 do ecs.remove_component(&pos, eid)
                else       do ecs.remove_component(&vel, eid)
            }

            if step % 20 == 0 do exp_view__verify(t, &view, &pos, &vel)
        }

        exp_view__verify(t, &view, &pos, &vel)
    }

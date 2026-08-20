/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for the dense (aligned) view fast path: Iterator reads components directly
    from table rows when view rows are aligned with table rows, and must fall back to
    the pointer-record path the moment alignment is broken.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:math/rand"

// ODE
    import ecs ".."

    Dense_Pos :: struct { x, y: f64 }
    Dense_Vel :: struct { x, y: f64 }

    dense__verify_view :: proc(t: ^testing.T, view: ^ecs.View, pos: ^ecs.Table(Dense_Pos), vel: ^ecs.Table(Dense_Vel)) {
        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, view) == nil)

        rows := 0
        for ecs.iterator_next(&it) {
            eid := ecs.get_entity(&it)

            p_it := ecs.get_component(pos, &it)
            v_it := ecs.get_component(vel, &it)

            p_direct := ecs.get_component(pos, eid)
            v_direct := ecs.get_component(vel, eid)

            testing.expect(t, p_it == p_direct, "iterator Position != table lookup Position")
            testing.expect(t, v_it == v_direct, "iterator Velocity != table lookup Velocity")

            rows += 1
        }

        testing.expect(t, rows == ecs.view_len(view))
    }

    @(test)
    dense_view__aligned_setup__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Dense_Pos)
        vel: ecs.Table(Dense_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

        for i in 0..<50 {
            eid, _ := ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eid); p^ = { f64(i), 0 }
            v, _ := ecs.add_component(&vel, eid); v^ = { 1, 2 }
        }

        dense__verify_view(t, &view, &pos, &vel)
        testing.expect(t, view.dense_state == ecs.View_Dense_State.Aligned, "identical add order should stay aligned")
    }

    @(test)
    dense_view__misaligned_add_order__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Dense_Pos)
        vel: ecs.Table(Dense_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

        eids: [20]ecs.entity_id
        for i in 0..<20 do eids[i], _ = ecs.create_entity(&db)

        for i := 19; i >= 0; i -= 1 {
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(i), 0 }
        }
        for i in 0..<20 {
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(i), 0 }
        }

        dense__verify_view(t, &view, &pos, &vel)
        testing.expect(t, view.dense_state == ecs.View_Dense_State.Misaligned, "reversed add order must be detected as misaligned")

        testing.expect(t, view.dense_cols[view.tid_to_cid[pos.id]] == ecs.View_Dense_State.Aligned, "pos column follows view row order and should stay aligned")
        testing.expect(t, view.dense_cols[view.tid_to_cid[vel.id]] == ecs.View_Dense_State.Misaligned, "reversed vel column must lose alignment")

        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&pos, &it)
            v := ecs.get_component(&vel, &it)
            testing.expect(t, p.x == v.x, "Position and Velocity belong to different entities")
        }
    }

    @(test)
    dense_view__single_component_removal__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Dense_Pos)
        vel: ecs.Table(Dense_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

        eids: [30]ecs.entity_id
        for i in 0..<30 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(i), 0 }
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(i), 0 }
        }

        testing.expect(t, ecs.remove_component(&pos, eids[5]) == nil)

        dense__verify_view(t, &view, &pos, &vel)

        testing.expect(t, ecs.rebuild(&view) == nil)
        dense__verify_view(t, &view, &pos, &vel)
    }

    @(test)
    dense_view__churn_stays_aligned__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Dense_Pos)
        vel: ecs.Table(Dense_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        N :: 200

        testing.expect(t, ecs.init(&db, N) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, N) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, N) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

        handles: [N]ecs.entity_id
        for i in 0..<N {
            handles[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, handles[i]); p^ = { f64(i), 0 }
            v, _ := ecs.add_component(&vel, handles[i]); v^ = { f64(i), 0 }
        }

        cursor := 0
        for frame in 0..<50 {
            for k in 0..<20 {
                ecs.destroy_entity(&db, handles[cursor])
                eid, _ := ecs.create_entity(&db)
                p, _ := ecs.add_component(&pos, eid); p^ = { f64(cursor), 0 }
                v, _ := ecs.add_component(&vel, eid); v^ = { f64(cursor), 0 }
                handles[cursor] = eid
                cursor = (cursor + 1) % N
            }
            dense__verify_view(t, &view, &pos, &vel)
        }

        testing.expect(t, view.dense_state == ecs.View_Dense_State.Aligned, "identical-membership churn should stay aligned")
    }

    @(test)
    dense_view__slice__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Dense_Pos)
        vel: ecs.Table(Dense_Vel)
        other: ecs.Table(Dense_Pos)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&other, &db, 100) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

        eids: [40]ecs.entity_id
        for i in 0..<40 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(i), 0 }
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(i), 0 }
        }

        dense__verify_view(t, &view, &pos, &vel)
        testing.expect(t, view.dense_cols[view.tid_to_cid[pos.id]] == ecs.View_Dense_State.Aligned)
        testing.expect(t, view.dense_cols[view.tid_to_cid[vel.id]] == ecs.View_Dense_State.Aligned)

        other_has_column := int(other.id) < len(view.tid_to_cid) && view.tid_to_cid[other.id] != ecs.DELETED_INDEX
        testing.expect(t, !other_has_column)

        ecs.suspend(&view)
        it: ecs.Iterator
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        testing.expect(t, !it.dense, "suspended view must not use the dense fast path")
        ecs.resume(&view)
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        testing.expect(t, it.dense, "resumed, still-aligned view should recover the dense fast path")

        testing.expect(t, ecs.remove_component(&pos, eids[3]) == nil)
        dense__verify_view(t, &view, &pos, &vel)
        testing.expect(t, view.dense_cols[view.tid_to_cid[pos.id]] == ecs.View_Dense_State.Aligned, "pos column mirrors the view's tail swap and stays aligned")
        testing.expect(t, view.dense_cols[view.tid_to_cid[vel.id]] == ecs.View_Dense_State.Misaligned, "vel column must lose alignment")

        testing.expect(t, ecs.rebuild(&view) == nil)
        dense__verify_view(t, &view, &pos, &vel)
        pos_aligned := view.dense_cols[view.tid_to_cid[pos.id]] == ecs.View_Dense_State.Aligned
        vel_aligned := view.dense_cols[view.tid_to_cid[vel.id]] == ecs.View_Dense_State.Aligned
        testing.expect(t, pos_aligned != vel_aligned, "exactly one column can realign after rebuild")
    }

    @(test)
    dense_view__try_dense_slice__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Dense_Pos)
        vel: ecs.Table(Dense_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

        eids: [20]ecs.entity_id
        for i in 0..<20 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(i), 0 }
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(i), 0 }
        }

        pos_dense := ecs.slice(&view, &pos)
        vel_dense := ecs.slice(&view, &vel)
        testing.expect(t, pos_dense != nil, "aligned column must return a real dense slice")
        testing.expect(t, vel_dense != nil)
        testing.expect(t, len(pos_dense) == ecs.view_len(&view))
        testing.expect(t, raw_data(pos_dense) == raw_data(ecs.slice(&pos)), "must be the table's own rows, not a copy")
        for i in 0..<len(pos_dense) {
            testing.expect(t, pos_dense[i].x == f64(i))
        }

        ecs.suspend(&view)
        testing.expect(t, ecs.slice(&view, &pos) == nil, "suspended view must not hand out a dense slice")
        ecs.resume(&view)
        testing.expect(t, ecs.slice(&view, &pos) != nil, "resumed, still-aligned view should recover the dense slice")

        testing.expect(t, ecs.remove_component(&pos, eids[3]) == nil)
        testing.expect(t, ecs.slice(&view, &vel) == nil, "vel's row 3 no longer matches the view after pos's tail-swap")
        testing.expect(t, ecs.slice(&view, &pos) != nil, "pos mirrors its own table's swap and stays aligned")
    }

    @(test)
    dense_view__random_ops_fuzz__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Dense_Pos)
        vel: ecs.Table(Dense_Vel)
        view: ecs.View
        defer ecs.terminate(&db)

        N :: 128

        testing.expect(t, ecs.init(&db, N) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, N) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, N) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

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

            if step % 20 == 0 do dense__verify_view(t, &view, &pos, &vel)
        }

        dense__verify_view(t, &view, &pos, &vel)
    }

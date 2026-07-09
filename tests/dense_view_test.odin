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

    // Oracle: for every view row, the component returned through the iterator must be
    // the exact same address as the table's own eid -> component lookup.
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

        // Same add order for both tables => everything stays aligned
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

        // Add velocities in reverse order first, then positions in forward order:
        // vel rows end up reversed relative to view rows => misaligned.
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

        // Alignment is per column: view rows follow the pos add order, so the pos column
        // is still dense while the reversed vel column is not.
        testing.expect(t, ecs.view_dense_slice(&view, &pos) != nil, "pos column follows view row order and should stay sliceable")
        testing.expect(t, ecs.view_dense_slice(&view, &vel) == nil, "reversed vel column must not be sliceable")

        // Values must come from the right entity
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

        // Removing only Position (entity keeps Velocity) breaks alignment permanently:
        // pos table tail-swaps but vel table does not.
        testing.expect(t, ecs.remove_component(&pos, eids[5]) == nil)

        dense__verify_view(t, &view, &pos, &vel)

        // Full churn (both components removed via destroy) keeps tables aligned with each other
        // after a rebuild.
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

        // Despawn+respawn churn with identical table membership preserves alignment
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
    dense_view__dense_slice__test :: proc(t: ^testing.T) {
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

        // Aligned: slices must line up with per-entity lookups
        ps := ecs.view_dense_slice(&view, &pos)
        vs := ecs.view_dense_slice(&view, &vel)
        testing.expect(t, len(ps) == ecs.view_len(&view))
        testing.expect(t, len(vs) == ecs.view_len(&view))
        for i in 0..<len(ps) {
            eid := ecs.get_entity(&pos, i)
            testing.expect(t, &ps[i] == ecs.get_component(&pos, eid))
            testing.expect(t, ps[i].x == vs[i].x, "slices of one view must be row-for-row the same entity")
        }

        // Table not in view => nil
        testing.expect(t, ecs.view_dense_slice(&view, &other) == nil)

        // Suspended => nil, resume recovers (rescan)
        ecs.suspend(&view)
        testing.expect(t, ecs.view_dense_slice(&view, &vel) == nil)
        ecs.resume(&view)
        testing.expect(t, ecs.view_dense_slice(&view, &vel) != nil)

        // Misalign vel (single-component removal from pos): the pos table's tail swap
        // mirrors the view's own tail swap, so the pos column stays aligned; the vel
        // table did not move rows while the view did, so the vel column loses alignment.
        testing.expect(t, ecs.remove_component(&pos, eids[3]) == nil)
        testing.expect(t, ecs.view_dense_slice(&view, &pos) != nil, "pos column mirrors the view's tail swap and stays sliceable")
        testing.expect(t, ecs.view_dense_slice(&view, &vel) == nil, "vel column must lose alignment")
        dense__verify_view(t, &view, &pos, &vel)

        // Rebuild follows one table's row order: that column realigns, the other cannot —
        // the tables themselves are now misaligned with each other (pos tail-swapped,
        // vel did not). Exactly one slice works; the record path stays correct either way.
        testing.expect(t, ecs.rebuild(&view) == nil)
        ps_rebuilt := ecs.view_dense_slice(&view, &pos)
        vs_rebuilt := ecs.view_dense_slice(&view, &vel)
        testing.expect(t, (ps_rebuilt != nil) != (vs_rebuilt != nil), "exactly one column can realign after rebuild")
        dense__verify_view(t, &view, &pos, &vel)
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

            if op < 5 || len(alive) == 0 { // create with random subset of components
                if len(alive) < N - 1 {
                    eid, err := ecs.create_entity(&db)
                    if err == nil {
                        which := rand.int_max(4)
                        if which != 1 { p, _ := ecs.add_component(&pos, eid); p^ = { f64(eid.ix), 1 } }
                        if which != 2 { v, _ := ecs.add_component(&vel, eid); v^ = { f64(eid.ix), 2 } }
                        append(&alive, eid)
                    }
                }
            } else if op < 8 { // destroy random entity
                i := rand.int_max(len(alive))
                ecs.destroy_entity(&db, alive[i])
                unordered_remove(&alive, i)
            } else { // remove a single component from a random entity
                i := rand.int_max(len(alive))
                eid := alive[i]
                if op == 8 do ecs.remove_component(&pos, eid)
                else       do ecs.remove_component(&vel, eid)
            }

            if step % 20 == 0 do dense__verify_view(t, &view, &pos, &vel)
        }

        dense__verify_view(t, &view, &pos, &vel)
    }

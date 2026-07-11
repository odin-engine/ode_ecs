/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for owned groups (group.odin): entities that have every owned component
    must occupy the aligned prefix [0, group_len) of every owned table, at the
    same row index in each — maintained incrementally through add/remove/destroy,
    deferred while tail swap is paused, and rebuilt on resume.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:math/rand"

// ODE
    import ecs ".."

    Group_Pos :: struct { x, y: f64 }
    Group_Vel :: struct { x, y: f64 }

    // Oracle: group membership must equal "has pos AND vel"; members must sit at
    // the same row in both tables; slices must hand out exactly those rows; and
    // component payloads (keyed by eid.ix at add time) must have survived the swaps.
    group__verify :: proc(t: ^testing.T, group: ^ecs.Group, pos: ^ecs.Table(Group_Pos), vel: ^ecs.Table(Group_Vel)) {
        expected := 0
        for r in 0..<ecs.table_len(pos) {
            eid := ecs.get_entity(pos, r)
            if eid.ix == ecs.DELETED_INDEX do continue // hole (paused removal)
            if ecs.has_component(vel, eid) do expected += 1
        }
        testing.expect(t, ecs.group_len(group) == expected, "group_len != number of entities having all owned components")

        ps := ecs.group_dense_slice(group, pos)
        vs := ecs.group_dense_slice(group, vel)
        testing.expect(t, len(ps) == ecs.group_len(group))
        testing.expect(t, len(vs) == ecs.group_len(group))

        for i in 0..<ecs.group_len(group) {
            eid_p := ecs.get_entity(pos, i)
            eid_v := ecs.get_entity(vel, i)
            testing.expect(t, eid_p == eid_v, "owned tables must agree on the entity at each prefix row")
            testing.expect(t, ecs.has_component(pos, eid_p) && ecs.has_component(vel, eid_p))
            testing.expect(t, ecs.get_component(pos, eid_p) == &ps[i], "slice row must be the entity's component")
            testing.expect(t, ecs.get_component(vel, eid_p) == &vs[i], "slice row must be the entity's component")
            testing.expect(t, ps[i].x == f64(eid_p.ix), "component payload lost in a swap")
            testing.expect(t, vs[i].x == f64(eid_p.ix), "component payload lost in a swap")
        }
    }

    @(test)
    group__basic__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        extra: ecs.Table(Group_Pos)
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&extra, &db, 100) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)
        testing.expect(t, ecs.is_valid(&group))
        testing.expect(t, ecs.group_len(&group) == 0)

        eids: [10]ecs.entity_id
        for i in 0..<10 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(eids[i].ix), 1 }
            if i % 2 == 0 {
                v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(eids[i].ix), 2 }
            }
        }

        testing.expect(t, ecs.group_len(&group) == 5)
        group__verify(t, &group, &pos, &vel)

        // not an owned table => nil slice
        testing.expect(t, ecs.group_dense_slice(&group, &extra) == nil)

        // removing an owned component removes the entity from the group
        testing.expect(t, ecs.remove_component(&vel, eids[0]) == nil)
        testing.expect(t, ecs.group_len(&group) == 4)
        group__verify(t, &group, &pos, &vel)

        // removing the other owned component does too
        testing.expect(t, ecs.remove_component(&pos, eids[2]) == nil)
        testing.expect(t, ecs.group_len(&group) == 3)
        group__verify(t, &group, &pos, &vel)

        // destroying a member removes it
        testing.expect(t, ecs.destroy_entity(&db, eids[4]) == nil)
        testing.expect(t, ecs.group_len(&group) == 2)
        group__verify(t, &group, &pos, &vel)

        // re-adding the missing component re-joins
        v, verr := ecs.add_component(&vel, eids[0])
        testing.expect(t, verr == nil)
        v^ = { f64(eids[0].ix), 2 }
        testing.expect(t, ecs.group_len(&group) == 3)
        group__verify(t, &group, &pos, &vel)

        // adding a non-owned component changes nothing
        _, xerr := ecs.add_component(&extra, eids[1])
        testing.expect(t, xerr == nil)
        testing.expect(t, ecs.group_len(&group) == 3)
        group__verify(t, &group, &pos, &vel)

        // group_rebuild reproduces the same membership
        testing.expect(t, ecs.group_rebuild(&group) == nil)
        testing.expect(t, ecs.group_len(&group) == 3)
        group__verify(t, &group, &pos, &vel)
    }

    @(test)
    group__init_on_existing_data__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)

        // populate first — and in opposite add orders, so the tables are
        // misaligned with each other before the group exists
        eids: [20]ecs.entity_id
        for i in 0..<20 do eids[i], _ = ecs.create_entity(&db)
        for i in 0..<20 {
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(eids[i].ix), 1 }
        }
        for i := 19; i >= 0; i -= 3 { // every 3rd entity, reverse order
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(eids[i].ix), 2 }
        }

        // group init must build the prefix from the existing rows
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)
        testing.expect(t, ecs.group_len(&group) == 7)
        group__verify(t, &group, &pos, &vel)
    }

    @(test)
    group__ownership__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        ct: ecs.Compact_Table(Group_Vel)
        group_a: ecs.Group
        group_b: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.compact_table__init(&ct, &db, 16) == nil)

        // only Table can be owned
        testing.expect(t, ecs.group_init(&group_a, &db, {&pos, &ct}) == ecs.API_Error.Only_Table_Can_Be_Owned_By_Group)

        // a table has at most one owner
        testing.expect(t, ecs.group_init(&group_a, &db, {&pos, &vel}) == nil)
        testing.expect(t, ecs.group_init(&group_b, &db, {&vel}) == ecs.API_Error.Table_Already_Owned_By_Group)

        // terminating the owner frees the tables for a new group
        testing.expect(t, ecs.group_terminate(&group_a) == nil)
        testing.expect(t, ecs.group_init(&group_b, &db, {&vel}) == nil)

        // single-table group tracks the whole table
        eid, _ := ecs.create_entity(&db)
        v, _ := ecs.add_component(&vel, eid); v^ = { f64(eid.ix), 2 }
        testing.expect(t, ecs.group_len(&group_b) == 1)

        // terminating an owned table invalidates the group; it can still be terminated
        testing.expect(t, ecs.table_terminate(&vel) == nil)
        testing.expect(t, group_b.state == ecs.Object_State.Invalid)
        testing.expect(t, ecs.group_dense_slice(&group_b, &pos) == nil)
        testing.expect(t, ecs.group_terminate(&group_b) == nil)
    }

    @(test)
    group__pause_resume__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)

        eids: [10]ecs.entity_id
        for i in 0..<10 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(eids[i].ix), 1 }
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(eids[i].ix), 2 }
        }
        testing.expect(t, ecs.group_len(&group) == 10)

        ecs.pause_packing(&db)

        // a member losing a component while paused defers group maintenance:
        // rows must not move, the group goes dirty and slices turn nil
        testing.expect(t, ecs.remove_component(&vel, eids[3]) == nil)
        testing.expect(t, ecs.group_dense_slice(&group, &pos) == nil, "dirty group must not hand out slices")

        // a membership gained while paused is deferred too
        testing.expect(t, ecs.destroy_entity(&db, eids[7]) == nil)
        neid, _ := ecs.create_entity(&db)
        np, _ := ecs.add_component(&pos, neid); np^ = { f64(neid.ix), 1 }
        nv, _ := ecs.add_component(&vel, neid); nv^ = { f64(neid.ix), 2 }

        testing.expect(t, ecs.resume_packing(&db) == nil)

        // resume packs the holes and rebuilds the group
        testing.expect(t, ecs.group_len(&group) == 9) // 10 - eids[3] - eids[7] + neid
        group__verify(t, &group, &pos, &vel)
    }

    // Pausing/resuming a table owned by a Group directly is rejected: group
    // membership requires every owned table to move rows in lock-step, so an
    // owned table cannot be paused independently — pause the Group instead.
    @(test)
    group__pause_owned_table_rejected__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)

        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&pos, eid); p^ = { f64(eid.ix), 1 }
        v, _ := ecs.add_component(&vel, eid); v^ = { f64(eid.ix), 2 }
        testing.expect(t, ecs.group_len(&group) == 1)

        testing.expect(t, ecs.pause_packing(&pos) == ecs.API_Error.Cannot_Pause_Table_Owned_By_Group)
        testing.expect(t, ecs.resume_packing(&pos) == ecs.API_Error.Cannot_Pause_Table_Owned_By_Group)
        testing.expect(t, pos.pause_packing == false, "rejected pause must not mutate table state")

        // normal tail-swap removal (and group maintenance) still works
        testing.expect(t, ecs.remove_component(&vel, eid) == nil)
        testing.expect(t, ecs.group_len(&group) == 0)
    }

    // Group-level pause: pausing the group defers membership maintenance for
    // all of its owned tables as one unit, independent of the database-wide
    // flag; resume packs every owned table and rebuilds the prefix. pack is
    // usable mid-pause without rebuilding.
    @(test)
    group__pause_resume_group_level__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)

        eids: [10]ecs.entity_id
        for i in 0..<10 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(eids[i].ix), 1 }
            v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(eids[i].ix), 2 }
        }
        testing.expect(t, ecs.group_len(&group) == 10)

        testing.expect(t, ecs.pause_packing(&group) == nil)
        testing.expect(t, db.tail_swap_paused == false, "group-level pause must not touch the database-wide flag")

        // a member losing a component while group-paused defers group
        // maintenance: rows must not move, the group goes dirty
        testing.expect(t, ecs.remove_component(&vel, eids[3]) == nil)
        testing.expect(t, ecs.group_dense_slice(&group, &pos) == nil, "dirty group must not hand out slices")
        testing.expect(t, pos.holes_count == 0, "no hole yet: eids[3] was still inside the prefix")

        // punch a real (non-tail) hole in pos so pack has something to do
        testing.expect(t, ecs.remove_component(&pos, eids[5]) == nil)
        testing.expect(t, pos.holes_count == 1)

        // pack mid-pause compacts holes without rebuilding the group
        testing.expect(t, ecs.pack(&group) == nil)
        testing.expect(t, pos.holes_count == 0)
        testing.expect(t, ecs.group_dense_slice(&group, &pos) == nil, "still dirty: pack does not rebuild")

        testing.expect(t, ecs.resume_packing(&group) == nil)
        testing.expect(t, ecs.group_len(&group) == 8) // 10 - eids[3] - eids[5]
        group__verify(t, &group, &pos, &vel)
    }

    @(test)
    group__db_clear__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)

        for _ in 0..<8 {
            eid, _ := ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eid); p^ = { f64(eid.ix), 1 }
            v, _ := ecs.add_component(&vel, eid); v^ = { f64(eid.ix), 2 }
        }
        testing.expect(t, ecs.group_len(&group) == 8)

        testing.expect(t, ecs.clear(&db) == nil)
        testing.expect(t, ecs.group_len(&group) == 0)

        // group keeps working after a clear
        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&pos, eid); p^ = { f64(eid.ix), 1 }
        v, _ := ecs.add_component(&vel, eid); v^ = { f64(eid.ix), 2 }
        testing.expect(t, ecs.group_len(&group) == 1)
        group__verify(t, &group, &pos, &vel)
    }

    @(test)
    group__view_coexistence__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        group: ecs.Group
        view: ecs.View
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, 100) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, 100) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&pos, &vel}) == nil)

        eids: [30]ecs.entity_id
        for i in 0..<30 {
            eids[i], _ = ecs.create_entity(&db)
            p, _ := ecs.add_component(&pos, eids[i]); p^ = { f64(eids[i].ix), 1 }
            if i % 3 != 0 {
                v, _ := ecs.add_component(&vel, eids[i]); v^ = { f64(eids[i].ix), 2 }
            }
        }

        // churn a bit so group swaps fire while the view is subscribed
        testing.expect(t, ecs.remove_component(&vel, eids[4]) == nil)
        testing.expect(t, ecs.destroy_entity(&db, eids[10]) == nil)
        va, _ := ecs.add_component(&vel, eids[6]); if va != nil do va^ = { f64(eids[6].ix), 2 }
        v0, verr := ecs.add_component(&vel, eids[0])
        testing.expect(t, verr == nil)
        v0^ = { f64(eids[0].ix), 2 }

        group__verify(t, &group, &pos, &vel)

        // the view must still resolve every row to the right components: group
        // swaps notify subscribed views through view__update_component_address
        it: ecs.Iterator
        rows := 0
        testing.expect(t, ecs.iterator_init(&it, &view) == nil)
        for ecs.iterator_next(&it) {
            eid := ecs.get_entity(&it)
            p_it := ecs.get_component(&pos, &it)
            v_it := ecs.get_component(&vel, &it)
            testing.expect(t, p_it == ecs.get_component(&pos, eid), "view Position != table lookup after group swaps")
            testing.expect(t, v_it == ecs.get_component(&vel, eid), "view Velocity != table lookup after group swaps")
            testing.expect(t, p_it.x == f64(eid.ix))
            testing.expect(t, v_it.x == f64(eid.ix))
            rows += 1
        }
        testing.expect(t, rows == ecs.view_len(&view))
        testing.expect(t, rows == ecs.group_len(&group)) // same membership rule
    }

    @(test)
    group__random_ops_fuzz__test :: proc(t: ^testing.T) {
        db: ecs.Database
        pos: ecs.Table(Group_Pos)
        vel: ecs.Table(Group_Vel)
        group: ecs.Group
        defer ecs.terminate(&db)

        N :: 128

        testing.expect(t, ecs.init(&db, N) == nil)
        testing.expect(t, ecs.table_init(&pos, &db, N) == nil)
        testing.expect(t, ecs.table_init(&vel, &db, N) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)

        rng := rand.create(0xBADD1CE)
        context.random_generator = rand.default_random_generator(&rng)

        alive: [dynamic]ecs.entity_id
        defer delete(alive)

        for step in 0..<3000 {
            op := rand.int_max(12)

            if op < 5 || len(alive) == 0 { // create with random subset of components
                if len(alive) < N - 1 {
                    eid, err := ecs.create_entity(&db)
                    if err == nil {
                        which := rand.int_max(4)
                        if which != 1 { p, _ := ecs.add_component(&pos, eid); if p != nil do p^ = { f64(eid.ix), 1 } }
                        if which != 2 { v, _ := ecs.add_component(&vel, eid); if v != nil do v^ = { f64(eid.ix), 2 } }
                        append(&alive, eid)
                    }
                }
            } else if op < 8 { // destroy random entity
                i := rand.int_max(len(alive))
                ecs.destroy_entity(&db, alive[i])
                unordered_remove(&alive, i)
            } else if op < 10 { // remove a single component
                eid := alive[rand.int_max(len(alive))]
                if op == 8 do ecs.remove_component(&pos, eid)
                else       do ecs.remove_component(&vel, eid)
            } else { // (re-)add a single component
                eid := alive[rand.int_max(len(alive))]
                if op == 10 { p, _ := ecs.add_component(&pos, eid); if p != nil && p.x == 0 do p^ = { f64(eid.ix), 1 } }
                else        { v, _ := ecs.add_component(&vel, eid); if v != nil && v.x == 0 do v^ = { f64(eid.ix), 2 } }
            }

            if step % 25 == 0 do group__verify(t, &group, &pos, &vel)
        }

        group__verify(t, &group, &pos, &vel)

        // one paused block over the final state
        ecs.pause_packing(&db)
        removed := 0
        for i := 0; i < len(alive) && removed < 10; i += 3 {
            if ecs.remove_component(&vel, alive[i]) == nil do removed += 1
        }
        testing.expect(t, ecs.resume_packing(&db) == nil)
        group__verify(t, &group, &pos, &vel)
    }

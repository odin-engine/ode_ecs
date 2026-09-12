/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for growing capacities in place: the entity capacity of an Overbase with its attached
    Databases, and the row capacity of tables, pairs and relations.
*/

package ode_ecs__tests

// Core
    import "core:testing"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Components

    Gr_Position :: struct { x, y: int }
    Gr_Link :: struct { weight: int }

///////////////////////////////////////////////////////////////////////////////
// Overbase

    @(test)
    overbase_grow__test :: proc(t: ^testing.T) {
        ob: ecs.Overbase
        defer ecs.overbase_terminate(&ob)
        testing.expect(t, ecs.overbase_init(&ob, 4, databases_cap = 2) == nil)

        a, b: ecs.Database
        defer ecs.terminate(&b)
        defer ecs.terminate(&a)
        testing.expect(t, ecs.init_from_overbase(&a, &ob) == nil)
        testing.expect(t, ecs.init_from_overbase(&b, &ob) == nil)

        positions: ecs.Table(Gr_Position)
        rel: ecs.Relations_Table
        links: ecs.Pair_Table(Gr_Link)
        flags: ecs.Flags_Table
        view: ecs.View
        testing.expect(t, ecs.table_init(&positions, &a, 4) == nil)
        testing.expect(t, ecs.relations_init(&rel, &a, 4) == nil)
        testing.expect(t, ecs.pair_init(&links, &b, holders_cap = 4, pairs_cap = 4) == nil)
        testing.expect(t, ecs.flags_table_init(&flags, &b, 4) == nil)
        testing.expect(t, ecs.view_init(&view, &a, {&positions}) == nil)

        e: [4]ecs.entity_id
        for &id, i in e {
            id, _ = ecs.create_entity(&ob)
            p, _ := ecs.add_component(&positions, id)
            p^ = { i, i * 10 }
        }
        testing.expect(t, ecs.destroy_entity(&ob, e[3]) == nil)
        e3, _ := ecs.create_entity(&ob) // slot 3, next generation
        testing.expect(t, ecs.set_parent(&a, e[1], e[0]) == nil)
        _, perr := ecs.pair_add(&links, e[0], e[2], Gr_Link{ 7 })
        testing.expect(t, perr == nil)
        testing.expect(t, ecs.flag(&flags, e[2], 5) == nil)

        _, full := ecs.create_entity(&ob)
        testing.expect(t, full != nil)

        testing.expect(t, ecs.grow(&ob, 2) == nil) // smaller: no-op
        testing.expect_value(t, ob.id_factory.cap, 4)
        testing.expect(t, ecs.grow(&ob, 16) == nil)
        testing.expect_value(t, ob.id_factory.cap, 16)

        for i in 0..<3 do testing.expect(t, !ecs.is_expired(&ob, e[i]))
        testing.expect(t, ecs.is_expired(&ob, e[3]))
        testing.expect(t, !ecs.is_expired(&ob, e3))
        testing.expect_value(t, ecs.get_component(&positions, e[2])^, Gr_Position{ 2, 20 })
        parent, _ := ecs.parent_of(&a, e[1])
        testing.expect_value(t, parent, e[0])
        testing.expect(t, ecs.pair_has_pair(&links, e[0], e[2]))
        testing.expect(t, ecs.has_flag(&flags, e[2], 5))
        testing.expect_value(t, len(ecs.entities_slice(&view)), 3)

        testing.expect(t, ecs.grow(&positions, 16) == nil)
        testing.expect(t, ecs.grow(&rel, 16) == nil)
        testing.expect(t, ecs.grow(&links, 16, 16) == nil)
        testing.expect(t, ecs.grow(&flags, 16) == nil)

        more: [12]ecs.entity_id
        for &id, i in more {
            err: ecs.Error
            id, err = ecs.create_entity(&ob)
            testing.expect(t, err == nil)
            c, _ := ecs.add_component(&positions, id)
            c^ = { 100 + i, 0 }
            testing.expect(t, ecs.set_parent(&a, id, e[0]) == nil)
            _, perr = ecs.pair_add(&links, id, e[2], Gr_Link{ i })
            testing.expect(t, perr == nil)
            testing.expect(t, ecs.flag(&flags, id, 1) == nil)
        }
        testing.expect_value(t, more[11].ix, 15)

        parent, _ = ecs.parent_of(&a, more[11])
        testing.expect_value(t, parent, e[0])
        testing.expect(t, ecs.pair_has_pair(&links, more[11], e[2]))
        testing.expect(t, ecs.has_flag(&flags, more[11], 1))

        // cached view pointers follow the rows to their new allocation
        ents := ecs.entities_slice(&view)
        cols := ecs.slice(&view, Gr_Position)
        testing.expect_value(t, len(ents), 15)
        for eid, i in ents do testing.expect(t, cols[i] == ecs.get_component(&positions, eid))
        testing.expect_value(t, ecs.get_component(&positions, e[1])^, Gr_Position{ 1, 10 })
    }

///////////////////////////////////////////////////////////////////////////////
// Compact_Table

    @(test)
    compact_table_grow__test :: proc(t: ^testing.T) {
        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, 32) == nil)

        ct: ecs.Compact_Table(Gr_Position)
        view: ecs.View
        testing.expect(t, ecs.compact_table_init(&ct, &db, 2) == nil)
        testing.expect(t, ecs.view_init(&view, &db, {&ct}) == nil)

        ids: [10]ecs.entity_id
        for &id, i in ids {
            id, _ = ecs.create_entity(&db)
            if i == 2 {
                _, full := ecs.add_component(&ct, id)
                testing.expect(t, full != nil)
                testing.expect(t, ecs.grow(&ct, 10) == nil)
            }
            c, err := ecs.add_component(&ct, id)
            testing.expect(t, err == nil)
            c^ = { i, -i }
        }

        for id, i in ids do testing.expect_value(t, ecs.get_component(&ct, id)^, Gr_Position{ i, -i })

        ents := ecs.entities_slice(&view)
        cols := ecs.slice(&view, Gr_Position)
        testing.expect_value(t, len(ents), 10)
        for eid, i in ents do testing.expect(t, cols[i] == ecs.get_component(&ct, eid))
    }

///////////////////////////////////////////////////////////////////////////////
// Sync

when ecs.SYNC_ENABLED {

    @(test)
    overbase_grow_refuses_sync__test :: proc(t: ^testing.T) {
        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, 4) == nil)

        positions: ecs.Table(Gr_Position)
        testing.expect(t, ecs.table_init(&positions, &db, 4) == nil)

        ch: ecs.Sync_Channel
        defer ecs.sync_channel_terminate(&ch)
        testing.expect(t, ecs.sync_channel_init(&ch, &db, 4) == nil)
        testing.expect(t, ecs.sync_register(&ch, &positions) == nil)

        testing.expect(t, ecs.grow(db.overbase, 8) == ecs.API_Error.Cannot_Grow_With_Sync)
        testing.expect_value(t, db.overbase.id_factory.cap, 4)
    }

} // when ecs.SYNC_ENABLED

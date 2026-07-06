/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Relations_Table: parent/child entity relations with automatic
    cleanup on destroy_entity (orphaning by default, cascade with
    destroy_children = true).
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"
    import "core:slice"
    import "core:math/rand"

// ODE
    import ecs ".."
    import oc "../ode_core"

///////////////////////////////////////////////////////////////////////////////
// Relations_Table

    rel__no_parent :: proc(t: ^testing.T, db: ^ecs.Database, eid: ecs.entity_id) {
        p, err := ecs.parent_of(db, eid)
        testing.expect(t, err == nil)
        testing.expect(t, p.ix == ecs.DELETED_INDEX)
    }

    rel__parent_is :: proc(t: ^testing.T, db: ^ecs.Database, eid, parent: ecs.entity_id) {
        p, err := ecs.parent_of(db, eid)
        testing.expect(t, err == nil)
        testing.expect(t, p == parent)
    }

    // children_of(parent) must contain exactly `expected` (order-insensitive)
    // and agree with children_count.
    rel__children_are :: proc(t: ^testing.T, db: ^ecs.Database, parent: ecs.entity_id, expected: []ecs.entity_id) {
        children, err := ecs.children_of(db, parent)
        testing.expect(t, err == nil)
        testing.expect(t, len(children) == len(expected))

        for e in expected do testing.expect(t, slice.contains(children, e))

        n, cerr := ecs.children_count(db, parent)
        testing.expect(t, cerr == nil)
        testing.expect(t, n == len(expected))
    }

    @(test)
    relations_table__init__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator
        //
        // Test
        //
            db: ecs.Database
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)

            // Every relation proc must fail before relations_table__init
            err: ecs.Error
            err = ecs.set_parent(&db, a, b)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
            err = ecs.remove_parent(&db, a)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
            _, err = ecs.parent_of(&db, a)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
            _, err = ecs.children_of(&db, a)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
            _, err = ecs.children_count(&db, a)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
            _, err = ecs.is_child_of(&db, a, b)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
            _, err = ecs.is_parent_of(&db, a, b)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
            _, err = ecs.has_relations(&db, a)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
            _, err = ecs.is_relation_of(&db, a, b)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)

            rt: ecs.Relations_Table
            testing.expect(t, ecs.relations_table__init(&rt, &db, 10) == nil)
            testing.expect(t, ecs.is_valid(&rt))
            testing.expect(t, ecs.table_len(&rt) == 0)
            testing.expect(t, ecs.table_cap(&rt) == 10)
            testing.expect(t, ecs.memory_usage(&rt) > 0)

            // Only one Relations_Table per database
            rt2: ecs.Relations_Table
            testing.expect(t, ecs.relations_table__init(&rt2, &db, 10) == ecs.API_Error.Relations_Table_Already_Exists)

            // Works after init
            testing.expect(t, ecs.set_parent(&db, a, b) == nil)
            testing.expect(t, ecs.table_len(&rt) == 1)

            // Terminate detaches from the database...
            testing.expect(t, ecs.relations_table__terminate(&rt) == nil)
            _, err = ecs.parent_of(&db, a)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)

            // ...and the same struct can be re-init'd (issue #8 convention)
            testing.expect(t, ecs.relations_table__init(&rt, &db, 10) == nil)
            testing.expect(t, ecs.table_len(&rt) == 0)
            rel__no_parent(t, &db, a) // links do not survive terminate
    }

    @(test)
    relations_table__basic__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            rt: ecs.Relations_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.relations_table__init(&rt, &db, 10) == nil)

            err: ecs.Error
            res: bool

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            d, _ := ecs.create_entity(&db)
            e, _ := ecs.create_entity(&db)
            f, _ := ecs.create_entity(&db)

            // a <- {b, c, d}, b <- {e}, f standalone
            testing.expect(t, ecs.set_parent(&db, b, a) == nil)
            testing.expect(t, ecs.set_parent(&db, c, a) == nil)
            testing.expect(t, ecs.set_parent(&db, d, a) == nil)
            testing.expect(t, ecs.set_parent(&db, e, b) == nil)
            testing.expect(t, ecs.table_len(&rt) == 4)

            rel__parent_is(t, &db, b, a)
            rel__parent_is(t, &db, e, b)
            rel__no_parent(t, &db, a)
            rel__no_parent(t, &db, f)

            rel__children_are(t, &db, a, {b, c, d})
            rel__children_are(t, &db, b, {e})
            rel__children_are(t, &db, f, {})

            res, err = ecs.is_child_of(&db, b, a)
            testing.expect(t, err == nil && res)
            res, err = ecs.is_child_of(&db, a, b)
            testing.expect(t, err == nil && !res)
            res, err = ecs.is_parent_of(&db, a, b)
            testing.expect(t, err == nil && res)
            res, err = ecs.is_parent_of(&db, b, a)
            testing.expect(t, err == nil && !res)

            res, err = ecs.has_relations(&db, a)
            testing.expect(t, err == nil && res) // children only
            res, err = ecs.has_relations(&db, e)
            testing.expect(t, err == nil && res) // parent only
            res, err = ecs.has_relations(&db, f)
            testing.expect(t, err == nil && !res)

            // is_relation_of is symmetric for a direct link, false otherwise
            res, err = ecs.is_relation_of(&db, a, b)
            testing.expect(t, err == nil && res)
            res, err = ecs.is_relation_of(&db, b, a)
            testing.expect(t, err == nil && res)
            res, err = ecs.is_relation_of(&db, a, e) // grandchild is not a direct relation
            testing.expect(t, err == nil && !res)
            res, err = ecs.is_relation_of(&db, f, a)
            testing.expect(t, err == nil && !res)

            // Re-setting the same parent is a no-op
            testing.expect(t, ecs.set_parent(&db, b, a) == nil)
            testing.expect(t, ecs.table_len(&rt) == 4)
            rel__children_are(t, &db, a, {b, c, d})

            // Reparent e from b to a
            testing.expect(t, ecs.set_parent(&db, e, a) == nil)
            testing.expect(t, ecs.table_len(&rt) == 4)
            rel__parent_is(t, &db, e, a)
            rel__children_are(t, &db, a, {b, c, d, e})
            rel__children_are(t, &db, b, {})

            // remove_parent / unparent
            testing.expect(t, ecs.remove_parent(&db, e) == nil)
            rel__no_parent(t, &db, e)
            rel__children_are(t, &db, a, {b, c, d})
            testing.expect(t, ecs.table_len(&rt) == 3)
            testing.expect(t, ecs.unparent(&db, e) == oc.Core_Error.Not_Found)

            // Expired and out-of-bounds entity ids
            testing.expect(t, ecs.destroy_entity(&db, f) == nil)
            testing.expect(t, ecs.set_parent(&db, f, a) == ecs.API_Error.Entity_Id_Expired)
            _, err = ecs.parent_of(&db, f)
            testing.expect(t, err == ecs.API_Error.Entity_Id_Expired)

            bad: ecs.entity_id
            bad.ix = 999
            _, err = ecs.parent_of(&db, bad)
            testing.expect(t, err == ecs.API_Error.Entity_Id_Out_of_Bounds)
            testing.expect(t, ecs.set_parent(&db, bad, a) == ecs.API_Error.Entity_Id_Out_of_Bounds)
    }

    @(test)
    relations_table__cycle__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            rt: ecs.Relations_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.relations_table__init(&rt, &db, 10) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            d, _ := ecs.create_entity(&db)

            // Self-parenting is a cycle of length 1
            testing.expect(t, ecs.set_parent(&db, a, a) == ecs.API_Error.Relation_Cycle)

            // Chain a <- b <- c <- d
            testing.expect(t, ecs.set_parent(&db, b, a) == nil)
            testing.expect(t, ecs.set_parent(&db, c, b) == nil)
            testing.expect(t, ecs.set_parent(&db, d, c) == nil)

            // Two-cycle and deep cycles are rejected
            testing.expect(t, ecs.set_parent(&db, a, b) == ecs.API_Error.Relation_Cycle)
            testing.expect(t, ecs.set_parent(&db, a, d) == ecs.API_Error.Relation_Cycle)
            testing.expect(t, ecs.set_parent(&db, b, d) == ecs.API_Error.Relation_Cycle)

            // Failed set_parent left everything untouched
            testing.expect(t, ecs.table_len(&rt) == 3)
            rel__no_parent(t, &db, a)
            rel__parent_is(t, &db, b, a)
            rel__children_are(t, &db, d, {})

            // Reparenting within the chain that does NOT close a cycle works:
            // d moves up from c to a.
            testing.expect(t, ecs.set_parent(&db, d, a) == nil)
            rel__parent_is(t, &db, d, a)
            rel__children_are(t, &db, a, {b, d})
            rel__children_are(t, &db, c, {})
            testing.expect(t, ecs.table_len(&rt) == 3)
    }

    @(test)
    relations_table__capacity__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            rt: ecs.Relations_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.relations_table__init(&rt, &db, 3) == nil) // cap on relations, not entities

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            d, _ := ecs.create_entity(&db)
            e, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.set_parent(&db, b, a) == nil)
            testing.expect(t, ecs.set_parent(&db, c, a) == nil)
            testing.expect(t, ecs.set_parent(&db, d, a) == nil)
            testing.expect(t, ecs.table_len(&rt) == 3)

            // A new link over cap fails...
            testing.expect(t, ecs.set_parent(&db, e, a) == oc.Core_Error.Container_Is_Full)

            // ...but reparenting an existing link at full cap succeeds
            testing.expect(t, ecs.set_parent(&db, d, b) == nil)
            testing.expect(t, ecs.table_len(&rt) == 3)
            rel__parent_is(t, &db, d, b)

            // Freeing a link makes room again
            testing.expect(t, ecs.remove_parent(&db, d) == nil)
            testing.expect(t, ecs.set_parent(&db, e, a) == nil)
            testing.expect(t, ecs.table_len(&rt) == 3)
    }

    @(test)
    relations_table__destroy_orphan__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            rt: ecs.Relations_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.relations_table__init(&rt, &db, 10) == nil)

            // g <- p <- {c1, c2, c3}
            g,  _ := ecs.create_entity(&db)
            p,  _ := ecs.create_entity(&db)
            c1, _ := ecs.create_entity(&db)
            c2, _ := ecs.create_entity(&db)
            c3, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.set_parent(&db, p, g) == nil)
            testing.expect(t, ecs.set_parent(&db, c1, p) == nil)
            testing.expect(t, ecs.set_parent(&db, c2, p) == nil)
            testing.expect(t, ecs.set_parent(&db, c3, p) == nil)
            testing.expect(t, ecs.table_len(&rt) == 4)

            // Default destroy: children are orphaned, p is unlinked from g
            testing.expect(t, ecs.destroy_entity(&db, p) == nil)
            testing.expect(t, ecs.is_entity_expired(&db, p))

            rel__no_parent(t, &db, c1)
            rel__no_parent(t, &db, c2)
            rel__no_parent(t, &db, c3)
            rel__children_are(t, &db, g, {})
            testing.expect(t, ecs.table_len(&rt) == 0)
    }

    @(test)
    relations_table__destroy_children__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            rt: ecs.Relations_Table
            pos: ecs.Table(Dense_Pos)
            is_alive: ecs.Tag_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=20, allocator=allocator) == nil)
            testing.expect(t, ecs.relations_table__init(&rt, &db, 20) == nil)
            testing.expect(t, ecs.table_init(&pos, &db, 20) == nil)
            testing.expect(t, ecs.tag_table__init(&is_alive, &db, 20) == nil)

            // Tree 1: root <- {a, b}; a <- {a1, a2}; b <- {b1}
            // Tree 2: r2 <- {x}
            // u: unrelated standalone entity
            root, _ := ecs.create_entity(&db)
            a,  _ := ecs.create_entity(&db)
            b,  _ := ecs.create_entity(&db)
            a1, _ := ecs.create_entity(&db)
            a2, _ := ecs.create_entity(&db)
            b1, _ := ecs.create_entity(&db)
            r2, _ := ecs.create_entity(&db)
            x,  _ := ecs.create_entity(&db)
            u,  _ := ecs.create_entity(&db)

            all := [?]ecs.entity_id{ root, a, b, a1, a2, b1, r2, x, u }
            for eid in all {
                p, err := ecs.add_component(&pos, eid)
                testing.expect(t, err == nil)
                p^ = { f64(eid.ix), 0 }
                testing.expect(t, ecs.add_tag(&is_alive, eid) == nil)
            }
            testing.expect(t, ecs.table_len(&pos) == 9)
            testing.expect(t, ecs.table_len(&is_alive) == 9)

            testing.expect(t, ecs.set_parent(&db, a, root) == nil)
            testing.expect(t, ecs.set_parent(&db, b, root) == nil)
            testing.expect(t, ecs.set_parent(&db, a1, a) == nil)
            testing.expect(t, ecs.set_parent(&db, a2, a) == nil)
            testing.expect(t, ecs.set_parent(&db, b1, b) == nil)
            testing.expect(t, ecs.set_parent(&db, x, r2) == nil)
            testing.expect(t, ecs.table_len(&rt) == 6)

            // Cascade destroy of the whole first tree
            testing.expect(t, ecs.destroy_entity(&db, root, destroy_children=true) == nil)

            for eid in ([]ecs.entity_id{ root, a, b, a1, a2, b1 }) {
                testing.expect(t, ecs.is_entity_expired(&db, eid))
            }
            for eid in ([]ecs.entity_id{ r2, x, u }) {
                testing.expect(t, !ecs.is_entity_expired(&db, eid))
            }

            // Component/tag tables shrank by exactly the destroyed subtree
            testing.expect(t, ecs.table_len(&pos) == 3)
            testing.expect(t, ecs.table_len(&is_alive) == 3)

            // Second tree untouched
            rel__parent_is(t, &db, x, r2)
            testing.expect(t, ecs.table_len(&rt) == 1)

            // Cascade destroy of a mid-node: m <- n <- o, destroy n
            m, _ := ecs.create_entity(&db)
            n, _ := ecs.create_entity(&db)
            o, _ := ecs.create_entity(&db)
            testing.expect(t, ecs.set_parent(&db, n, m) == nil)
            testing.expect(t, ecs.set_parent(&db, o, n) == nil)

            testing.expect(t, ecs.destroy_entity(&db, n, destroy_children=true) == nil)
            testing.expect(t, ecs.is_entity_expired(&db, n))
            testing.expect(t, ecs.is_entity_expired(&db, o))
            testing.expect(t, !ecs.is_entity_expired(&db, m))
            rel__children_are(t, &db, m, {})
            testing.expect(t, ecs.table_len(&rt) == 1) // only x <- r2 left
    }

    @(test)
    relations_table__clear__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            rt: ecs.Relations_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.relations_table__init(&rt, &db, 10) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.set_parent(&db, b, a) == nil)
            testing.expect(t, ecs.set_parent(&db, c, b) == nil)

            // Direct clear of the relations table only: entities stay alive,
            // links are gone, table is reusable.
            testing.expect(t, ecs.clear(&rt) == nil)
            testing.expect(t, ecs.table_len(&rt) == 0)
            rel__no_parent(t, &db, b)
            rel__no_parent(t, &db, c)
            rel__children_are(t, &db, a, {})

            testing.expect(t, ecs.set_parent(&db, b, a) == nil)
            testing.expect(t, ecs.table_len(&rt) == 1)

            // Database-level clear also clears relations (and expires entities)
            testing.expect(t, ecs.clear(&db) == nil)
            testing.expect(t, ecs.table_len(&rt) == 0)

            err: ecs.Error
            _, err = ecs.parent_of(&db, a)
            testing.expect(t, err == ecs.API_Error.Entity_Id_Expired)

            a2, _ := ecs.create_entity(&db)
            b2, _ := ecs.create_entity(&db)
            testing.expect(t, ecs.set_parent(&db, b2, a2) == nil)
            rel__parent_is(t, &db, b2, a2)
    }

///////////////////////////////////////////////////////////////////////////////
// Fuzz: random ops cross-checked against a naive shadow model

    // Shadow model: child ix -> {child, parent} for every live link.
    Rel_Shadow_Link :: struct {
        child:  ecs.entity_id,
        parent: ecs.entity_id,
    }

    // Would parenting child under parent close a cycle, per the shadow model?
    rel_shadow__creates_cycle :: proc(shadow: ^map[int]Rel_Shadow_Link, child, parent: ecs.entity_id) -> bool {
        if child == parent do return true

        p := parent
        for {
            link, ok := shadow[p.ix]
            if !ok do return false
            if link.parent == child do return true
            p = link.parent
        }
    }

    // Mirrors destroy_entity in the shadow: removes eid's own parent link,
    // orphans its children, and (with cascade) recursively destroys descendants.
    rel_shadow__destroy :: proc(shadow: ^map[int]Rel_Shadow_Link, alive: ^[dynamic]ecs.entity_id, eid: ecs.entity_id, cascade: bool) {
        if cascade {
            // Collect direct children, destroy them first (their own links
            // and descendants included).
            children: [dynamic]ecs.entity_id
            defer delete(children)
            for _, link in shadow do if link.parent == eid do append(&children, link.child)

            for c in children do rel_shadow__destroy(shadow, alive, c, true)
        } else {
            // Orphan children
            orphans: [dynamic]int
            defer delete(orphans)
            for ix, link in shadow do if link.parent == eid do append(&orphans, ix)

            for ix in orphans do delete_key(shadow, ix)
        }

        delete_key(shadow, eid.ix) // own parent link, if any

        for e, i in alive {
            if e == eid {
                unordered_remove(alive, i)
                break
            }
        }
    }

    rel_fuzz__verify :: proc(t: ^testing.T, db: ^ecs.Database, rt: ^ecs.Relations_Table, shadow: ^map[int]Rel_Shadow_Link, alive: ^[dynamic]ecs.entity_id) {
        testing.expect(t, ecs.table_len(rt) == len(shadow))

        for e in alive {
            // parent_of agrees with the shadow
            p, err := ecs.parent_of(db, e)
            testing.expect(t, err == nil)
            link, has_parent := shadow[e.ix]
            if has_parent do testing.expect(t, p == link.parent)
            else do testing.expect(t, p.ix == ecs.DELETED_INDEX)

            // children_of / children_count agree with the shadow
            expected: [dynamic]ecs.entity_id
            defer delete(expected)
            for _, l in shadow do if l.parent == e do append(&expected, l.child)

            children, cerr := ecs.children_of(db, e)
            testing.expect(t, cerr == nil)
            testing.expect(t, len(children) == len(expected))
            for c in expected do testing.expect(t, slice.contains(children, c))

            n, nerr := ecs.children_count(db, e)
            testing.expect(t, nerr == nil)
            testing.expect(t, n == len(expected))

            // has_relations consistency
            has, herr := ecs.has_relations(db, e)
            testing.expect(t, herr == nil)
            testing.expect(t, has == (has_parent || len(expected) > 0))
        }
    }

    @(test)
    relations_table__random_ops_fuzz__test :: proc(t: ^testing.T) {
        db: ecs.Database
        rt: ecs.Relations_Table
        defer ecs.terminate(&db)

        N :: 64
        CAP :: 48 // relations cap below entity cap so Container_Is_Full is exercised

        testing.expect(t, ecs.init(&db, N) == nil)
        testing.expect(t, ecs.relations_table__init(&rt, &db, CAP) == nil)

        rng := rand.create(0xC0FFEE)
        context.random_generator = rand.default_random_generator(&rng)

        shadow: map[int]Rel_Shadow_Link
        defer delete(shadow)
        alive: [dynamic]ecs.entity_id
        defer delete(alive)

        for step in 0..<2000 {
            op := rand.int_max(100)

            if op < 35 || len(alive) == 0 { // create
                if len(alive) < N - 1 {
                    eid, err := ecs.create_entity(&db)
                    if err == nil do append(&alive, eid)
                }
            } else if op < 55 { // destroy, randomly cascading
                i := rand.int_max(len(alive))
                eid := alive[i]
                cascade := rand.int_max(2) == 0
                testing.expect(t, ecs.destroy_entity(&db, eid, destroy_children=cascade) == nil)
                rel_shadow__destroy(&shadow, &alive, eid, cascade)
            } else if op < 85 { // set_parent on a random pair, expected result from the shadow
                child := alive[rand.int_max(len(alive))]
                parent := alive[rand.int_max(len(alive))]

                err := ecs.set_parent(&db, child, parent)

                existing, has_link := shadow[child.ix]
                if has_link && existing.parent == parent {
                    testing.expect(t, err == nil) // no-op
                } else if rel_shadow__creates_cycle(&shadow, child, parent) {
                    testing.expect(t, err == ecs.API_Error.Relation_Cycle)
                } else if !has_link && len(shadow) >= CAP {
                    testing.expect(t, err == oc.Core_Error.Container_Is_Full)
                } else {
                    testing.expect(t, err == nil)
                    shadow[child.ix] = Rel_Shadow_Link{ child, parent }
                }
            } else if op < 95 { // remove_parent
                child := alive[rand.int_max(len(alive))]
                err := ecs.remove_parent(&db, child)
                if _, has_link := shadow[child.ix]; has_link {
                    testing.expect(t, err == nil)
                    delete_key(&shadow, child.ix)
                } else {
                    testing.expect(t, err == oc.Core_Error.Not_Found)
                }
            } else { // pure queries on a random pair must never error for alive ids
                x := alive[rand.int_max(len(alive))]
                y := alive[rand.int_max(len(alive))]
                _, err1 := ecs.is_child_of(&db, x, y)
                _, err2 := ecs.is_relation_of(&db, x, y)
                testing.expect(t, err1 == nil && err2 == nil)
            }

            if step % 20 == 0 do rel_fuzz__verify(t, &db, &rt, &shadow, &alive)
        }

        rel_fuzz__verify(t, &db, &rt, &shadow, &alive)
    }

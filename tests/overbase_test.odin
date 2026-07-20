/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Overbase: a shared entity ID space that multiple Databases can
    attach to (see overbase.odin / docs/overbase.md).
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs ".."
    import oc "../ode_core"

///////////////////////////////////////////////////////////////////////////////
// Components

    Ob_Position :: struct { x, y: int }
    Ob_Sprite :: struct { texture_id: int }

///////////////////////////////////////////////////////////////////////////////
// Overbase

    @(test)
    overbase_lifecycle__test :: proc(t: ^testing.T) {
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

            testing.expect(t, ecs.overbase_init(&ob, entities_cap=0, allocator=allocator) == ecs.API_Error.Entities_Cap_Should_Be_Greater_Than_Zero)
            testing.expect(t, ecs.overbase_init(&ob, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.is_valid(&ob))
            testing.expect(t, ecs.entities_len(&ob) == 0)
            testing.expect(t, ecs.memory_usage(&ob) > 0)

            eid, err := ecs.create_entity(&ob)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.entities_len(&ob) == 1)
            testing.expect(t, ecs.is_expired(&ob, eid) == false)

            testing.expect(t, ecs.destroy_entity(&ob, eid) == nil)
            testing.expect(t, ecs.entities_len(&ob) == 0)
            testing.expect(t, ecs.is_expired(&ob, eid) == true)
    }

    // Plain ecs.init(&db, ...) must behave exactly as before — it owns a
    // private, embedded Overbase; nothing about the public entity API changes.
    @(test)
    overbase_default_database_unaffected__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
        //
        // Test
        //
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.is_valid(&db))

            eid_1, err_1 := ecs.create_entity(&db)
            testing.expect(t, err_1 == nil)
            eid_2, err_2 := ecs.create_entity(&db)
            testing.expect(t, err_2 == nil)
            testing.expect(t, ecs.entities_len(&db) == 2)

            testing.expect(t, ecs.destroy_entity(&db, eid_1) == nil)
            testing.expect(t, ecs.is_expired(&db, eid_1) == true)
            testing.expect(t, ecs.is_expired(&db, eid_2) == false)
            testing.expect(t, ecs.destroy_entity(&db, eid_1) == ecs.API_Error.Entity_Id_Expired)
    }

    // Two Databases attached to the same Overbase see the same entity ids.
    @(test)
    overbase_shared_entities__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            db_a: ecs.Database
            db_b: ecs.Database
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&db_a)
            defer ecs.terminate(&db_b)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap=10, databases_cap=2, allocator=allocator) == nil)

            // allocator omitted -> falls back to ob's allocator
            testing.expect(t, ecs.init_from_overbase(&db_a, &ob) == nil)
            // allocator given explicitly -> overrides
            testing.expect(t, ecs.init_from_overbase(&db_b, &ob, allocator) == nil)

            testing.expect(t, db_a.owns_overbase == false)
            testing.expect(t, db_b.owns_overbase == false)
            testing.expect(t, db_a.overbase == &ob)
            testing.expect(t, db_b.overbase == &ob)

            eid, err := ecs.create_entity(&ob)
            testing.expect(t, err == nil)

            testing.expect(t, ecs.is_expired(&db_a, eid) == false)
            testing.expect(t, ecs.is_expired(&db_b, eid) == false)
            testing.expect(t, ecs.entities_len(&db_a) == 1)
            testing.expect(t, ecs.entities_len(&db_b) == 1)
    }

    // A third Database exceeding overbase_init's databases_cap is rejected —
    // fully preallocated, no hidden growth.
    @(test)
    overbase_databases_cap_enforced__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            db_a: ecs.Database
            db_b: ecs.Database
            db_c: ecs.Database
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&db_a)
            defer ecs.terminate(&db_b)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap=10, databases_cap=2, allocator=allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&db_a, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&db_b, &ob) == nil)

            testing.expect(t, ecs.init_from_overbase(&db_c, &ob) == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs.is_valid(&db_c) == false) // failed init, never attached, safe to drop
    }

    // Core correctness: destroying an entity through either Database sharing
    // an Overbase removes its components from BOTH — a recycled index must
    // never resurface stale data in a Database that wasn't told the entity died.
    @(test)
    overbase_destroy_cleans_all_databases__test :: proc(t: ^testing.T) {
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

            testing.expect(t, ecs.overbase_init(&ob, entities_cap=10, databases_cap=2, allocator=allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)

            testing.expect(t, ecs.table_init(&positions, &world_db, 10) == nil)
            testing.expect(t, ecs.table_init(&sprites, &render_db, 10) == nil)

            robot, err := ecs.create_entity(&ob)
            testing.expect(t, err == nil)

            _, perr := ecs.add_component(&positions, robot)
            testing.expect(t, perr == nil)
            _, serr := ecs.add_component(&sprites, robot)
            testing.expect(t, serr == nil)

            testing.expect(t, ecs.has_component(&positions, robot))
            testing.expect(t, ecs.has_component(&sprites, robot))

            // Destroy through world_db only — must still clean render_db.
            testing.expect(t, ecs.destroy_entity(&world_db, robot) == nil)

            testing.expect(t, ecs.has_component(&positions, robot) == false)
            testing.expect(t, ecs.has_component(&sprites, robot) == false)
            testing.expect(t, ecs.is_expired(&world_db, robot) == true)
            testing.expect(t, ecs.is_expired(&render_db, robot) == true)

            // The recycled index must come back clean for a brand-new entity —
            // no leftover Ob_Sprite from `robot` visible on render_db.
            robot_2, err_2 := ecs.create_entity(&ob)
            testing.expect(t, err_2 == nil)
            testing.expect(t, robot_2.ix == robot.ix) // index reused
            testing.expect(t, ecs.has_component(&sprites, robot_2) == false)
            testing.expect(t, ecs.has_component(&positions, robot_2) == false)
    }

    // Terminating a Database that doesn't own its Overbase must not touch it —
    // the shared Overbase stays usable afterward.
    @(test)
    overbase_survives_non_owning_terminate__test :: proc(t: ^testing.T) {
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
            testing.expect(t, ecs.overbase_init(&ob, entities_cap=10, databases_cap=1, allocator=allocator) == nil)

            db: ecs.Database
            testing.expect(t, ecs.init_from_overbase(&db, &ob) == nil)
            eid, _ := ecs.create_entity(&ob)

            ecs.terminate(&db)

            testing.expect(t, ecs.is_valid(&ob)) // shared overbase survived
            testing.expect(t, ecs.is_expired(&ob, eid) == false) // entity state untouched

            // Overbase is usable again for a new Database (databases_cap freed up)
            db_2: ecs.Database
            defer ecs.terminate(&db_2)
            testing.expect(t, ecs.init_from_overbase(&db_2, &ob) == nil)
    }

    // destroy_children cascades through the relations table on one Database
    // and still cleans descendants' components from a sibling Database that
    // has no relations table of its own.
    @(test)
    overbase_destroy_children_cascades_across_databases__test :: proc(t: ^testing.T) {
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
            rt: ecs.Relations_Table
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap=10, databases_cap=2, allocator=allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)

            testing.expect(t, ecs.table_init(&positions, &world_db, 10) == nil)
            testing.expect(t, ecs.table_init(&sprites, &render_db, 10) == nil)
            testing.expect(t, ecs.relations_init(&rt, &world_db, 10) == nil)

            parent, _ := ecs.create_entity(&ob)
            child, _ := ecs.create_entity(&ob)

            testing.expect(t, ecs.set_parent(&world_db, child, parent) == nil)

            _, perr := ecs.add_component(&positions, child)
            testing.expect(t, perr == nil)
            _, serr := ecs.add_component(&sprites, child)
            testing.expect(t, serr == nil)

            testing.expect(t, ecs.destroy_entity(&world_db, parent, destroy_children=true) == nil)

            testing.expect(t, ecs.is_expired(&ob, child) == true)
            testing.expect(t, ecs.is_expired(&ob, parent) == true)
            testing.expect(t, ecs.has_component(&positions, child) == false)
            testing.expect(t, ecs.has_component(&sprites, child) == false)
    }

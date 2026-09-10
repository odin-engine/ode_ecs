/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Any_Table (type-erased table handle), entity_tables and
    clone_component. See any_table.odin and clone.odin.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"
    import "core:slice"

// ODE
    import ecs "../src"
    import oc "../src/ode_core"

///////////////////////////////////////////////////////////////////////////////
// Fixtures

    Any_Pos :: struct {
        x, y: f32,
    }

    Any_Vel :: struct {
        dx, dy: f32,
    }

    Any_Hp :: struct {
        current: int,
    }

///////////////////////////////////////////////////////////////////////////////
// Metadata

    @(test)
    any_table__metadata__test :: proc(t: ^testing.T) {
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
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)

            positions: ecs.Table(Any_Pos)
            compact:   ecs.Compact_Table(Any_Vel)
            tiny:      ecs.Tiny_Table(Any_Hp)
            dead:      ecs.Tag_Table

            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.compact_table_init(&compact, &db, 8) == nil)
            testing.expect(t, ecs.tiny_table_init(&tiny, &db) == nil)
            testing.expect(t, ecs.tag_table_init(&dead, &db, 16) == nil)

            ap := ecs.any_table(&positions)
            ac := ecs.any_table(&compact)
            at := ecs.any_table(&tiny)
            ad := ecs.any_table(&dead)

            testing.expect(t, ecs.any_table_type(ap) == ecs.Table_Type.Table)
            testing.expect(t, ecs.any_table_type(ac) == ecs.Table_Type.Compact_Table)
            testing.expect(t, ecs.any_table_type(at) == ecs.Table_Type.Tiny_Table)
            testing.expect(t, ecs.any_table_type(ad) == ecs.Table_Type.Tag_Table)

            testing.expect(t, ecs.any_table_component_type(ap) == Any_Pos)
            testing.expect(t, ecs.any_table_component_type(ac) == Any_Vel)
            testing.expect(t, ecs.any_table_component_type(at) == Any_Hp)
            testing.expect(t, ecs.any_table_component_type(ad) == nil)

            testing.expect(t, ecs.any_table_component_size(ap) == size_of(Any_Pos))
            testing.expect(t, ecs.any_table_component_size(ad) == 0)

            testing.expect(t, ecs.any_table_column_count(ap) == 1)
            testing.expect(t, ecs.any_table_column_count(ad) == 0)
            testing.expect(t, ecs.any_table_column_type(ap, 0) == Any_Pos)
            testing.expect(t, ecs.any_table_column_type(ap, 1) == nil)

            testing.expect(t, ecs.any_table_cap(ap) == 16)
            testing.expect(t, ecs.any_table_len(ap) == 0)
            testing.expect(t, ecs.any_table_is_valid(ap))

            // The handle round-trips to the same table it came from.
            back, ok := ecs.any_table_by_id(&db, ecs.any_table_id(ap), ecs.Table_Type.Table)
            testing.expect(t, ok && back == ap)

            back, ok = ecs.any_table_by_id(&db, ecs.any_table_id(ad), ecs.Table_Type.Tag_Table)
            testing.expect(t, ok && back == ad)
    }

    @(test)
    any_table__enumeration__test :: proc(t: ^testing.T) {
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
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)

            positions: ecs.Table(Any_Pos)
            velocities: ecs.Table(Any_Vel)
            dead: ecs.Tag_Table

            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.table_init(&velocities, &db, 16) == nil)
            testing.expect(t, ecs.tag_table_init(&dead, &db, 16) == nil)

            testing.expect(t, ecs.any_tables_len(&db) == 3)

            buf: [8]ecs.Any_Table
            all, err := ecs.any_tables(&db, buf[:])
            testing.expect(t, err == nil)
            testing.expect(t, len(all) == 3)
            testing.expect(t, slice.contains(all, ecs.any_table(&positions)))
            testing.expect(t, slice.contains(all, ecs.any_table(&velocities)))
            testing.expect(t, slice.contains(all, ecs.any_table(&dead)))

            // A buffer that cannot hold them all reports it, and still returns what fit.
            small: [2]ecs.Any_Table
            some, serr := ecs.any_tables(&db, small[:])
            testing.expect(t, serr == oc.Core_Error.Container_Is_Full)
            testing.expect(t, len(some) == 2)
    }

///////////////////////////////////////////////////////////////////////////////
// Type-erased rows

    @(test)
    any_table__row_round_trip__test :: proc(t: ^testing.T) {
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
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)

            positions: ecs.Table(Any_Pos)
            compact:   ecs.Compact_Table(Any_Vel)
            tiny:      ecs.Tiny_Table(Any_Hp)
            dead:      ecs.Tag_Table

            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.compact_table_init(&compact, &db, 8) == nil)
            testing.expect(t, ecs.tiny_table_init(&tiny, &db) == nil)
            testing.expect(t, ecs.tag_table_init(&dead, &db, 16) == nil)

            eid, _ := ecs.create_entity(&db)

            // Write through the type-erased handle, read back through the typed one.
            value := Any_Pos{ x = 3, y = 4 }
            ap := ecs.any_table(&positions)
            c, err := ecs.any_table_add_component(ap, eid, &value)
            testing.expect(t, err == nil && c != nil)

            typed := ecs.get_component(&positions, eid)
            testing.expect(t, typed != nil && typed.x == 3 && typed.y == 4)
            testing.expect(t, ecs.any_table_has_component(ap, eid))
            testing.expect(t, ecs.any_table_len(ap) == 1)

            // Same for the other data variants.
            vel := Any_Vel{ dx = 1, dy = 2 }
            _, err = ecs.any_table_add_component(ecs.any_table(&compact), eid, &vel)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.get_component(&compact, eid).dx == 1)

            hp := Any_Hp{ current = 7 }
            _, err = ecs.any_table_add_component(ecs.any_table(&tiny), eid, &hp)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.get_component(&tiny, eid).current == 7)

            // Tag_Table: add works, get_component is nil by design, has_component is the real answer.
            ad := ecs.any_table(&dead)
            _, err = ecs.any_table_add_component(ad, eid)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.has_tag(&dead, eid))
            testing.expect(t, ecs.any_table_has_component(ad, eid))
            testing.expect(t, ecs.any_table_get_component(ad, eid) == nil)

            testing.expect(t, ecs.any_table_get_entity(ap, 0) == eid)
            testing.expect(t, len(ecs.any_table_entities_slice(ap)) == 1)

            // Remove through the handle.
            testing.expect(t, ecs.any_table_remove_component(ap, eid) == nil)
            testing.expect(t, !ecs.has_component(&positions, eid))
            testing.expect(t, !ecs.any_table_has_component(ap, eid))

            testing.expect(t, ecs.any_table_remove_component(ad, eid) == nil)
            testing.expect(t, !ecs.has_tag(&dead, eid))
    }

///////////////////////////////////////////////////////////////////////////////
// entity_tables

    @(test)
    any_table__entity_tables__test :: proc(t: ^testing.T) {
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
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)

            positions: ecs.Table(Any_Pos)
            velocities: ecs.Table(Any_Vel)
            dead: ecs.Tag_Table

            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.table_init(&velocities, &db, 16) == nil)
            testing.expect(t, ecs.tag_table_init(&dead, &db, 16) == nil)

            eid, _ := ecs.create_entity(&db)
            bare, _ := ecs.create_entity(&db)

            buf: [8]ecs.Any_Table

            // An entity with nothing is in no tables.
            res, err := ecs.entity_tables(&db, bare, buf[:])
            testing.expect(t, err == nil && len(res) == 0)

            ecs.add_component(&positions, eid)
            ecs.add_tag(&dead, eid)

            res, err = ecs.entity_tables(&db, eid, buf[:])
            testing.expect(t, err == nil)
            testing.expect(t, len(res) == 2)
            testing.expect(t, slice.contains(res, ecs.any_table(&positions)))
            testing.expect(t, slice.contains(res, ecs.any_table(&dead)))
            testing.expect(t, !slice.contains(res, ecs.any_table(&velocities)))

            ecs.add_component(&velocities, eid)
            res, _ = ecs.entity_tables(&db, eid, buf[:])
            testing.expect(t, len(res) == 3)

            ecs.remove_component(&positions, eid)
            res, _ = ecs.entity_tables(&db, eid, buf[:])
            testing.expect(t, len(res) == 2)
            testing.expect(t, !slice.contains(res, ecs.any_table(&positions)))

            // Every reported table really does hold the entity.
            for a in res {
                testing.expect(t, ecs.any_table_has_component(a, eid))
            }
    }

///////////////////////////////////////////////////////////////////////////////
// clone_component

    @(test)
    clone_component__typed__test :: proc(t: ^testing.T) {
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
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)

            positions: ecs.Table(Any_Pos)
            compact:   ecs.Compact_Table(Any_Vel)
            tiny:      ecs.Tiny_Table(Any_Hp)

            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.compact_table_init(&compact, &db, 8) == nil)
            testing.expect(t, ecs.tiny_table_init(&tiny, &db) == nil)

            archetype, _ := ecs.create_entity(&db)
            instance,  _ := ecs.create_entity(&db)
            empty,     _ := ecs.create_entity(&db)

            src, _ := ecs.add_component(&positions, archetype)
            src.x = 10
            src.y = 20

            c, err := ecs.clone_component(&positions, archetype, instance)
            testing.expect(t, err == nil && c != nil)
            testing.expect(t, c.x == 10 && c.y == 20)
            testing.expect(t, ecs.has_component(&positions, instance))

            // The clone is independent — mutating the source must not move it.
            src = ecs.get_component(&positions, archetype)
            src.x = 999
            testing.expect(t, ecs.get_component(&positions, instance).x == 10)

            // Cloning onto an entity that already has one overwrites it.
            c, err = ecs.clone_component(&positions, archetype, instance)
            testing.expect(t, err == nil && c.x == 999)

            // No source component.
            _, err = ecs.clone_component(&positions, empty, instance)
            testing.expect(t, err == oc.Core_Error.Not_Found)

            // Same entity is a no-op that still hands back the component.
            c, err = ecs.clone_component(&positions, archetype, archetype)
            testing.expect(t, err == nil && c.x == 999)

            // Compact_Table and Tiny_Table go through the same proc group.
            v, _ := ecs.add_component(&compact, archetype)
            v.dx = 5
            vc, verr := ecs.clone_component(&compact, archetype, instance)
            testing.expect(t, verr == nil && vc.dx == 5)

            h, _ := ecs.add_component(&tiny, archetype)
            h.current = 42
            hc, herr := ecs.clone_component(&tiny, archetype, instance)
            testing.expect(t, herr == nil && hc.current == 42)
    }

    @(test)
    clone_component__type_erased__test :: proc(t: ^testing.T) {
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
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)

            positions: ecs.Table(Any_Pos)
            velocities: ecs.Table(Any_Vel)
            wooden: ecs.Tag_Table

            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.table_init(&velocities, &db, 16) == nil)
            testing.expect(t, ecs.tag_table_init(&wooden, &db, 16) == nil)

            archetype, _ := ecs.create_entity(&db)
            instance,  _ := ecs.create_entity(&db)

            p, _ := ecs.add_component(&positions, archetype)
            p.x = 1
            p.y = 2
            v, _ := ecs.add_component(&velocities, archetype)
            v.dx = 3
            ecs.add_tag(&wooden, archetype)

            // What a data-driven baker does: clone every table the template is in,
            // without knowing any of their component types.
            buf: [8]ecs.Any_Table
            tables, _ := ecs.entity_tables(&db, archetype, buf[:])
            testing.expect(t, len(tables) == 3)

            for a in tables {
                testing.expect(t, ecs.any_table_clone_component(a, archetype, instance) == nil)
            }

            testing.expect(t, ecs.get_component(&positions, instance).x == 1)
            testing.expect(t, ecs.get_component(&positions, instance).y == 2)
            testing.expect(t, ecs.get_component(&velocities, instance).dx == 3)
            testing.expect(t, ecs.has_tag(&wooden, instance))

            // Independent copy.
            ecs.get_component(&positions, archetype).x = 777
            testing.expect(t, ecs.get_component(&positions, instance).x == 1)

            // Missing source row.
            fresh, _ := ecs.create_entity(&db)
            testing.expect(t, ecs.any_table_clone_component(ecs.any_table(&positions), fresh, instance) == oc.Core_Error.Not_Found)
    }

/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Database tag storage allocated on the first Tag_Table.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Lazy tag storage

    Lt_Pos :: struct {
        x, y: f32,
    }

    Lt_Like :: struct {
        weight: f32,
    }

    @(test)
    database__lazy_tag_storage__test :: proc(t: ^testing.T) {
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
            db, db2: ecs.Database
            positions, positions2: ecs.Table(Lt_Pos)
            status, status2: ecs.Flags_Table
            alive: ecs.Tag_Table
            view, flags_view, tag_view: ecs.View
            defer ecs.terminate(&db)
            defer ecs.terminate(&db2)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, db.tag_tables.items == nil && db.eid_to_tag_bits == nil && db.eid_to_tag_disabled_bits == nil)

            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions}) == nil)
            testing.expect(t, ecs.view_init(&flags_view, &db, {&positions, ecs.flags_term(&status, {1})}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.add_component(&positions, b)
            testing.expect(t, ecs.flag(&status, a, 1) == nil)
            testing.expect(t, ecs.view_len(&view) == 2 && ecs.view_len(&flags_view) == 1)

            // disabling a component turns on the disabled-bits path in view matching
            testing.expect(t, ecs.disable_component(&positions, b) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, ecs.enable_component(&positions, b) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)

            tables_buf: [8]ecs.Any_Table
            tables, terr := ecs.entity_tables(&db, a, tables_buf[:])
            testing.expect(t, terr == nil && len(tables) == 2)

            // snapshot round trip between two tagless databases
            testing.expect(t, ecs.init(&db2, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions2, &db2, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status2, &db2, 16) == nil)

            size, serr := ecs.serialized_size(&db)
            testing.expect(t, serr == nil)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            written, werr := ecs.serialize(&db, buf)
            testing.expect(t, werr == nil)
            testing.expect(t, ecs.deserialize(&db2, buf[:written]) == nil)
            testing.expect(t, ecs.get_flags(&status2, a) == ecs.Bits{1})
            testing.expect(t, ecs.table_len(&positions2) == 2)
            testing.expect(t, db2.eid_to_tag_bits == nil)

            testing.expect(t, ecs.destroy_entity(&db, b) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, db.eid_to_tag_bits == nil)

            // the first Tag_Table allocates all three
            testing.expect(t, ecs.tag_table__init(&alive, &db, 16) == nil)
            testing.expect(t, db.tag_tables.items != nil)
            testing.expect(t, len(db.eid_to_tag_bits) == 16 && len(db.eid_to_tag_disabled_bits) == 16)

            testing.expect(t, ecs.tag(&alive, a) == nil)
            testing.expect(t, ecs.view_init(&tag_view, &db, {&positions, &alive}) == nil)
            testing.expect(t, ecs.rebuild(&tag_view) == nil)
            testing.expect(t, ecs.view_len(&tag_view) == 1)

            // terminating the tag table keeps the arrays
            testing.expect(t, ecs.tag_table__terminate(&alive) == nil)
            testing.expect(t, db.eid_to_tag_bits != nil && db.eid_to_tag_disabled_bits != nil)
            testing.expect(t, ecs.destroy_entity(&db, a) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)
    }

    @(test)
    database__pair_table_allocates_tag_storage__test :: proc(t: ^testing.T) {
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
            likes: ecs.Pair_Table(Lt_Like)
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, db.eid_to_tag_bits == nil)

            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap = 8, pairs_cap = 8) == nil)
            testing.expect(t, len(db.eid_to_tag_bits) == 16 && len(db.eid_to_tag_disabled_bits) == 16)
    }

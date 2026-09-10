/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Flags_Table: up to 128 flags per entity, stored as a Compact_Table(Bits).
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"
    import "core:slice"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Flags_Table

    Ft_Status :: enum u8 {
        Alert,
        Armed,
        Wounded,
        Asleep,
    }

    @(test)
    flags_table__flag_unflag__test :: proc(t: ^testing.T) {
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
            status: ecs.Flags_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)

            a, _ := ecs.create_entity(&db)

            testing.expect(t, !ecs.has_tag(&status, a))
            testing.expect(t, ecs.table_len(&status) == 0)

            testing.expect(t, ecs.flag(&status, a, 3) == nil)
            testing.expect(t, ecs.has_flag(&status, a, 3))
            testing.expect(t, ecs.has_tag(&status, a))
            testing.expect(t, ecs.table_len(&status) == 1)

            testing.expect(t, ecs.flag(&status, a, 5) == nil)
            testing.expect(t, ecs.get_flags(&status, a) == ecs.Bits{3, 5})
            testing.expect(t, ecs.table_len(&status) == 1)

            testing.expect(t, ecs.unflag(&status, a, 3) == nil)
            testing.expect(t, ecs.get_flags(&status, a) == ecs.Bits{5})

            testing.expect(t, ecs.unflag(&status, a, 5) == nil)
            testing.expect(t, ecs.get_flags(&status, a) == ecs.Bits{})
            testing.expect(t, !ecs.has_tag(&status, a))
            testing.expect(t, ecs.table_len(&status) == 0)

            testing.expect(t, ecs.tag(&status, a, 7) == nil)
            testing.expect(t, ecs.has_tag(&status, a, 7))
            testing.expect(t, ecs.untag(&status, a, 7) == nil)
            testing.expect(t, !ecs.has_tag(&status, a, 7))
    }

    @(test)
    flags_table__enum_forms__test :: proc(t: ^testing.T) {
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
            status: ecs.Flags_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)

            a, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.flag(&status, a, Ft_Status.Armed) == nil)
            testing.expect(t, ecs.has_flag(&status, a, Ft_Status.Armed))
            testing.expect(t, !ecs.has_flag(&status, a, Ft_Status.Alert))

            testing.expect(t, ecs.flags_of(Ft_Status.Alert, Ft_Status.Armed) == ecs.Bits{0, 1})
            testing.expect(t, ecs.flags_of(Ft_Status.Asleep) == ecs.Bits{3})
            testing.expect(t, ecs.flags_of(bit_set[Ft_Status]{.Alert, .Wounded}) == ecs.Bits{0, 2})

            testing.expect(t, ecs.set_flags(&status, a, ecs.flags_of(Ft_Status.Alert, Ft_Status.Wounded)) == nil)
            testing.expect(t, ecs.get_flags(&status, a) == ecs.Bits{0, 2})

            testing.expect(t, ecs.unflag(&status, a, Ft_Status.Alert) == nil)
            testing.expect(t, ecs.get_flags(&status, a) == ecs.Bits{2})
    }

    @(test)
    flags_table__has_flags_ops__test :: proc(t: ^testing.T) {
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
            status: ecs.Flags_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            testing.expect(t, ecs.set_flags(&status, a, {1, 2}) == nil)

            testing.expect(t, ecs.has_flags(&status, a, {1}))
            testing.expect(t, ecs.has_flags(&status, a, {1, 2}, .And))
            testing.expect(t, !ecs.has_flags(&status, a, {1, 3}))

            testing.expect(t, ecs.has_flags(&status, a, {2, 9}, .Or))
            testing.expect(t, !ecs.has_flags(&status, a, {3, 4}, .Or))

            testing.expect(t, ecs.has_flags(&status, a, {1, 9}, .Xor))
            testing.expect(t, !ecs.has_flags(&status, a, {1, 2}, .Xor))

            testing.expect(t, ecs.has_flags(&status, a, {3, 4}, .Nor))
            testing.expect(t, !ecs.has_flags(&status, a, {1}, .Nor))

            testing.expect(t, ecs.has_flags(&status, a, {1, 3}, .Nand))
            testing.expect(t, !ecs.has_flags(&status, a, {1, 2}, .Nand))

            testing.expect(t, ecs.has_flags(&status, a, {1, 2}, .Exact))
            testing.expect(t, !ecs.has_flags(&status, a, {1}, .Exact))
            testing.expect(t, !ecs.has_flags(&status, a, {}, .Exact))
            testing.expect(t, ecs.has_flags(&status, b, {}, .Exact))
    }

    @(test)
    flags_table__row_invariant__test :: proc(t: ^testing.T) {
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
            status: ecs.Flags_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)

            a, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.set_flags(&status, a, {}) == nil)
            testing.expect(t, ecs.table_len(&status) == 0)
            testing.expect(t, ecs.set_flags(&status, a, {4}) == nil)
            testing.expect(t, ecs.table_len(&status) == 1)
            testing.expect(t, ecs.set_flags(&status, a, {}) == nil)
            testing.expect(t, ecs.table_len(&status) == 0)

            at := ecs.any_table(&status)
            testing.expect(t, ecs.any_table_type(at) == ecs.Table_Type.Flags_Table)
            testing.expect(t, ecs.any_table_component_type(at) == ecs.Bits)

            empty: ecs.Bits
            _, err := ecs.any_table_add_component(at, a, &empty)
            testing.expect(t, err == ecs.API_Error.Flags_Bits_Cannot_Be_Empty)
            _, err = ecs.any_table_add_component(at, a, nil)
            testing.expect(t, err == ecs.API_Error.Flags_Bits_Cannot_Be_Empty)
            testing.expect(t, ecs.table_len(&status) == 0)

            six := ecs.Bits{6}
            _, err = ecs.any_table_add_component(at, a, &six)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.has_flag(&status, a, 6))

            testing.expect(t, ecs.any_table_remove_component(at, a) == nil)
            testing.expect(t, !ecs.has_tag(&status, a))
    }

    @(test)
    flags_table__many_tables__test :: proc(t: ^testing.T) {
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
            status, faction: ecs.Flags_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)
            testing.expect(t, ecs.flags_table_init(&faction, &db, 8) == nil)

            a, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.flag(&status, a, 1) == nil)
            testing.expect(t, ecs.flag(&faction, a, 2) == nil)
            testing.expect(t, ecs.get_flags(&status, a) == ecs.Bits{1})
            testing.expect(t, ecs.get_flags(&faction, a) == ecs.Bits{2})

            testing.expect(t, ecs.clear_flags(&status, a) == nil)
            testing.expect(t, !ecs.has_tag(&status, a))
            testing.expect(t, ecs.has_tag(&faction, a))
    }

    @(test)
    flags_table__destroy_and_recycle__test :: proc(t: ^testing.T) {
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
            status: ecs.Flags_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)

            a, _ := ecs.create_entity(&db)
            testing.expect(t, ecs.flag(&status, a, 9) == nil)
            testing.expect(t, ecs.destroy_entity(&db, a) == nil)
            testing.expect(t, ecs.table_len(&status) == 0)

            b, _ := ecs.create_entity(&db)
            testing.expect(t, b.ix == a.ix)
            testing.expect(t, ecs.get_flags(&status, b) == ecs.Bits{})
            testing.expect(t, !ecs.has_tag(&status, b))
    }

    @(test)
    flags_table__clear_slices_and_any_table__test :: proc(t: ^testing.T) {
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
            status: ecs.Flags_Table
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.set_flags(&status, a, {1, 4}) == nil)
            testing.expect(t, ecs.flag(&status, b, 2) == nil)

            testing.expect(t, len(ecs.slice(&status)) == 2)
            eids := ecs.entities_slice(&status)
            testing.expect(t, slice.contains(eids, a) && slice.contains(eids, b))

            testing.expect(t, ecs.any_table_clone_component(ecs.any_table(&status), a, c) == nil)
            testing.expect(t, ecs.get_flags(&status, c) == ecs.Bits{1, 4})

            buf: [8]ecs.Any_Table
            tables, _ := ecs.entity_tables(&db, a, buf[:])
            testing.expect(t, slice.contains(tables, ecs.any_table(&status)))

            testing.expect(t, ecs.clear(&status) == nil)
            testing.expect(t, ecs.table_len(&status) == 0)
            testing.expect(t, !ecs.has_tag(&status, a))
            testing.expect(t, !ecs.has_tag(&status, c))
            testing.expect(t, ecs.flag(&status, a, 3) == nil)
            testing.expect(t, ecs.table_len(&status) == 1)
    }

    @(test)
    flags_table__terminate_invalidates_views__test :: proc(t: ^testing.T) {
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
            status: ecs.Flags_Table
            view: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {ecs.flags_term(&status, {1})}) == nil)

            testing.expect(t, ecs.flags_table_terminate(&status) == nil)
            testing.expect(t, view.state == ecs.Object_State.Invalid)
    }

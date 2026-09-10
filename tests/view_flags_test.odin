/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Flags view terms: every Flags_Op in includes / excludes / any_of,
    the "has any flag" presence term, and views sourced only from flags.
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
// Flags view terms

    Vf_Pos :: struct {
        x, y: f32,
    }

    view_flags__lens :: proc(views: []^ecs.View) -> (res: [8]int) {
        for v, i in views do res[i] = ecs.view_len(v)
        return
    }

    @(test)
    view_flags__and_includes__test :: proc(t: ^testing.T) {
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
            positions: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            view: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions, ecs.flags_term(&status, {1, 2})}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.add_component(&positions, b)
            testing.expect(t, ecs.view_len(&view) == 0)

            ecs.flag(&status, a, 1)
            testing.expect(t, ecs.view_len(&view) == 0)
            ecs.flag(&status, a, 2)
            testing.expect(t, ecs.view_len(&view) == 1)
            ecs.flag(&status, a, 7)
            testing.expect(t, ecs.view_len(&view) == 1)
            ecs.unflag(&status, a, 1)
            testing.expect(t, ecs.view_len(&view) == 0)

            ecs.set_flags(&status, b, {1, 2, 3})
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, slice.contains(ecs.entities_slice(&view), b))
    }

    @(test)
    view_flags__every_op__test :: proc(t: ^testing.T) {
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
            positions: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            v_or, v_xor, v_exact, v_none, v_nor, v_nand: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)

            testing.expect(t, ecs.view_init(&v_or,    &db, {&positions, ecs.flags_term(&status, {1, 2}, .Or)}) == nil)
            testing.expect(t, ecs.view_init(&v_xor,   &db, {&positions, ecs.flags_term(&status, {1, 2}, .Xor)}) == nil)
            testing.expect(t, ecs.view_init(&v_exact, &db, {&positions, ecs.flags_term(&status, {1, 2}, .Exact)}) == nil)
            testing.expect(t, ecs.view_init(&v_none,  &db, {&positions, ecs.flags_term(&status, {}, .Exact)}) == nil)
            testing.expect(t, ecs.view_init(&v_nor,   &db, {&positions, ecs.flags_term(&status, {1}, .Nor)}) == nil)
            testing.expect(t, ecs.view_init(&v_nand,  &db, {&positions, ecs.flags_term(&status, {1, 2}, .Nand)}) == nil)

            views := []^ecs.View{&v_or, &v_xor, &v_exact, &v_none, &v_nor, &v_nand}

            a, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            testing.expect(t, view_flags__lens(views) == [8]int{0, 0, 0, 1, 1, 1, 0, 0})

            ecs.flag(&status, a, 1)
            testing.expect(t, view_flags__lens(views) == [8]int{1, 1, 0, 0, 0, 1, 0, 0})

            ecs.flag(&status, a, 2)
            testing.expect(t, view_flags__lens(views) == [8]int{1, 0, 1, 0, 0, 0, 0, 0})

            ecs.flag(&status, a, 3)
            testing.expect(t, view_flags__lens(views) == [8]int{1, 0, 0, 0, 0, 0, 0, 0})

            ecs.clear_flags(&status, a)
            testing.expect(t, view_flags__lens(views) == [8]int{0, 0, 0, 1, 1, 1, 0, 0})
    }

    @(test)
    view_flags__excludes__test :: proc(t: ^testing.T) {
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
            positions: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            view: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions}, excludes = {ecs.flags_term(&status, {1})}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.add_component(&positions, b)
            testing.expect(t, ecs.view_len(&view) == 2)

            ecs.flag(&status, a, 1)
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, !slice.contains(ecs.entities_slice(&view), a))

            ecs.flag(&status, a, 4)
            testing.expect(t, ecs.view_len(&view) == 1)

            ecs.unflag(&status, a, 1)
            testing.expect(t, ecs.view_len(&view) == 2)
    }

    @(test)
    view_flags__any_of__test :: proc(t: ^testing.T) {
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
            positions: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            boss: ecs.Tag_Table
            v_mixed, v_nor: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)
            testing.expect(t, ecs.tag_table_init(&boss, &db, 16) == nil)

            testing.expect(t, ecs.view_init(&v_mixed, &db, {&positions}, any_of = {ecs.flags_term(&status, {1}), &boss}) == nil)
            testing.expect(t, ecs.view_init(&v_nor, &db, {&positions}, any_of = {ecs.flags_term(&status, {1}), ecs.flags_term(&status, {2}, .Nor)}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            d, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.add_component(&positions, b)
            ecs.add_component(&positions, c)
            ecs.add_component(&positions, d)

            ecs.flag(&status, a, 1)
            ecs.add_tag(&boss, b)
            ecs.flag(&status, d, 2)

            testing.expect(t, ecs.view_len(&v_mixed) == 2)
            testing.expect(t, slice.contains(ecs.entities_slice(&v_mixed), a))
            testing.expect(t, slice.contains(ecs.entities_slice(&v_mixed), b))

            testing.expect(t, ecs.view_len(&v_nor) == 3)
            testing.expect(t, !slice.contains(ecs.entities_slice(&v_nor), d))
    }

    @(test)
    view_flags__presence_term__test :: proc(t: ^testing.T) {
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
            positions: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            view: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions, &status}) == nil)

            a, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            testing.expect(t, ecs.view_len(&view) == 0)

            ecs.flag(&status, a, 5)
            testing.expect(t, ecs.view_len(&view) == 1)

            cols := ecs.slice(&view, ecs.Bits)
            testing.expect(t, len(cols) == 1 && cols[0]^ == ecs.Bits{5})

            ecs.unflag(&status, a, 5)
            testing.expect(t, ecs.view_len(&view) == 0)
    }

    @(test)
    view_flags__flags_only_view__test :: proc(t: ^testing.T) {
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

            x, _ := ecs.create_entity(&db)
            ecs.flag(&status, x, 1)

            testing.expect(t, ecs.view_init(&view, &db, {ecs.flags_term(&status, {1})}) == nil)
            testing.expect(t, ecs.view_cap(&view) == 8)
            testing.expect(t, ecs.rebuild(&view) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)

            y, _ := ecs.create_entity(&db)
            ecs.flag(&status, y, 1)
            testing.expect(t, ecs.view_len(&view) == 2)

            ecs.unflag(&status, x, 1)
            testing.expect(t, ecs.view_len(&view) == 1)

            testing.expect(t, ecs.destroy_entity(&db, y) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)
    }

    @(test)
    view_flags__errors__test :: proc(t: ^testing.T) {
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
            positions: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            v1, v2, v3, v4, v5: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)

            testing.expect(t, ecs.view_init(&v1, &db, {&positions, ecs.flags_term(&status, {})}) == ecs.API_Error.Flags_Bits_Cannot_Be_Empty)
            testing.expect(t, ecs.view_init(&v2, &db, {&positions}, excludes = {ecs.flags_term(&status, {}, .Or)}) == ecs.API_Error.Flags_Bits_Cannot_Be_Empty)
            testing.expect(t, ecs.view_init(&v3, &db, {ecs.flags_term(&status, {1}, .Nor)}) == ecs.API_Error.View_Includes_Need_A_Table)
            testing.expect(t, ecs.view_init(&v4, &db, {ecs.flags_term(&status, {}, .Exact)}) == ecs.API_Error.View_Includes_Need_A_Table)
            testing.expect(t, ecs.view_init(&v5, &db, {&positions, ecs.flags_term(&status, {}, .Exact)}) == nil)
    }

    @(test)
    view_flags__subscriptions__test :: proc(t: ^testing.T) {
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
            positions: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            v1, v2: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)

            testing.expect(t, ecs.view_init(&v1, &db, {&positions, ecs.flags_term(&status, {1})}, excludes = {ecs.flags_term(&status, {2})}) == nil)
            testing.expect(t, len(status.flags_subscribers.items) == 1)

            testing.expect(t, ecs.view_init(&v2, &db, {ecs.flags_term(&status, {3})}) == nil)
            testing.expect(t, len(status.flags_subscribers.items) == 2)

            testing.expect(t, ecs.view_terminate(&v2) == nil)
            testing.expect(t, len(status.flags_subscribers.items) == 1)

            a, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.flag(&status, a, 1)
            testing.expect(t, ecs.view_len(&v1) == 1)
            ecs.flag(&status, a, 2)
            testing.expect(t, ecs.view_len(&v1) == 0)
            ecs.flag(&status, a, 3)
    }

    @(test)
    view_flags__suspended_goes_stale__test :: proc(t: ^testing.T) {
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
            when ecs.VALIDATIONS {
                db: ecs.Database
                positions: ecs.Table(Vf_Pos)
                status: ecs.Flags_Table
                view: ecs.View
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
                testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
                testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)
                testing.expect(t, ecs.view_init(&view, &db, {&positions, ecs.flags_term(&status, {1})}) == nil)

                a, _ := ecs.create_entity(&db)
                ecs.add_component(&positions, a)
                ecs.set_flags(&status, a, {1, 2})
                testing.expect(t, ecs.view_len(&view) == 1)

                ecs.suspend(&view)
                ecs.unflag(&status, a, 1)
                testing.expect(t, view.stale)
            }
    }

    @(test)
    view_flags__notify_only_changed_bits__test :: proc(t: ^testing.T) {
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
            positions: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            on_a, exact_a, a_not_b: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 16) == nil)
            testing.expect(t, ecs.view_init(&on_a, &db, {&positions, ecs.flags_term(&status, {1})}) == nil)
            testing.expect(t, ecs.view_init(&exact_a, &db, {&positions, ecs.flags_term(&status, {1}, .Exact)}) == nil)
            testing.expect(t, ecs.view_init(&a_not_b, &db, {&positions, ecs.flags_term(&status, {1})}, excludes = {ecs.flags_term(&status, {2})}) == nil)
            testing.expect(t, status.flags_mask == ~ecs.Bits{})

            e, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, e)

            testing.expect(t, ecs.flag(&status, e, 1) == nil)
            testing.expect(t, ecs.view_len(&on_a) == 1 && ecs.view_len(&exact_a) == 1 && ecs.view_len(&a_not_b) == 1)

            // unrelated bit: only the Exact view reacts
            testing.expect(t, ecs.flag(&status, e, 3) == nil)
            testing.expect(t, ecs.view_len(&on_a) == 1 && ecs.view_len(&exact_a) == 0 && ecs.view_len(&a_not_b) == 1)

            // bit 2 is in a_not_b's merged mask through its excludes term
            testing.expect(t, ecs.flag(&status, e, 2) == nil)
            testing.expect(t, ecs.view_len(&on_a) == 1 && ecs.view_len(&a_not_b) == 0)
            testing.expect(t, ecs.unflag(&status, e, 2) == nil)
            testing.expect(t, ecs.view_len(&a_not_b) == 1)

            testing.expect(t, ecs.unflag(&status, e, 3) == nil)
            testing.expect(t, ecs.view_len(&exact_a) == 1)

            ecs.view_terminate(&exact_a)
            testing.expect(t, status.flags_mask == ecs.Bits{1, 2})
            testing.expect(t, len(status.flags_subscribers.items) == 2)
            ecs.view_terminate(&a_not_b)
            testing.expect(t, status.flags_mask == ecs.Bits{1})
            testing.expect(t, len(status.flags_subscribers.items) == 1)

            when ecs.VALIDATIONS {
                ecs.suspend(&on_a)
                testing.expect(t, ecs.flag(&status, e, 5) == nil)
                testing.expect(t, !on_a.stale)
                testing.expect(t, ecs.unflag(&status, e, 1) == nil)
                testing.expect(t, on_a.stale)
            }
    }

    @(test)
    view_flags__rebuild_from_flags_rows__test :: proc(t: ^testing.T) {
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
            positions, small: ecs.Table(Vf_Pos)
            status: ecs.Flags_Table
            from_flags, from_small: ecs.View
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 32, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 32) == nil)
            testing.expect(t, ecs.table_init(&small, &db, 32) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 32) == nil)

            // e[0..9] have flags and positions, 4 more entities only positions; e[0..3] also in small
            e: [14]ecs.entity_id
            for i in 0..<14 {
                e[i], _ = ecs.create_entity(&db)
                ecs.add_component(&positions, e[i])
                if i < 4 do ecs.add_component(&small, e[i])
                if i < 10 {
                    bits := ecs.Bits{0}
                    if i % 2 == 0 do bits += {1}
                    if i % 3 == 0 do bits += {2}
                    testing.expect(t, ecs.set_flags(&status, e[i], bits) == nil)
                }
            }

            // status (10 rows) is the smallest source: has 1, lacks 2 -> e2, e4, e8
            testing.expect(t, ecs.view_init(&from_flags, &db, {&positions, ecs.flags_term(&status, {1})}, excludes = {ecs.flags_term(&status, {2})}) == nil)
            testing.expect(t, ecs.rebuild(&from_flags) == nil)
            testing.expect(t, ecs.view_len(&from_flags) == 3)
            for eid in ecs.entities_slice(&from_flags) do testing.expect(t, eid == e[2] || eid == e[4] || eid == e[8])

            // small (4 rows) is the source: has 1 -> e0, e2
            testing.expect(t, ecs.view_init(&from_small, &db, {&small, ecs.flags_term(&status, {1})}) == nil)
            testing.expect(t, ecs.rebuild(&from_small) == nil)
            testing.expect(t, ecs.view_len(&from_small) == 2)

            // a hole in the source keeps rows and entity ids aligned
            testing.expect(t, ecs.pause_packing(&status) == nil)
            testing.expect(t, ecs.clear_flags(&status, e[2]) == nil)
            testing.expect(t, status.holes_count == 1)
            testing.expect(t, ecs.rebuild(&from_flags) == nil)
            testing.expect(t, ecs.view_len(&from_flags) == 2)
            for eid in ecs.entities_slice(&from_flags) do testing.expect(t, eid == e[4] || eid == e[8])
            testing.expect(t, ecs.resume_packing(&status) == nil)
            testing.expect(t, ecs.rebuild(&from_flags) == nil)
            testing.expect(t, ecs.view_len(&from_flags) == 2)

            // refilter walks the same source with the same shortcut
            allow_filter :: proc(row: ^ecs.View_Row, user_data: rawptr) -> bool { return (cast(^bool) user_data)^ }
            allow := false
            filtered: ecs.View
            filtered.user_data = &allow
            testing.expect(t, ecs.view_init(&filtered, &db, {&positions, ecs.flags_term(&status, {1})}, filter = allow_filter, excludes = {ecs.flags_term(&status, {2})}) == nil)
            testing.expect(t, ecs.rebuild(&filtered) == nil)
            testing.expect(t, ecs.view_len(&filtered) == 0)
            allow = true
            testing.expect(t, ecs.refilter(&filtered) == nil)
            testing.expect(t, ecs.view_len(&filtered) == 2)
            for eid in ecs.entities_slice(&filtered) do testing.expect(t, eid == e[4] || eid == e[8])
    }

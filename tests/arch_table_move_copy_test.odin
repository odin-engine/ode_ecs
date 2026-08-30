/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Arch_Table's move/sudo_move, copy/sudo_copy, and is_in.
*/
package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Arch_Table: is_in

    @(test)
    arch_table__is_in__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&at)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.is_in(&at, eid))

        testing.expect(t, ecs.arch_table__remove_entity(&at, eid) == nil)
        testing.expect(t, !ecs.is_in(&at, eid))

        other, oerr := ecs.create_entity(&db)
        testing.expect(t, oerr == nil)
        testing.expect(t, !ecs.is_in(&at, other))
    }

///////////////////////////////////////////////////////////////////////////////
// Arch_Table: move / sudo_move

    @(test)
    arch_table__move_to_superset__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        from: ecs.Arch_Table
        defer ecs.arch_table__terminate(&from)
        testing.expect(t, ecs.arch_table__init(&from, &db, 10, {Position, AI}) == nil)

        to: ecs.Arch_Table
        defer ecs.arch_table__terminate(&to)
        testing.expect(t, ecs.arch_table__init(&to, &db, 10, {Position, AI, Speed}) == nil)

        eid, err := ecs.create_entity(&from)
        testing.expect(t, err == nil)
        ecs.get_component(&from, eid, Position).x = 11
        ecs.get_component(&from, eid, Position).y = 22
        ecs.get_component(&from, eid, AI).neurons_count = 33

        testing.expect(t, ecs.move(eid, &from, &to) == nil)

        testing.expect(t, !ecs.is_in(&from, eid))
        testing.expect(t, ecs.is_in(&to, eid))
        testing.expect(t, ecs.table_len(&from) == 0)
        testing.expect(t, ecs.table_len(&to) == 1)

        pos := ecs.get_component(&to, eid, Position)
        testing.expect(t, pos.x == 11 && pos.y == 22)
        testing.expect(t, ecs.get_component(&to, eid, AI).neurons_count == 33)
    }

    @(test)
    arch_table__move_entity_not_in_from__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        from: ecs.Arch_Table
        defer ecs.arch_table__terminate(&from)
        testing.expect(t, ecs.arch_table__init(&from, &db, 10, {Position, AI}) == nil)

        // Same schema as `from`, so the column-superset check trivially
        // passes and the entity-membership check is what's exercised.
        to: ecs.Arch_Table
        defer ecs.arch_table__terminate(&to)
        testing.expect(t, ecs.arch_table__init(&to, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.move(eid, &from, &to) == ecs.API_Error.Entity_Not_In_Table)
        testing.expect(t, !ecs.is_in(&to, eid))
    }

    @(test)
    arch_table__sudo_move_drops_missing_columns__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        from: ecs.Arch_Table
        defer ecs.arch_table__terminate(&from)
        testing.expect(t, ecs.arch_table__init(&from, &db, 10, {Position, AI}) == nil)

        lean: ecs.Arch_Table
        defer ecs.arch_table__terminate(&lean)
        testing.expect(t, ecs.arch_table__init(&lean, &db, 10, {Position}) == nil)

        eid, err := ecs.create_entity(&from)
        testing.expect(t, err == nil)
        ecs.get_component(&from, eid, Position).x = 5
        ecs.get_component(&from, eid, AI).neurons_count = 9

        testing.expect(t, ecs.sudo_move(eid, &from, &lean) == nil)

        testing.expect(t, !ecs.is_in(&from, eid))
        testing.expect(t, ecs.is_in(&lean, eid))
        testing.expect(t, ecs.get_component(&lean, eid, Position).x == 5)
    }

///////////////////////////////////////////////////////////////////////////////
// Arch_Table: copy / sudo_copy

    @(test)
    arch_table__copy_to_superset_leaves_source_intact__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        from: ecs.Arch_Table
        defer ecs.arch_table__terminate(&from)
        testing.expect(t, ecs.arch_table__init(&from, &db, 10, {Position, AI}) == nil)

        to: ecs.Arch_Table
        defer ecs.arch_table__terminate(&to)
        testing.expect(t, ecs.arch_table__init(&to, &db, 10, {Position, AI, Speed}) == nil)

        eid, err := ecs.create_entity(&from)
        testing.expect(t, err == nil)
        ecs.get_component(&from, eid, Position).x = 7
        ecs.get_component(&from, eid, AI).neurons_count = 70

        new_eid, cerr := ecs.copy(eid, &from, &to)
        testing.expect(t, cerr == nil)
        testing.expect(t, new_eid != eid)

        testing.expect(t, ecs.is_in(&from, eid))
        testing.expect(t, !ecs.is_in(&from, new_eid))
        testing.expect(t, ecs.is_in(&to, new_eid))
        testing.expect(t, ecs.table_len(&from) == 1)
        testing.expect(t, ecs.table_len(&to) == 1)

        testing.expect(t, ecs.get_component(&from, eid, Position).x == 7)
        testing.expect(t, ecs.get_component(&to, new_eid, Position).x == 7)
        testing.expect(t, ecs.get_component(&to, new_eid, AI).neurons_count == 70)
    }

    @(test)
    arch_table__sudo_copy_drops_missing_columns__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        from: ecs.Arch_Table
        defer ecs.arch_table__terminate(&from)
        testing.expect(t, ecs.arch_table__init(&from, &db, 10, {Position, AI}) == nil)

        lean: ecs.Arch_Table
        defer ecs.arch_table__terminate(&lean)
        testing.expect(t, ecs.arch_table__init(&lean, &db, 10, {Position}) == nil)

        eid, err := ecs.create_entity(&from)
        testing.expect(t, err == nil)
        ecs.get_component(&from, eid, Position).x = 3

        new_eid, cerr := ecs.sudo_copy(eid, &from, &lean)
        testing.expect(t, cerr == nil)

        testing.expect(t, ecs.is_in(&from, eid))
        testing.expect(t, ecs.is_in(&lean, new_eid))
        testing.expect(t, ecs.get_component(&lean, new_eid, Position).x == 3)
    }

///////////////////////////////////////////////////////////////////////////////
// move / copy proc groups also dispatch to the single-component Table(T)
// variants (table__move_component / table__copy_component), not just Arch_Table

    @(test)
    move_copy_groups_dispatch_to_table_component__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        ais: ecs.Table(AI)
        defer ecs.table_terminate(&ais)
        testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)

        ais_2: ecs.Table(AI)
        defer ecs.table_terminate(&ais_2)
        testing.expect(t, ecs.table_init(&ais_2, &db, 10) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        ai, aerr := ecs.add_component(&ais, eid)
        testing.expect(t, aerr == nil)
        ai.neurons_count = 55

        copied, _, cerr := ecs.copy(&ais_2, &ais, eid)
        testing.expect(t, cerr == nil)
        testing.expect(t, copied.neurons_count == 55)
        testing.expect(t, ecs.get_component(&ais, eid) != nil) // copy leaves the source untouched

        eid2, err2 := ecs.create_entity(&db)
        testing.expect(t, err2 == nil)
        ai2, aerr2 := ecs.add_component(&ais, eid2)
        testing.expect(t, aerr2 == nil)
        ai2.neurons_count = 66

        moved, merr := ecs.move(&ais_2, &ais, eid2)
        testing.expect(t, merr == nil)
        testing.expect(t, moved.neurons_count == 66)
        testing.expect(t, ecs.get_component(&ais, eid2) == nil) // move removes it from the source
        testing.expect(t, ecs.get_component(&ais_2, eid2) == moved)
    }

///////////////////////////////////////////////////////////////////////////////
// Arch_Table: command_buffer positional-column fix after sorting columns

    @(test)
    arch_table__command_buffer_arch_add_entity4_columns_by_type__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        C1 :: struct { v: int }
        C2 :: struct { v: int }
        C3 :: struct { v: int }
        C4 :: struct { v: int }

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {C1, C2, C3, C4}) == nil)

        cb: ecs.Command_Buffer
        defer ecs.command_buffer_terminate(&cb)
        testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 16, payload_cap = 512) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.cmd_arch_add_entity(&cb, &at, eid, C1{v = 1}, C2{v = 2}, C3{v = 3}, C4{v = 4}) == nil)

        skipped, rerr := ecs.replay(&cb)
        testing.expect(t, rerr == nil)
        testing.expect(t, skipped == 0)

        testing.expect(t, ecs.get_component(&at, eid, C1).v == 1)
        testing.expect(t, ecs.get_component(&at, eid, C2).v == 2)
        testing.expect(t, ecs.get_component(&at, eid, C3).v == 3)
        testing.expect(t, ecs.get_component(&at, eid, C4).v == 4)
    }

///////////////////////////////////////////////////////////////////////////////
// Arch_Table: entity can be in at most one Arch_Table at a time

    @(test)
    arch_table__add_entity_rejects_second_arch_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        arch1: ecs.Arch_Table
        defer ecs.arch_table__terminate(&arch1)
        testing.expect(t, ecs.arch_table__init(&arch1, &db, 10, {Position, AI}) == nil)

        arch2: ecs.Arch_Table
        defer ecs.arch_table__terminate(&arch2)
        testing.expect(t, ecs.arch_table__init(&arch2, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&arch1)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.add_entity(&arch2, eid) == ecs.API_Error.Entity_Already_In_Table)
        testing.expect(t, ecs.table_len(&arch2) == 0)
        testing.expect(t, ecs.is_in(&arch1, eid))
        testing.expect(t, !ecs.is_in(&arch2, eid))
    }

    @(test)
    arch_table__add_entity_same_table_still_component_already_exist__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Arch_Table
        defer ecs.arch_table__terminate(&at)
        testing.expect(t, ecs.arch_table__init(&at, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&at)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.add_entity(&at, eid) == ecs.API_Error.Component_Already_Exist)
    }

    @(test)
    arch_table__remove_then_add_to_different_arch_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        arch1: ecs.Arch_Table
        defer ecs.arch_table__terminate(&arch1)
        testing.expect(t, ecs.arch_table__init(&arch1, &db, 10, {Position, AI}) == nil)

        arch2: ecs.Arch_Table
        defer ecs.arch_table__terminate(&arch2)
        testing.expect(t, ecs.arch_table__init(&arch2, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&arch1)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.remove_component(&arch1, eid) == nil)
        testing.expect(t, ecs.add_entity(&arch2, eid) == nil)
        testing.expect(t, ecs.is_in(&arch2, eid))
    }

    @(test)
    arch_table__terminate_releases_exclusivity_claim__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        arch1: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&arch1, &db, 10, {Position, AI}) == nil)

        arch2: ecs.Arch_Table
        defer ecs.arch_table__terminate(&arch2)
        testing.expect(t, ecs.arch_table__init(&arch2, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&arch1)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.arch_table__terminate(&arch1) == nil)
        testing.expect(t, ecs.add_entity(&arch2, eid) == nil)
        testing.expect(t, ecs.is_in(&arch2, eid))
    }

    @(test)
    arch_table__deserialize_restores_exclusivity_claim__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        src_db: ecs.Database
        defer ecs.terminate(&src_db)
        testing.expect(t, ecs.init(&src_db, entities_cap = 10, allocator = allocator) == nil)

        src_at: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&src_at, &src_db, 10, {Position, AI}) == nil)

        eid, cerr := ecs.create_entity(&src_at)
        testing.expect(t, cerr == nil)

        size, serr := ecs.serialized_size(&src_db)
        testing.expect(t, serr == nil)
        buf := make([]byte, size, allocator)
        defer delete(buf, allocator)
        _, werr := ecs.serialize(&src_db, buf)
        testing.expect(t, werr == nil)

        dst_db: ecs.Database
        defer ecs.terminate(&dst_db)
        testing.expect(t, ecs.init(&dst_db, entities_cap = 10, allocator = allocator) == nil)

        dst_at: ecs.Arch_Table
        testing.expect(t, ecs.arch_table__init(&dst_at, &dst_db, 10, {Position, AI}) == nil)

        testing.expect(t, ecs.deserialize(&dst_db, buf) == nil)

        // A second, unrelated Arch_Table added after the restore — the
        // restored entity must still be rejected from it.
        dst_at2: ecs.Arch_Table
        defer ecs.arch_table__terminate(&dst_at2)
        testing.expect(t, ecs.arch_table__init(&dst_at2, &dst_db, 10, {Position}) == nil)

        testing.expect(t, ecs.add_entity(&dst_at2, eid) == ecs.API_Error.Entity_Already_In_Table)
    }

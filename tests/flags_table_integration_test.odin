/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Flags_Table with Command_Buffer, snapshots, Observers and Sync.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Flags_Table integration

    Fi_Flag :: enum u8 {
        A,
        B,
        C,
    }

    @(test)
    flags_table__command_buffer__test :: proc(t: ^testing.T) {
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
            cb: ecs.Command_Buffer
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 16, payload_cap = 64) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.cmd_flag(&cb, &status, a, 3) == nil)
            testing.expect(t, ecs.cmd_flag(&cb, &status, a, Fi_Flag.B) == nil)
            testing.expect(t, ecs.cmd_tag(&cb, &status, b, 7) == nil)
            testing.expect(t, ecs.cmd_flag(&cb, &status, c, 1) == nil)
            testing.expect(t, !ecs.has_flag(&status, a, 3))

            testing.expect(t, ecs.destroy_entity(&db, c) == nil)

            skipped, err := ecs.replay(&cb)
            testing.expect(t, err == nil)
            testing.expect(t, skipped == 1)
            testing.expect(t, ecs.get_flags(&status, a) == ecs.Bits{1, 3})
            testing.expect(t, ecs.has_flag(&status, b, 7))

            testing.expect(t, ecs.cmd_unflag(&cb, &status, a, 3) == nil)
            testing.expect(t, ecs.cmd_untag(&cb, &status, b, 7) == nil)
            skipped, err = ecs.replay(&cb)
            testing.expect(t, err == nil && skipped == 0)
            testing.expect(t, ecs.get_flags(&status, a) == ecs.Bits{1})
            testing.expect(t, !ecs.has_tag(&status, b))
    }

    @(test)
    flags_table__serialization_round_trip__test :: proc(t: ^testing.T) {
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
            status, status2: ecs.Flags_Table
            view2: ecs.View
            defer ecs.terminate(&db)
            defer ecs.terminate(&db2)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.init(&db2, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)
            testing.expect(t, ecs.flags_table_init(&status2, &db2, 8) == nil)
            testing.expect(t, ecs.view_init(&view2, &db2, {ecs.flags_term(&status2, {1})}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            testing.expect(t, ecs.set_flags(&status, a, {1, 5}) == nil)
            testing.expect(t, ecs.set_flags(&status, b, {9}) == nil)

            size, serr := ecs.serialized_size(&db)
            testing.expect(t, serr == nil)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)

            written, werr := ecs.serialize(&db, buf)
            testing.expect(t, werr == nil)
            testing.expect(t, ecs.deserialize(&db2, buf[:written]) == nil)

            testing.expect(t, ecs.get_flags(&status2, a) == ecs.Bits{1, 5})
            testing.expect(t, ecs.get_flags(&status2, b) == ecs.Bits{9})
            testing.expect(t, ecs.view_len(&view2) == 1)

            testing.expect(t, ecs.unflag(&status2, a, 1) == nil)
            testing.expect(t, ecs.view_len(&view2) == 0)
    }

when ecs.OBSERVERS_ENABLED {

    Fi_Observed :: struct {
        count: int,
        old:   ecs.Bits,
        new:   ecs.Bits,
    }

    @(test)
    flags_table__observer__test :: proc(t: ^testing.T) {
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
            obs: ecs.Observer
            seen: Fi_Observed
            defer ecs.terminate(&db)

            on_flags :: proc(ev: ^ecs.Observer_Event, user_data: rawptr) {
                s := cast(^Fi_Observed) user_data
                change := cast(^ecs.Flags_Change) ev.data
                s.count += 1
                s.old = change.old
                s.new = change.new
            }

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)
            testing.expect(t, ecs.observer_init(&obs, &db, on_flags, interested_in = {.Flags_Changed}, user_data = &seen) == nil)

            a, _ := ecs.create_entity(&db)

            testing.expect(t, ecs.flag(&status, a, 1) == nil)
            testing.expect(t, seen.count == 1 && seen.old == ecs.Bits{} && seen.new == ecs.Bits{1})

            testing.expect(t, ecs.flag(&status, a, 1) == nil)
            testing.expect(t, seen.count == 1)

            testing.expect(t, ecs.flag(&status, a, 2) == nil)
            testing.expect(t, seen.count == 2 && seen.old == ecs.Bits{1} && seen.new == ecs.Bits{1, 2})

            testing.expect(t, ecs.destroy_entity(&db, a) == nil)
            testing.expect(t, seen.count == 3 && seen.new == ecs.Bits{})
    }
}

when ecs.SYNC_ENABLED {

    @(test)
    flags_table__sync_round_trip__test :: proc(t: ^testing.T) {
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
            status, status2: ecs.Flags_Table
            ch: ecs.Sync_Channel
            dec: ecs.Sync_Decoder
            view2: ecs.View
            defer ecs.terminate(&db)
            defer ecs.terminate(&db2)
            defer ecs.sync_channel_terminate(&ch)
            defer ecs.sync_decoder_terminate(&dec)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.init(&db2, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.flags_table_init(&status, &db, 8) == nil)
            testing.expect(t, ecs.flags_table_init(&status2, &db2, 8) == nil)
            testing.expect(t, ecs.view_init(&view2, &db2, {ecs.flags_term(&status2, {3})}) == nil)

            testing.expect(t, ecs.sync_channel_init(&ch, &db, 4) == nil)
            testing.expect(t, ecs.sync_decoder_init(&dec, &db2, 4) == nil)
            testing.expect(t, ecs.sync_register(&ch, &status) == nil)
            testing.expect(t, ecs.sync_register(&dec, &status2) == nil)

            a, _ := ecs.create_entity(&db)
            a2, _ := ecs.create_entity(&db2)
            testing.expect(t, a == a2)

            buf := make([]byte, 1024, allocator)
            defer delete(buf, allocator)

            testing.expect(t, ecs.flag(&status, a, 3) == nil)
            n, err := ecs.collect_delta(&ch, buf)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.apply_delta(&dec, buf[:n]) == nil)
            testing.expect(t, ecs.get_flags(&status2, a2) == ecs.Bits{3})
            testing.expect(t, ecs.view_len(&view2) == 1)

            testing.expect(t, ecs.flag(&status, a, 4) == nil)
            n, err = ecs.collect_delta(&ch, buf)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.apply_delta(&dec, buf[:n]) == nil)
            testing.expect(t, ecs.get_flags(&status2, a2) == ecs.Bits{3, 4})

            testing.expect(t, ecs.clear_flags(&status, a) == nil)
            n, err = ecs.collect_delta(&ch, buf)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.apply_delta(&dec, buf[:n]) == nil)
            testing.expect(t, !ecs.has_tag(&status2, a2))
            testing.expect(t, ecs.view_len(&view2) == 0)
    }
}

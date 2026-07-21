/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Command_Buffer (command_buffer.odin) — deferred structural
    operations recorded during iteration and replayed at a sync point.
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
// Tests

    @(test)
    cb_record_during_view_iteration__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            ais: ecs.Table(AI)
            view: ecs.View
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 20, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 20) == nil)
            testing.expect(t, ecs.table_init(&ais, &db, 20) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions, &ais}) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 64, payload_cap = 1024) == nil)

            // 6 entities with Position+AI (all in the view)
            eids: [6]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 6; i += 1 {
                eids[i], err = ecs.create_entity(&db)
                testing.expect(t, err == nil)
                pos, perr := ecs.add_component(&positions, eids[i])
                testing.expect(t, perr == nil)
                pos^ = Position{ x = i, y = 0 }
                _, aerr := ecs.add_component(&ais, eids[i])
                testing.expect(t, aerr == nil)
            }
            testing.expect(t, ecs.view_len(&view) == 6)

            // Iterate the view; record structural changes; nothing may move mid-loop
            spawned: ecs.entity_id
            it: ecs.Iterator
            testing.expect(t, ecs.iterator_init(&it, &view) == nil)
            visited := 0
            for ecs.iterator_next(&it) {
                eid := ecs.get_entity(&it)
                pos := ecs.get_component(&positions, &it)

                if pos.x == 1 do testing.expect(t, ecs.cmd_destroy_entity(&cb, eid) == nil)
                if pos.x == 2 do testing.expect(t, ecs.cmd_remove_component(&cb, &ais, eid) == nil)
                if pos.x == 3 {
                    // spawn: create_entity is immediate (iteration-safe), components deferred
                    spawned, err = ecs.create_entity(&db)
                    testing.expect(t, err == nil)
                    testing.expect(t, ecs.cmd_add_component(&cb, &positions, spawned, Position{ x = 100, y = 100 }) == nil)
                    testing.expect(t, ecs.cmd_add_component(&cb, &ais, spawned, AI{ IQ = 42, neurons_count = 7 }) == nil)
                }

                visited += 1
                // the database is untouched while recording
                testing.expect(t, ecs.view_len(&view) == 6)
                testing.expect(t, ecs.table_len(&positions) == 6)
            }
            testing.expect(t, visited == 6)
            testing.expect(t, ecs.command_buffer_len(&cb) == 4)

            // Sync point
            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil)
            testing.expect(t, skipped == 0)
            testing.expect(t, ecs.command_buffer_len(&cb) == 0) // cleared after replay

            // destroyed entity gone; ai removed from one; spawn visible now
            testing.expect(t, ecs.is_expired(&db, eids[1]))
            testing.expect(t, !ecs.has_component(&ais, eids[2]))
            testing.expect(t, ecs.has_component(&positions, eids[2]))

            spos := ecs.get_component(&positions, spawned)
            sai := ecs.get_component(&ais, spawned)
            testing.expect(t, spos != nil && spos.x == 100)
            testing.expect(t, sai != nil && sai.IQ == 42 && sai.neurons_count == 7)

            // view: -1 destroyed, -1 lost AI, +1 spawned = 5
            testing.expect(t, ecs.view_len(&view) == 5)
    }

    @(test)
    cb_overflow__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)

            // commands_cap overflow
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 2, payload_cap = 1024) == nil)
            testing.expect(t, ecs.cmd_destroy_entity(&cb, eid) == nil)
            testing.expect(t, ecs.cmd_destroy_entity(&cb, eid) == nil)
            testing.expect(t, ecs.cmd_destroy_entity(&cb, eid) == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs.command_buffer_len(&cb) == 2)
            testing.expect(t, ecs.command_buffer_terminate(&cb) == nil)

            // payload_cap overflow: Position is 16 bytes, arena of 24 fits one, not two
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 24) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{1, 1}) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{2, 2}) == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs.command_buffer_len(&cb) == 1) // failed add recorded nothing
    }

    @(test)
    cb_expired_id_skip__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 256) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)

            // Recorded against a live entity, destroyed before replay (outside the buffer)
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{1, 1}) == nil)
            testing.expect(t, ecs.cmd_remove_component(&cb, &positions, eid) == nil)
            testing.expect(t, ecs.destroy_entity(&db, eid) == nil)

            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil)
            testing.expect(t, skipped == 2)

            // Destroy-then-add within one buffer: later commands on the dead eid skip
            eid2, err2 := ecs.create_entity(&db)
            testing.expect(t, err2 == nil)
            testing.expect(t, ecs.cmd_destroy_entity(&cb, eid2) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid2, Position{5, 5}) == nil)
            testing.expect(t, ecs.cmd_destroy_entity(&cb, eid2) == nil) // idempotent destroy

            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil)
            testing.expect(t, skipped == 2) // the add and the second destroy
            testing.expect(t, ecs.is_expired(&db, eid2))
            testing.expect(t, ecs.table_len(&positions) == 0)
    }

    @(test)
    cb_add_overwrite_and_ordering__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 256) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)

            // Overwrite: component exists with A, deferred add with B wins
            pos, perr := ecs.add_component(&positions, eid)
            testing.expect(t, perr == nil)
            pos^ = Position{ x = 1, y = 1 }

            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{ x = 2, y = 2 }) == nil)
            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            pos = ecs.get_component(&positions, eid)
            testing.expect(t, pos != nil && pos.x == 2 && pos.y == 2)
            testing.expect(t, ecs.table_len(&positions) == 1) // no duplicate row

            // Two adds in one buffer: last write wins
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{3, 3}) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{4, 4}) == nil)
            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            pos = ecs.get_component(&positions, eid)
            testing.expect(t, pos != nil && pos.x == 4)

            // add-then-remove: absent after replay
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{5, 5}) == nil)
            testing.expect(t, ecs.cmd_remove_component(&cb, &positions, eid) == nil)
            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            testing.expect(t, !ecs.has_component(&positions, eid))

            // remove-then-add: present with the recorded value (remove of absent = skip)
            testing.expect(t, ecs.cmd_remove_component(&cb, &positions, eid) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{6, 6}) == nil)
            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil)
            testing.expect(t, skipped == 1) // the remove found nothing
            pos = ecs.get_component(&positions, eid)
            testing.expect(t, pos != nil && pos.x == 6)
    }

    @(test)
    cb_group__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            ais: ecs.Table(AI)
            group: ecs.Group
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.table_init(&ais, &db, 10) == nil)
            testing.expect(t, ecs.group_init(&group, &db, {&positions, &ais}) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 16, payload_cap = 512) == nil)

            // e0 has both (member), e1 has only Position
            e0, _ := ecs.create_entity(&db)
            e1, _ := ecs.create_entity(&db)
            _, err0 := ecs.add_component(&positions, e0)
            testing.expect(t, err0 == nil)
            _, err1 := ecs.add_component(&ais, e0)
            testing.expect(t, err1 == nil)
            p1, err2 := ecs.add_component(&positions, e1)
            testing.expect(t, err2 == nil)
            p1^ = Position{ x = 11, y = 0 }
            testing.expect(t, ecs.group_len(&group) == 1)

            // deferred: complete e1's membership + destroy member e0
            testing.expect(t, ecs.cmd_add_component(&cb, &ais, e1, AI{ IQ = 77, neurons_count = 3 }) == nil)
            testing.expect(t, ecs.cmd_destroy_entity(&cb, e0) == nil)

            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)

            testing.expect(t, ecs.group_len(&group) == 1) // e1 in, e0 gone
            ai_slice := ecs.group_dense_slice(&group, &ais)
            pos_slice := ecs.group_dense_slice(&group, &positions)
            testing.expect(t, len(ai_slice) == 1 && len(pos_slice) == 1)
            // the recorded value survived the group's row swap into the prefix
            testing.expect(t, ai_slice[0].IQ == 77 && ai_slice[0].neurons_count == 3)
            testing.expect(t, pos_slice[0].x == 11)
            testing.expect(t, ecs.get_entity(&positions, 0) == e1)
    }

    @(test)
    cb_tags_and_filtered_view__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            is_dead: ecs.Tag_Table
            view: ecs.View // positions, excluding dead
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.tag_table__init(&is_dead, &db, 10) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions}, excludes = {&is_dead}) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 64) == nil)

            e0, _ := ecs.create_entity(&db)
            e1, _ := ecs.create_entity(&db)
            _, err0 := ecs.add_component(&positions, e0)
            testing.expect(t, err0 == nil)
            _, err1 := ecs.add_component(&positions, e1)
            testing.expect(t, err1 == nil)
            testing.expect(t, ecs.view_len(&view) == 2)

            // tag e0 dead (deferred), untag e1 (absent -> skip), tag e0 twice (idempotent)
            testing.expect(t, ecs.cmd_tag(&cb, &is_dead, e0) == nil)
            testing.expect(t, ecs.cmd_untag(&cb, &is_dead, e1) == nil)
            testing.expect(t, ecs.cmd_tag(&cb, &is_dead, e0) == nil)

            testing.expect(t, ecs.view_len(&view) == 2) // untouched while recording

            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil)
            testing.expect(t, skipped == 1) // the untag of an absent tag
            testing.expect(t, ecs.table_len(&is_dead) == 1)
            testing.expect(t, ecs.view_len(&view) == 1) // e0 excluded now

            // untag via buffer brings it back
            testing.expect(t, ecs.cmd_untag(&cb, &is_dead, e0) == nil)
            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            testing.expect(t, ecs.view_len(&view) == 2)
    }

    @(test)
    cb_all_table_variants__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            compact_ais: ecs.Compact_Table(AI)
            tiny_ais: ecs.Tiny_Table(AI)
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 20, allocator = allocator) == nil)
            testing.expect(t, ecs.compact_table__init(&compact_ais, &db, 10) == nil)
            testing.expect(t, ecs.tiny_table__init(&tiny_ais, &db) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 32, payload_cap = 1024) == nil)

            // Compact_Table add/remove through the buffer
            e0, _ := ecs.create_entity(&db)
            testing.expect(t, ecs.cmd_add_component(&cb, &compact_ais, e0, AI{ IQ = 1, neurons_count = 2 }) == nil)
            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            cai := ecs.get_component(&compact_ais, e0)
            testing.expect(t, cai != nil && cai.IQ == 1 && cai.neurons_count == 2)

            testing.expect(t, ecs.cmd_remove_component(&cb, &compact_ais, e0) == nil)
            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            testing.expect(t, !ecs.has_component(&compact_ais, e0))

            // Tiny_Table: fill to its 8-row cap via the buffer, 9th errors from
            // replay but the remaining commands still apply
            eids: [9]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 9; i += 1 {
                eids[i], err = ecs.create_entity(&db)
                testing.expect(t, err == nil)
                testing.expect(t, ecs.cmd_add_component(&cb, &tiny_ais, eids[i], AI{ IQ = f32(i), neurons_count = i }) == nil)
            }
            // one more valid command after the failing one
            testing.expect(t, ecs.cmd_add_component(&cb, &compact_ais, e0, AI{ IQ = 9, neurons_count = 9 }) == nil)

            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == oc.Core_Error.Container_Is_Full) // the 9th tiny add
            testing.expect(t, ecs.table_len(&tiny_ais) == 8)
            testing.expect(t, ecs.has_component(&compact_ais, e0)) // later command still ran

            tai := ecs.get_component(&tiny_ais, eids[3])
            testing.expect(t, tai != nil && tai.neurons_count == 3)
    }

    @(test)
    cb_replay_while_packing_paused__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 256) == nil)

            eids: [3]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 3; i += 1 {
                eids[i], err = ecs.create_entity(&db)
                testing.expect(t, err == nil)
                pos, perr := ecs.add_component(&positions, eids[i])
                testing.expect(t, perr == nil)
                pos^ = Position{ x = i, y = 0 }
            }

            // pointer stability check target: last row must not move while paused
            p2_before := ecs.get_component(&positions, eids[2])

            ecs.pause_packing(&db)

            testing.expect(t, ecs.cmd_remove_component(&cb, &positions, eids[0]) == nil) // leaves a hole
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eids[0], Position{ x = 50, y = 0 }) == nil) // re-add appends at tail

            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)

            // while paused: other components did not move
            testing.expect(t, ecs.get_component(&positions, eids[2]) == p2_before)

            testing.expect(t, ecs.resume_packing(&db) == nil) // packs the hole

            testing.expect(t, ecs.table_len(&positions) == 3)
            pos := ecs.get_component(&positions, eids[0])
            testing.expect(t, pos != nil && pos.x == 50)
    }

    @(test)
    cb_clear_and_reinit__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)

            // clear without replay: nothing applied
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 256) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{1, 1}) == nil)
            testing.expect(t, ecs.clear(&cb) == nil)
            testing.expect(t, ecs.command_buffer_len(&cb) == 0)

            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            testing.expect(t, !ecs.has_component(&positions, eid))

            // issue #8: terminate then re-init the SAME struct without zeroing
            testing.expect(t, ecs.command_buffer_terminate(&cb) == nil)
            testing.expect(t, cb.state == ecs.Object_State.Not_Initialized)

            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 4, payload_cap = 64) == nil)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{2, 2}) == nil)
            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            pos := ecs.get_component(&positions, eid)
            testing.expect(t, pos != nil && pos.x == 2)
    }

    @(test)
    cb_stale_table__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            ais: ecs.Table(AI)
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.table_init(&ais, &db, 10) == nil) // occupies id 1
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 256) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)

            // record against `positions`, then terminate it before replay
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{1, 1}) == nil)
            testing.expect(t, ecs.table_terminate(&positions) == nil)

            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil)
            testing.expect(t, skipped == 1) // terminated table -> command dropped

            // re-init the same struct; it may get its old id back, but the size
            // guard still protects mismatched re-registrations — record + terminate +
            // re-init as usual and confirm a fresh record works
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb, &positions, eid, Position{3, 3}) == nil)
            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            pos := ecs.get_component(&positions, eid)
            testing.expect(t, pos != nil && pos.x == 3)
    }

    @(test)
    cb_relations__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            rt: ecs.Relations_Table
            cb: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 20, allocator = allocator) == nil)
            testing.expect(t, ecs.relations_init(&rt, &db, 10) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 16, payload_cap = 64) == nil)

            parent, err1 := ecs.create_entity(&db)
            testing.expect(t, err1 == nil)
            child, err2 := ecs.create_entity(&db)
            testing.expect(t, err2 == nil)

            //
            // Deferral: recording does not touch the database
            //
            testing.expect(t, ecs.cmd_set_parent(&cb, child, parent) == nil)

            p, perr := ecs.parent_of(&db, child)
            testing.expect(t, perr == nil && p.ix == ecs.DELETED_INDEX) // still unparented

            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)

            p, perr = ecs.parent_of(&db, child)
            testing.expect(t, perr == nil && p == parent) // linked at the sync point

            //
            // Ordering within one buffer: link first, then cascade-destroy the
            // parent — the child must be gone too
            //
            p2, e1 := ecs.create_entity(&db)
            testing.expect(t, e1 == nil)
            c2, e2 := ecs.create_entity(&db)
            testing.expect(t, e2 == nil)

            testing.expect(t, ecs.cmd_set_parent(&cb, c2, p2) == nil)
            testing.expect(t, ecs.cmd_destroy_entity(&cb, p2, destroy_children = true) == nil)

            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil && skipped == 0)
            testing.expect(t, ecs.is_expired(&db, p2))
            testing.expect(t, ecs.is_expired(&db, c2)) // cascade caught the fresh link

            //
            // Expired-parent skip: parent destroyed by an earlier command in
            // the same buffer — the set_parent is dropped harmlessly
            //
            p3, e3 := ecs.create_entity(&db)
            testing.expect(t, e3 == nil)
            c3, e4 := ecs.create_entity(&db)
            testing.expect(t, e4 == nil)

            testing.expect(t, ecs.cmd_destroy_entity(&cb, p3) == nil)
            testing.expect(t, ecs.cmd_set_parent(&cb, c3, p3) == nil)

            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil)
            testing.expect(t, skipped == 1)
            testing.expect(t, !ecs.is_expired(&db, c3)) // child alive and unparented
            p, perr = ecs.parent_of(&db, c3)
            testing.expect(t, perr == nil && p.ix == ecs.DELETED_INDEX)

            //
            // remove_parent: applies once, second one skips (idempotent)
            //
            testing.expect(t, ecs.set_parent(&db, c3, child) == nil) // immediate link

            testing.expect(t, ecs.cmd_remove_parent(&cb, c3) == nil)
            testing.expect(t, ecs.cmd_unparent(&cb, c3) == nil) // alias; no parent by then

            skipped, rerr = ecs.replay(&cb)
            testing.expect(t, rerr == nil)
            testing.expect(t, skipped == 1)
            p, perr = ecs.parent_of(&db, c3)
            testing.expect(t, perr == nil && p.ix == ecs.DELETED_INDEX)
    }

    @(test)
    cb_relations_errors__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            rt: ecs.Relations_Table
            cb: ecs.Command_Buffer

            db2: ecs.Database // no Relations_Table on purpose
            cb2: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.relations_init(&rt, &db, 10) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb, &db, commands_cap = 8, payload_cap = 64) == nil)

            a, e1 := ecs.create_entity(&db)
            testing.expect(t, e1 == nil)
            b, e2 := ecs.create_entity(&db)
            testing.expect(t, e2 == nil)
            c, e3 := ecs.create_entity(&db)
            testing.expect(t, e3 == nil)

            //
            // Cycle detected at replay; later commands still run
            //
            testing.expect(t, ecs.set_parent(&db, b, a) == nil) // immediate: b is a child of a

            testing.expect(t, ecs.cmd_set_parent(&cb, a, b) == nil) // would close a cycle
            testing.expect(t, ecs.cmd_set_parent(&cb, c, a) == nil) // valid, must still apply

            skipped, rerr := ecs.replay(&cb)
            testing.expect(t, rerr == ecs.API_Error.Relation_Cycle)
            testing.expect(t, skipped == 0)

            p, perr := ecs.parent_of(&db, a)
            testing.expect(t, perr == nil && p.ix == ecs.DELETED_INDEX) // cycle rejected
            p, perr = ecs.parent_of(&db, c)
            testing.expect(t, perr == nil && p == a) // command after the error applied

            //
            // No Relations_Table: the error surfaces at replay, buffer still clears
            //
            defer ecs.terminate(&db2)
            defer ecs.command_buffer_terminate(&cb2)

            testing.expect(t, ecs.init(&db2, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb2, &db2, commands_cap = 8, payload_cap = 64) == nil)

            x, e4 := ecs.create_entity(&db2)
            testing.expect(t, e4 == nil)
            y, e5 := ecs.create_entity(&db2)
            testing.expect(t, e5 == nil)

            testing.expect(t, ecs.cmd_set_parent(&cb2, x, y) == nil)
            testing.expect(t, ecs.cmd_remove_parent(&cb2, x) == nil)

            skipped, rerr = ecs.replay(&cb2)
            testing.expect(t, rerr == ecs.API_Error.Relations_Table_Not_Created)
            testing.expect(t, ecs.command_buffer_len(&cb2) == 0) // cleared despite the error
    }

    // Cross-buffer ordering on ONE database: two independently-recorded
    // buffers against the same db, where the second buffer's command depends
    // on the first's effect. The doc comment (command_buffer.odin) promises
    // "cross-buffer ordering is the order you replay them in" — verify both
    // directions actually behave that way.
    @(test)
    cb_cross_buffer_ordering__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table(Position)
            cb_a, cb_b: ecs.Command_Buffer

        //
        // Test
        //
            defer ecs.terminate(&db)
            defer ecs.command_buffer_terminate(&cb_a)
            defer ecs.command_buffer_terminate(&cb_b)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 10) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb_a, &db, commands_cap = 8, payload_cap = 256) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb_b, &db, commands_cap = 8, payload_cap = 256) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)

            // Recorded independently: A destroys eid, B (unaware of A) adds a
            // component to the same still-alive-at-record-time eid.
            testing.expect(t, ecs.cmd_destroy_entity(&cb_a, eid) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb_b, &positions, eid, Position{9, 9}) == nil)

            // Replay A then B: B's add must be skipped (eid already expired).
            skipped_a, rerr_a := ecs.replay(&cb_a)
            testing.expect(t, rerr_a == nil)
            testing.expect(t, skipped_a == 0)
            testing.expect(t, ecs.is_expired(&db, eid))

            skipped_b, rerr_b := ecs.replay(&cb_b)
            testing.expect(t, rerr_b == nil)
            testing.expect(t, skipped_b == 1)
            testing.expect(t, ecs.table_len(&positions) == 0)

        //
        // Same setup, reversed replay order: B then A — B's add must now
        // succeed (eid still alive at that point), proving the outcome is
        // governed purely by replay order, not recording order.
        //
            db2: ecs.Database
            positions2: ecs.Table(Position)
            cb_a2, cb_b2: ecs.Command_Buffer
            defer ecs.terminate(&db2)
            defer ecs.command_buffer_terminate(&cb_a2)
            defer ecs.command_buffer_terminate(&cb_b2)

            testing.expect(t, ecs.init(&db2, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions2, &db2, 10) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb_a2, &db2, commands_cap = 8, payload_cap = 256) == nil)
            testing.expect(t, ecs.command_buffer_init(&cb_b2, &db2, commands_cap = 8, payload_cap = 256) == nil)

            eid2, err2 := ecs.create_entity(&db2)
            testing.expect(t, err2 == nil)

            testing.expect(t, ecs.cmd_destroy_entity(&cb_a2, eid2) == nil)
            testing.expect(t, ecs.cmd_add_component(&cb_b2, &positions2, eid2, Position{9, 9}) == nil)

            skipped_b2, rerr_b2 := ecs.replay(&cb_b2)
            testing.expect(t, rerr_b2 == nil)
            testing.expect(t, skipped_b2 == 0) // eid2 still alive: add succeeds
            testing.expect(t, ecs.table_len(&positions2) == 1)

            skipped_a2, rerr_a2 := ecs.replay(&cb_a2)
            testing.expect(t, rerr_a2 == nil)
            testing.expect(t, skipped_a2 == 0)
            testing.expect(t, ecs.is_expired(&db2, eid2))
            testing.expect(t, ecs.table_len(&positions2) == 0) // destroy also removed the component
    }

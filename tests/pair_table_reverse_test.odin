/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Pair_Table(T) reverse (target-side) queries, the row cursor and
    per-row payload access. See pair_table.odin.
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
// Row cursor

    @(test)
    pair_table__row_cursor_both_directions__test :: proc(t: ^testing.T) {
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
            testing.expect(t, ecs.init(&db, entities_cap=16, allocator=allocator) == nil)

            likes: ecs.Pair_Table(Likes_Data)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap=8, pairs_cap=16) == nil)

            alice, _ := ecs.create_entity(&db)
            bob,   _ := ecs.create_entity(&db)
            carol, _ := ecs.create_entity(&db)
            dave,  _ := ecs.create_entity(&db)

            ecs.pair_add(&likes, alice, bob,   Likes_Data{ strength = 1 })
            ecs.pair_add(&likes, alice, carol, Likes_Data{ strength = 2 })
            ecs.pair_add(&likes, dave,  carol, Likes_Data{ strength = 3 })

            targets: [4]ecs.entity_id
            strengths: [4]int
            n := 0
            for row, ok := ecs.pair_first_row_of(&likes, alice); ok; row, ok = ecs.pair_next_row_of(&likes, row) {
                testing.expect(t, ecs.pair_row_holder(&likes, row) == alice)
                targets[n] = ecs.pair_row_target(&likes, row)
                strengths[n] = ecs.pair_row_data(&likes, row).strength
                n += 1
            }

            testing.expect(t, n == 2)
            testing.expect(t, slice.contains(targets[:n], bob))
            testing.expect(t, slice.contains(targets[:n], carol))
            testing.expect(t, slice.contains(strengths[:n], 1))
            testing.expect(t, slice.contains(strengths[:n], 2))

            holders: [4]ecs.entity_id
            n = 0
            for row, ok := ecs.pair_first_row_to(&likes, carol); ok; row, ok = ecs.pair_next_row_to(&likes, row) {
                testing.expect(t, ecs.pair_row_target(&likes, row) == carol)
                holders[n] = ecs.pair_row_holder(&likes, row)
                n += 1
            }

            testing.expect(t, n == 2)
            testing.expect(t, slice.contains(holders[:n], alice))
            testing.expect(t, slice.contains(holders[:n], dave))

            _, ok_out := ecs.pair_first_row_of(&likes, bob)
            testing.expect(t, !ok_out)

            _, ok_in := ecs.pair_first_row_to(&likes, alice)
            testing.expect(t, !ok_in)
    }

///////////////////////////////////////////////////////////////////////////////
// Reverse and payload queries

    @(test)
    pair_table__holders_of_and_counts__test :: proc(t: ^testing.T) {
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
            testing.expect(t, ecs.init(&db, entities_cap=16, allocator=allocator) == nil)

            likes: ecs.Pair_Table(Likes_Data)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap=8, pairs_cap=16) == nil)

            alice, _ := ecs.create_entity(&db)
            bob,   _ := ecs.create_entity(&db)
            carol, _ := ecs.create_entity(&db)
            dave,  _ := ecs.create_entity(&db)

            ecs.pair_add(&likes, alice, carol, Likes_Data{ strength = 1 })
            ecs.pair_add(&likes, bob,   carol, Likes_Data{ strength = 2 })
            ecs.pair_add(&likes, dave,  carol, Likes_Data{ strength = 3 })
            ecs.pair_add(&likes, alice, bob,   Likes_Data{ strength = 4 })

            holders, herr := ecs.pair_holders_of(&likes, carol)
            testing.expect(t, herr == nil)
            testing.expect(t, len(holders) == 3)
            testing.expect(t, slice.contains(holders, alice))
            testing.expect(t, slice.contains(holders, bob))
            testing.expect(t, slice.contains(holders, dave))

            testing.expect(t, ecs.pair_count_to(&likes, carol) == 3)
            testing.expect(t, ecs.pair_count_to(&likes, bob) == 1)
            testing.expect(t, ecs.pair_count_to(&likes, alice) == 0)
            testing.expect(t, ecs.pair_count_of(&likes, alice) == 2)
            testing.expect(t, ecs.pair_count_of(&likes, carol) == 0)

            // The two scratch buffers are independent — a targets_of call must not
            // clobber a live holders_of result.
            holders2, _ := ecs.pair_holders_of(&likes, carol)
            targets2, _ := ecs.pair_targets_of(&likes, alice)
            testing.expect(t, len(targets2) == 2)
            testing.expect(t, len(holders2) == 3)
            testing.expect(t, slice.contains(holders2, dave))

            d, ok := ecs.pair_get_data(&likes, alice, carol)
            testing.expect(t, ok && d.strength == 1)

            // Non-head row of the same holder.
            d, ok = ecs.pair_get_data(&likes, alice, bob)
            testing.expect(t, ok && d.strength == 4)

            _, ok = ecs.pair_get_data(&likes, alice, dave)
            testing.expect(t, !ok)
    }

    @(test)
    pair_table__remove_all_to__test :: proc(t: ^testing.T) {
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
            testing.expect(t, ecs.init(&db, entities_cap=16, allocator=allocator) == nil)

            likes: ecs.Pair_Table(Likes_Data)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap=8, pairs_cap=16) == nil)

            alice, _ := ecs.create_entity(&db)
            bob,   _ := ecs.create_entity(&db)
            carol, _ := ecs.create_entity(&db)

            // alice keeps a second pair, carol is the only target bob points at.
            ecs.pair_add(&likes, alice, carol, Likes_Data{})
            ecs.pair_add(&likes, alice, bob,   Likes_Data{})
            ecs.pair_add(&likes, bob,   carol, Likes_Data{})

            testing.expect(t, ecs.pair_len(&likes) == 3)
            testing.expect(t, ecs.pair_remove_all_to(&likes, carol) == nil)

            testing.expect(t, ecs.pair_len(&likes) == 1)
            testing.expect(t, ecs.pair_count_to(&likes, carol) == 0)
            testing.expect(t, !ecs.pair_has_pair(&likes, alice, carol))
            testing.expect(t, !ecs.pair_has_pair(&likes, bob, carol))
            testing.expect(t, ecs.pair_has_pair(&likes, alice, bob))

            testing.expect(t, ecs.pair_has_any(&likes, alice))
            testing.expect(t, !ecs.pair_has_any(&likes, bob))
    }

    @(test)
    pair_table__reverse_matches_brute_force__test :: proc(t: ^testing.T) {
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
            testing.expect(t, ecs.init(&db, entities_cap=32, allocator=allocator) == nil)

            likes: ecs.Pair_Table(Likes_Data)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap=16, pairs_cap=128) == nil)

            eids: [12]ecs.entity_id
            for i in 0..<len(eids) do eids[i], _ = ecs.create_entity(&db)

            for h in 0..<len(eids) {
                for tg in 0..<len(eids) {
                    if h != tg && (h * 7 + tg * 3) % 5 == 0 {
                        ecs.pair_add(&likes, eids[h], eids[tg], Likes_Data{ strength = h * 100 + tg })
                    }
                }
            }

            for tg in 0..<len(eids) {
                expected := 0
                for h in 0..<len(eids) {
                    if ecs.pair_has_pair(&likes, eids[h], eids[tg]) do expected += 1
                }

                testing.expect(t, ecs.pair_count_to(&likes, eids[tg]) == expected)

                holders, herr := ecs.pair_holders_of(&likes, eids[tg])
                testing.expect(t, herr == nil)
                testing.expect(t, len(holders) == expected)
                for h in holders {
                    testing.expect(t, ecs.pair_has_pair(&likes, h, eids[tg]))
                }
            }

            // Every stored payload is reachable by (holder, target) and by row cursor.
            for h in 0..<len(eids) {
                cursor_rows := 0
                for row, ok := ecs.pair_first_row_of(&likes, eids[h]); ok; row, ok = ecs.pair_next_row_of(&likes, row) {
                    cursor_rows += 1
                }
                testing.expect(t, cursor_rows == ecs.pair_count_of(&likes, eids[h]))

                for tg in 0..<len(eids) {
                    d, ok := ecs.pair_get_data(&likes, eids[h], eids[tg])
                    if h != tg && (h * 7 + tg * 3) % 5 == 0 {
                        testing.expect(t, ok && d.strength == h * 100 + tg)
                    } else {
                        testing.expect(t, !ok)
                    }
                }
            }
    }

    @(test)
    pair_table__destroy_target_clears_reverse_index__test :: proc(t: ^testing.T) {
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
            testing.expect(t, ecs.init(&db, entities_cap=16, allocator=allocator) == nil)

            likes: ecs.Pair_Table(Likes_Data)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap=8, pairs_cap=16) == nil)

            alice, _ := ecs.create_entity(&db)
            bob,   _ := ecs.create_entity(&db)
            carol, _ := ecs.create_entity(&db)

            ecs.pair_add(&likes, alice, carol, Likes_Data{})
            ecs.pair_add(&likes, bob,   carol, Likes_Data{})
            ecs.pair_add(&likes, alice, bob,   Likes_Data{})

            testing.expect(t, ecs.pair_count_to(&likes, carol) == 2)

            ecs.destroy_entity(&db, carol)

            testing.expect(t, ecs.pair_count_to(&likes, carol) == 0)
            testing.expect(t, ecs.pair_count_of(&likes, alice) == 1)
            testing.expect(t, ecs.pair_count_of(&likes, bob) == 0)
            testing.expect(t, !ecs.pair_has_any(&likes, bob))

            _, ok := ecs.pair_first_row_to(&likes, carol)
            testing.expect(t, !ok)
    }

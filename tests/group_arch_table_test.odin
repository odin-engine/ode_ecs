/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for Group ownership of Arch_Table: a Group can own a mix of
    Table($T) and Arch_Table — the same aligned-prefix invariant holds
    across both, maintained via arch_table__swap_rows (one call moves every
    owned column of an Arch_Table row).
*/

package ode_ecs__tests

// Core
    import "core:testing"

// ODE
    import ecs "../src"

    Group_Speed :: struct { value: f64 }

    @(test)
    group__owns_arch_table_only__test :: proc(t: ^testing.T) {
        db: ecs.Database
        at: ecs.Arch_Table
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.arch_table__init(&at, &db, 100, {Position, AI}) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&at}) == nil)
        testing.expect(t, ecs.is_valid(&group))
        testing.expect(t, ecs.group_len(&group) == 0)

        // owner is inert until it's a group member — verify the ownership
        // link itself and that direct pause_packing on the table is rejected
        testing.expect(t, ecs.pause_packing(&at) == ecs.API_Error.Cannot_Pause_Table_Owned_By_Group)

        eids: [6]ecs.entity_id
        for i in 0 ..< 6 {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            eids[i] = eid
        }

        // only even-indexed entities join the archetype
        for i in 0 ..< 6 {
            if i % 2 == 0 {
                testing.expect(t, ecs.arch_table__add_entity(&at, eids[i]) == nil)
                ecs.get_component(&at, eids[i], Position).x = i
            }
        }
        testing.expect(t, ecs.group_len(&group) == 3)

        ps := ecs.slice(&group, &at, Position)
        testing.expect(t, len(ps) == 3)
        for i in 0 ..< 3 {
            row_eid := ecs.get_entity(&at, i)
            testing.expect(t, ecs.get_component(&at, row_eid, Position) == &ps[i])
        }

        // removing from the archetype removes the entity from the group
        testing.expect(t, ecs.arch_table__remove_entity(&at, eids[0]) == nil)
        testing.expect(t, ecs.group_len(&group) == 2)

        // re-adding brings it back
        testing.expect(t, ecs.arch_table__add_entity(&at, eids[0]) == nil)
        testing.expect(t, ecs.group_len(&group) == 3)
    }

    @(test)
    group__owns_table_and_arch_table_mixed__test :: proc(t: ^testing.T) {
        db: ecs.Database
        speeds: ecs.Table(Group_Speed)
        at: ecs.Arch_Table
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.table_init(&speeds, &db, 100) == nil)
        testing.expect(t, ecs.arch_table__init(&at, &db, 100, {Position, AI}) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&speeds, &at}) == nil)

        eids: [8]ecs.entity_id
        for i in 0 ..< 8 {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            eids[i] = eid
        }

        // Speed: entities 0..5; archetype row: entities 3..7 -> intersection {3,4,5}
        for i in 0 ..< 6 {
            spd, err := ecs.add_component(&speeds, eids[i])
            testing.expect(t, err == nil)
            spd.value = f64(i)
        }
        for i in 3 ..< 8 {
            testing.expect(t, ecs.arch_table__add_entity(&at, eids[i]) == nil)
            ecs.get_component(&at, eids[i], Position).x = i
            ecs.get_component(&at, eids[i], AI).neurons_count = i * 10
        }

        testing.expect(t, ecs.group_len(&group) == 3)

        for r in 0 ..< ecs.group_len(&group) {
            eid_from_speeds := ecs.get_entity(&speeds, r)
            eid_from_arch := ecs.get_entity(&at, r)
            testing.expect(t, eid_from_speeds == eid_from_arch, "owned Table and Arch_Table must agree on the entity at each prefix row")
        }

        spd_slice := ecs.slice(&group, &speeds)
        pos_slice := ecs.slice(&group, &at, Position)
        ai_slice := ecs.slice(&group, &at, AI)
        testing.expect(t, len(spd_slice) == 3 && len(pos_slice) == 3 && len(ai_slice) == 3)

        // removing the Table-side component drops the entity from the group
        testing.expect(t, ecs.remove_component(&speeds, eids[3]) == nil)
        testing.expect(t, ecs.group_len(&group) == 2)

        // removing the Arch_Table-side row drops it too
        testing.expect(t, ecs.arch_table__remove_entity(&at, eids[4]) == nil)
        testing.expect(t, ecs.group_len(&group) == 1)

        // the survivor (eid 5) must still have correct data after the swaps
        testing.expect(t, ecs.group_len(&group) == 1)
        surv := ecs.get_entity(&speeds, 0)
        testing.expect(t, surv == eids[5])
        testing.expect(t, ecs.get_component(&speeds, surv).value == 5)
        testing.expect(t, ecs.get_component(&at, surv, Position).x == 5)
        testing.expect(t, ecs.get_component(&at, surv, AI).neurons_count == 50)
    }

    @(test)
    group__arch_table_ownership_errors__test :: proc(t: ^testing.T) {
        db: ecs.Database
        at: ecs.Arch_Table
        compact: ecs.Compact_Table(AI)
        group_a: ecs.Group
        group_b: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.arch_table__init(&at, &db, 100, {Position}) == nil)
        testing.expect(t, ecs.compact_table__init(&compact, &db, 100) == nil)

        // Compact_Table still cannot be owned, alongside an Arch_Table
        testing.expect(t, ecs.group_init(&group_a, &db, {&at, &compact}) == ecs.API_Error.Only_Table_Can_Be_Owned_By_Group)

        // first group succeeds owning the Arch_Table alone
        testing.expect(t, ecs.group_init(&group_a, &db, {&at}) == nil)

        // a second group cannot also own it
        testing.expect(t, ecs.group_init(&group_b, &db, {&at}) == ecs.API_Error.Table_Already_Owned_By_Group)
    }

    @(test)
    group__arch_table_pause_resume__test :: proc(t: ^testing.T) {
        db: ecs.Database
        at: ecs.Arch_Table
        group: ecs.Group
        defer ecs.terminate(&db)

        testing.expect(t, ecs.init(&db, 100) == nil)
        testing.expect(t, ecs.arch_table__init(&at, &db, 100, {Position}) == nil)
        testing.expect(t, ecs.group_init(&group, &db, {&at}) == nil)

        eids: [3]ecs.entity_id
        for i in 0 ..< 3 {
            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            eids[i] = eid
            testing.expect(t, ecs.arch_table__add_entity(&at, eid) == nil)
            ecs.get_component(&at, eid, Position).x = i
        }
        testing.expect(t, ecs.group_len(&group) == 3)

        testing.expect(t, ecs.pause_packing(&group) == nil)

        // removing the middle member while the GROUP is paused must defer the
        // swap (mark dirty) instead of moving rows
        testing.expect(t, ecs.arch_table__remove_entity(&at, eids[1]) == nil)
        testing.expect(t, ecs.slice(&group, &at, Position) == nil, "dirty group must report no dense slice")

        testing.expect(t, ecs.resume_packing(&group) == nil)

        testing.expect(t, ecs.group_len(&group) == 2)
        ps := ecs.slice(&group, &at, Position)
        testing.expect(t, len(ps) == 2)
        for i in 0 ..< 2 {
            row_eid := ecs.get_entity(&at, i)
            testing.expect(t, row_eid == eids[0] || row_eid == eids[2])
        }
    }

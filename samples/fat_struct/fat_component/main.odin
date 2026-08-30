/*
    2026 (c) Oleh, https://github.com/zm69

    "Fat component" architecture: same scenario as ../fat/main.odin, but the
    whole monolithic hot-path struct (flags/position/velocity/health) becomes
    ONE ODE_ECS component.

    Demonstrates: ODE_ECS doesn't force fine-grained decomposition — you can
    unite hot-path data into a single fat component and still get entity
    lifecycle, O(1) lookups, and sparse/rare components for free.

    NOTE: errors aren't handled here, to keep the code short.
*/

package ode_ecs_fat_struct_fat_component

// Core
    import "core:fmt"

// ODE_ECS
    import ecs "../../../src"

//
// Components
//

    Entity_Flags :: bit_set[Entity_Flag; u16]
    Entity_Flag  :: enum u16 {
        Active,
        Has_Physics,
    }

    // The fat component: position/velocity/health/flags bundled into ONE
    // ODE_ECS component instead of split into Position/Velocity/Health
    // tables joined by a Group.
    Entity :: struct #align(16) {
        flags:    Entity_Flags,
        position: [3]f32,
        velocity: [3]f32,
        health:   f32,
    }

    // No owner_id — get_entity(&table, index) recovers it.
    Inventory :: struct {
        gold:  u32,
        items: [16]u16,
    }

    // Same reasoning — no owner_id/target_id.
    AI_State :: struct {
        target:      ecs.entity_id,
        aggro_range: f32,
    }

//
// Config
//

    MAX_ENTITIES :: 100

//
// Systems
//

    // Hot loop — a single Table(Entity) walk. 
    update_physics :: proc(entities: ^ecs.Table(Entity), dt: f32) {
        for &e in ecs.slice(entities) {
            if .Active not_in e.flags || .Has_Physics not_in e.flags {
                continue
            }

            e.position += e.velocity * dt
        }
    }

    // Cold loop — get_entity replaces the manual owner_id back-reference.
    update_inventories :: proc(inventories: ^ecs.Compact_Table(Inventory)) {
        dense := ecs.slice(inventories)
        entities := ecs.entities_slice(inventories)
        for i in 0..<len(dense) {
            inv := &dense[i]
            owner := entities[i]

            if inv.gold > 0 {
                // Process owner-specific inventory logic
                _ = owner
            }
        }
    }

    // Cold loop — same as update_inventories; ai.target is looked up via
    // get_component into the fat Entity component instead of a target_id
    // field.
    update_ai :: proc(ais: ^ecs.Compact_Table(AI_State), entities: ^ecs.Table(Entity)) {
        dense := ecs.slice(ais)
        ai_eids := ecs.entities_slice(ais)
        for i in 0..<len(dense) {
            ai := &dense[i]
            owner := ai_eids[i]

            owner_e  := ecs.get_component(entities, owner)
            target_e := ecs.get_component(entities, ai.target)
            if owner_e == nil || target_e == nil do continue

            // Example logic: simple aggro-range check
            d := owner_e.position - target_e.position
            dist_sq := d[0]*d[0] + d[1]*d[1] + d[2]*d[2]
            if dist_sq <= ai.aggro_range * ai.aggro_range {
                // Process aggro'd AI logic
            }
        }
    }

main :: proc() {
        db: ecs.Database
        defer ecs.terminate(&db)
        ecs.init(&db, MAX_ENTITIES)

        // Hot path: one Table holding the whole fat component.
        entities: ecs.Table(Entity)
        ecs.table_init(&entities, &db, MAX_ENTITIES)

        // Sparse/rare components: dedicated Compact_Tables (memory-saving dense pools).
        inventories: ecs.Compact_Table(Inventory)
        ais:         ecs.Compact_Table(AI_State)

        ecs.compact_table_init(&inventories, &db, 10)
        ecs.compact_table_init(&ais, &db, 10)

        // Rock: Active only — no physics, no inventory, no AI.
        rock, _ := ecs.create_entity(&db)

        rock_e, _ := ecs.add_component(&entities, rock)
        rock_e^ = { flags = {.Active}, position = {10.0, 0.0, 5.0} }

        // Player: physics + inventory.
        player, _ := ecs.create_entity(&db)

        player_e, _ := ecs.add_component(&entities, player)
        player_e^ = {
            flags    = {.Active, .Has_Physics},
            position = {0.0, 0.0, 0.0},
            velocity = {1.0, 0.0, 0.0},
            health   = 100.0,
        }

        player_inv, _ := ecs.add_component(&inventories, player)
        player_inv.gold = 100

        // Enemy: Position + AI, targets the player.
        enemy, _ := ecs.create_entity(&db)

        enemy_e, _ := ecs.add_component(&entities, enemy)
        enemy_e^ = { flags = {.Active}, position = {3.0, 0.0, 0.0} }

        enemy_ai, _ := ecs.add_component(&ais, enemy)
        enemy_ai.target = player
        enemy_ai.aggro_range = 5.0

        fmt.println("Rock has physics flag?", .Has_Physics in ecs.get_component(&entities, rock).flags)
        fmt.println("Player has physics flag?", .Has_Physics in ecs.get_component(&entities, player).flags)
        fmt.println("AI entities:", ecs.table_len(&ais))

        update_physics(&entities, 0.016)
        update_inventories(&inventories)
        update_ai(&ais, &entities)

        fmt.println()
        fmt.printfln("Player position after tick: %v", ecs.get_component(&entities, player).position)
        fmt.printfln("Rock position after tick (untouched): %v", ecs.get_component(&entities, rock).position)
}

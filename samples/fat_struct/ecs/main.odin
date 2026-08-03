/*
    2026 (c) Oleh, https://github.com/zm69

    ODE_ECS port of hybrid Fat Struct architecture from ../fat/main.odin.
    Same scenario (a static rock, a moving player with an inventory, an enemy
    with simple aggro-range AI), rebuilt with ODE_ECS instead of hand-rolling it.

    NOTE: errors aren't handled here, to keep the code short.
*/

package ode_ecs_fat_struct_ecs

// Core
    import "core:fmt"

// ODE_ECS
    import ecs "../../../"

//
// Components
//

    Position :: struct { x, y, z: f32 }
    Velocity :: struct { dx, dy, dz: f32 }
    Health   :: struct { hp: f32 }

    // No owner_id — get_entity(&table, index) recovers it.
    Inventory :: struct {
        gold:  u32,
        items: [16]u16,
    }

    // Same reasoning — no owner_id.
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

    // Hot loop — Group's aligned dense prefix replaces the manual
    // .Active/.Has_Physics check: a plain parallel-array walk, no branching.
    update_physics :: proc(group: ^ecs.Group, positions: ^ecs.Table(Position), velocities: ^ecs.Table(Velocity), dt: f32) {
        pos_slice := ecs.slice(group, positions)
        vel_slice := ecs.slice(group, velocities)

        for i in 0..<ecs.group_len(group) {
            pos_slice[i].x += vel_slice[i].dx * dt
            pos_slice[i].y += vel_slice[i].dy * dt
            pos_slice[i].z += vel_slice[i].dz * dt
        }
    }

    // Cold loop — get_entity replaces the manual owner_id back-reference.
    update_inventories :: proc(inventories: ^ecs.Compact_Table(Inventory)) {
        for &inv, index in ecs.slice(inventories) {
            owner := ecs.get_entity(inventories, index)

            if inv.gold > 0 {
                // Process owner-specific inventory logic
                _ = owner
            }
        }
    }

    // Cold loop — same as update_inventories; ai.target is looked up via
    // get_component instead of a target_id field.
    update_ai :: proc(ais: ^ecs.Compact_Table(AI_State), positions: ^ecs.Table(Position)) {
        for &ai, index in ecs.slice(ais) {
            owner := ecs.get_entity(ais, index)

            owner_pos  := ecs.get_component(positions, owner)
            target_pos := ecs.get_component(positions, ai.target)
            if owner_pos == nil || target_pos == nil do continue

            // Example logic: simple aggro-range check
            dx := owner_pos.x - target_pos.x
            dy := owner_pos.y - target_pos.y
            dz := owner_pos.z - target_pos.z
            dist_sq := dx*dx + dy*dy + dz*dz
            if dist_sq <= ai.aggro_range * ai.aggro_range {
                // Process aggro'd AI logic
            }
        }
    }

main :: proc() {
        db: ecs.Database
        defer ecs.terminate(&db)
        ecs.init(&db, MAX_ENTITIES)

        // Hot-path components: one Table each — only entities that need one pay for a row.
        positions:  ecs.Table(Position)
        velocities: ecs.Table(Velocity)
        healths:    ecs.Table(Health)

        ecs.table_init(&positions, &db, MAX_ENTITIES)
        ecs.table_init(&velocities, &db, MAX_ENTITIES)
        ecs.table_init(&healths, &db, MAX_ENTITIES)

        // Group: entities with BOTH Position and Velocity stay packed in an
        // aligned dense prefix automatically.
        physics_group: ecs.Group
        ecs.group_init(&physics_group, &db, {&positions, &velocities})

        // Sparse/rare components: dedicated Compact_Tables (memory-saving dense pools).
        inventories: ecs.Compact_Table(Inventory)
        ais:         ecs.Compact_Table(AI_State)

        ecs.compact_table__init(&inventories, &db, 10)
        ecs.compact_table__init(&ais, &db, 10)

        // Rock: Position only — excluded from the physics group automatically.
        rock, _ := ecs.create_entity(&db)

        rock_pos, _ := ecs.add_component(&positions, rock)
        rock_pos^ = { 10.0, 0.0, 5.0 }

        // Player: Position + Velocity + Health + Inventory.
        player, _ := ecs.create_entity(&db)

        player_pos, _ := ecs.add_component(&positions, player)
        player_pos^ = { 0.0, 0.0, 0.0 }

        player_vel, _ := ecs.add_component(&velocities, player)
        player_vel^ = { 1.0, 0.0, 0.0 }

        player_health, _ := ecs.add_component(&healths, player)
        player_health.hp = 100.0

        player_inv, _ := ecs.add_component(&inventories, player)
        player_inv.gold = 100

        // Enemy: Position + AI, targets the player.
        enemy, _ := ecs.create_entity(&db)

        enemy_pos, _ := ecs.add_component(&positions, enemy)
        enemy_pos^ = { 3.0, 0.0, 0.0 }

        enemy_ai, _ := ecs.add_component(&ais, enemy)
        enemy_ai.target = player
        enemy_ai.aggro_range = 5.0

        fmt.println("Rock has velocity (physics-eligible)?", ecs.has_component(&velocities, rock))
        fmt.println("Player has velocity (physics-eligible)?", ecs.has_component(&velocities, player))
        fmt.println("Physics group size (Position AND Velocity):", ecs.group_len(&physics_group))
        fmt.println("AI entities:", ecs.table_len(&ais))

        update_physics(&physics_group, &positions, &velocities, 0.016)
        update_inventories(&inventories)
        update_ai(&ais, &positions)

        fmt.println()
        fmt.printfln("Player position after tick: %v", ecs.get_component(&positions, player)^)
        fmt.printfln("Rock position after tick (untouched): %v", ecs.get_component(&positions, rock)^)
}

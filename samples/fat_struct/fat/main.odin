/*
    2026 (c) Oleh, https://github.com/zm69

    Hybrid Fat Structs architecture: fully hand-rolled, no ODE_ECS at
    all. A monolithic "fat" Entity struct (flags bit_set, position/velocity/
    health) lives in a plain [dynamic] array, and sparse/rare data
    (Inventory, AI_State) lives in separate hand-rolled pools addressed by
    manual u16 handles.

    It is called "hybrid Fat Structs" not just "Fat Structs" because the 
    hot path (position/velocity/health) is still a monolithic struct, but 
    the cold path (Inventory/AI_State) is split into separate pools.
*/

package ode_ecs_fat_struct_fat

import "core:fmt"

// Enforce explicit sizing for predictable cache lines (e.g., exactly 64 bytes)
Entity_Flags :: bit_set[Entity_Flag; u16]
Entity_Flag  :: enum u16 {
    Active,
    Has_Physics,
    Has_Inventory,
    Has_AI,
}

INVALID_HANDLE :: 0xFFFF

// Primary Monolithic Struct (Fits within 64-byte cache line)
Entity :: struct #align(16) {
    id:               u32,
    flags:            Entity_Flags,

    // Handles pointing into dedicated secondary pools
    inventory_handle: u16,
    ai_handle:        u16,

    // Hot-path data used in main update loops
    position:         [3]f32,
    velocity:         [3]f32,
    health:           f32,
    padding:          [2]f32, // Padding to maintain alignment
}

// Secondary Data Structures (Stored off-struct in dedicated pools)
Inventory :: struct {
    owner_id: u32,
    gold:     u32,
    items:    [16]u16,
}

AI_State :: struct {
    owner_id: u32,
    target_id: u32,
    aggro_range: f32,
}

// Engine / World State
World :: struct {
    entities:         [dynamic]Entity,

    // Dense storage pools for sparse/rare data
    inventory_pool:   [dynamic]Inventory,
    ai_pool:          [dynamic]AI_State,
}

// ---------------------------------------------------------------------------
// System Processing Loops
// ---------------------------------------------------------------------------

// 1. Hot Loop: Processes core entities sequentially (Contiguous & Cache-Friendly)
update_physics :: proc(world: ^World, dt: f32) {
    for &e in world.entities {
        // Simple bit set check—no dynamic component query machinery
        if .Active not_in e.flags || .Has_Physics not_in e.flags {
            continue
        }

        e.position += e.velocity * dt
    }
}

// 2. Cold Loop: Iterates directly over the dense secondary pool, NOT the whole entity array
update_inventories :: proc(world: ^World) {
    for &inv in world.inventory_pool {
        // Direct access to inventory data; back-reference owner if needed
        owner := &world.entities[inv.owner_id]

        // Example logic: tick inventory state
        if inv.gold > 0 {
            // Process owner-specific inventory logic
        }
    }
}

// 3. Cold Loop: Iterates directly over the dense AI pool, NOT the whole entity array
update_ai :: proc(world: ^World) {
    for &ai in world.ai_pool {
        // Direct access to AI state; back-reference owner/target if needed
        owner  := &world.entities[ai.owner_id]
        target := &world.entities[ai.target_id]

        // Example logic: simple aggro-range check
        d := owner.position - target.position
        dist_sq := d[0]*d[0] + d[1]*d[1] + d[2]*d[2]
        if dist_sq <= ai.aggro_range * ai.aggro_range {
            // Process aggro'd AI logic
        }
    }
}

// Example usage
main :: proc() {
    world: World

    // Spawn a static rock (No inventory, no AI, no physics)
    append(&world.entities, Entity{
        id               = 0,
        flags            = {.Active},
        position         = {10.0, 0.0, 5.0},
        inventory_handle = INVALID_HANDLE,
        ai_handle        = INVALID_HANDLE,
    })

    // Spawn a Player (Has physics & inventory)
    player_inv_idx := u16(len(world.inventory_pool))
    append(&world.inventory_pool, Inventory{owner_id = 1, gold = 100})

    append(&world.entities, Entity{
        id               = 1,
        flags            = {.Active, .Has_Physics, .Has_Inventory},
        position         = {0.0, 0.0, 0.0},
        velocity         = {1.0, 0.0, 0.0},
        health           = 100.0,
        inventory_handle = player_inv_idx,
        ai_handle        = INVALID_HANDLE,
    })

    // Spawn an Enemy NPC (Has AI, targets the player)
    enemy_ai_idx := u16(len(world.ai_pool))
    append(&world.ai_pool, AI_State{owner_id = 2, target_id = 1, aggro_range = 5.0})

    append(&world.entities, Entity{
        id               = 2,
        flags            = {.Active, .Has_AI},
        position         = {3.0, 0.0, 0.0},
        inventory_handle = INVALID_HANDLE,
        ai_handle        = enemy_ai_idx,
    })

    fmt.println("Rock has velocity (physics-eligible)?", .Has_Physics in world.entities[0].flags)
    fmt.println("Player has velocity (physics-eligible)?", .Has_Physics in world.entities[1].flags)

    physics_count := 0
    for &e in world.entities {
        if .Active in e.flags && .Has_Physics in e.flags {
            physics_count += 1
        }
    }
    fmt.println("Physics group size (Position AND Velocity):", physics_count)
    fmt.println("AI entities:", len(world.ai_pool))

    // Run systems
    update_physics(&world, 0.016)
    update_inventories(&world)
    update_ai(&world)

    fmt.println()
    fmt.printfln("Player position after tick: %v", world.entities[1].position)
    fmt.printfln("Rock position after tick (untouched): %v", world.entities[0].position)
}

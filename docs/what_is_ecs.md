# What is ECS?

**Entity-Component-System (ECS)** is a pattern for organizing game code and data.

To understand ECS, it helps to compare it to standard **Object-Oriented Programming (OOP)**. In traditional OOP, you group data and behavior together inside classes (`Player`, `Enemy`, `Treasure`). In ECS, you completely separate them.

Think of ECS like LEGO bricks:

* **Entities** are empty baseplates.
* **Components** are individual LEGO bricks (data).
* **Systems** are the instructions or machinery that look for specific brick combinations and do work on them.

## Breakdown of the Three Parts

### 1. Entity (The "ID")

An entity contains **no code and no data**. It is literally just an ID (a number like `42`). Its only job is to tag which components belong together.

* `Entity 101`: Player
* `Entity 102`: Goblin
* `Entity 103`: Wooden Chair

### 2. Component (The "Data")

Components are pure data structures (structs) with **no methods or logic**. They describe *what an entity has or is*.

```odin
Position :: struct { x, y: f32 }
Velocity :: struct { dx, dy: f32 }
Health :: struct { current, max: i32 }
Renderable :: struct { sprite: Sprite }
```

### 3. System (The "Logic")

Systems contain **all the code and zero state**. A system queries for entities that have a specific combination of components, loops over them, and updates their data.

```odin
movement_system :: proc(view: ^View) {

	it: ecs.Iterator
	ecs.iterator_init(&it, view)
	
	for pos, vel in ecs.iterate(&it, &positions, &velocities) {
		pos.x += vel.dx
		pos.y += vel.dy
	}
}

```

## Concrete Example: Building Game Objects

Instead of creating deep class inheritance trees (`GameObject` $\rightarrow$ `Actor` $\rightarrow$ `Monster` $\rightarrow$ `Goblin`), you build objects by attaching components to an Entity ID:

| Entity ID | Attached Components | Behavior |
| --- | --- | --- |
| **`Entity 1`** (Player) | `Position`, `Velocity`, `Health`, `Renderable`, `Input` | Moves via player input, takes damage, renders on screen |
| **`Entity 2`** (Goblin) | `Position`, `Velocity`, `Health`, `Renderable`, `AI` | Moves via AI logic, takes damage, renders on screen |
| **`Entity 3`** (Rock) | `Position`, `Renderable` | Can't move, can't take damage, just sits there |
| **`Entity 4`** (Ghost) | `Position`, `Velocity`, `Renderable` | Moves around, but has no `Health` (invulnerable!) |

## Why Use ECS?

1. **No "Inheritance Hell":** In OOP, if you want a flying, explosive barrel, where does it go in your class tree? In ECS, you simply attach `Position`, `Renderable`, `Flying`, and `Explosive` components to an entity.
2. **Cache Locality (Performance):** In memory, all `Position` components are packed tightly together in a contiguous array. When `MovementSystem` iterates over them, the CPU cache loads them all at once, making CPU cache misses rare and execution extremely fast.
3. **Decoupled Systems:** Systems don't need to know about each other. The `RenderSystem` doesn't care about `Health` or `AI`—it just grabs every entity with a `Position` + `Renderable` and draws it.
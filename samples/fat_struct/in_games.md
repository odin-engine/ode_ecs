# Fat structs vs. ECS in games

Quake (and later expanded in Quake II and Quake III) famously used a fat-struct architecture.

```C
// Simplified snapshot from Quake / QuakeC engine header
typedef struct entvars_s {
    float       modelindex;
    vec3_t      origin;
    vec3_t      angles;
    vec3_t      velocity;
    float       health;
    float       armorvalue;
    float       weapon;
    float       movetype;
    float       solid;
    
    // Generic variables reused by entirely different entity types
    string_t    target;
    string_t    targetname;
    float       nextthink;
    void        (*think)(void);
    void        (*touch)(void);
    void        (*blocked)(void);
    
    // ... dozens of other fields for light, sounds, inventory, etc.
} entvars_t;

typedef struct edict_s {
    qboolean    free;
    float       freetime;
    entvars_t   v;          // The monolithic fat struct payload!
    
    // Engine-internal fields (link pointers, leaf nodes, etc.)
} edict_t;
```

World of Warcraft used C++ OOP. ECS was virtually non-existent in the late 90s. The software engineering patterns that popularized modern ECS (such as Dungeon Siege in 2002 or the Thief/Dark Engine component systems) were still in their infancy when Blizzard began writing the Warcraft III engine (from which WoW derived its early technology).

For networking, WoW used `update_fields`:

```C++
// Simplification of WoW's underlying network synchronization array
struct WorldObject {
    uint64_t guid;
    uint32_t type_id;
    Vec3 position;

    // A contiguous, flat array containing packed integers, floats, and bitmasks
    // corresponding to Health, MaxHealth, Mana, DisplayID, Flags, etc.
    uint32_t update_fields[PLAYER_END]; 
};
```
Why this design was chosen:
- Network Delta Masking: Instead of serializing complex C++ objects into custom network packets, the server simply maintained a bitmask tracking which indices in `update_fields` changed during a tick.
- Blitting: If a player took damage, `update_fields[UNIT_FIELD_HEALTH]` was modified; the bit at index N was marked dirty; and the server compressed and broadcast only the modified 32-bit dwords to surrounding clients.

League of Legends (LoL) uses a hybrid, data-driven Object-Oriented Architecture that evolved from a classic C++ class hierarchy into a heavily modular, component-based engine.

Because the game originated as an indie project in 2008 built on top of a custom engine (derived from early C++ game development practices), its architecture reflects a blend of legacy C++ object structures, component-oriented design (for spells and champions), and a deterministic server-authoritative tick model.

Modern MMORPGs, MOBAs, and shooters **do use ECS**, but its adoption varies significantly depending on the genre, performance constraints, and netcode requirements.

While pure ECS is exceptional for certain problems, industry consensus has shifted toward using **the right architectural pattern for the right domain** rather than forcing an entire game engine into a single paradigm.

---

## 1. Genre-by-Genre Breakdown

### Shooter / Hero Shooter (e.g., *Overwatch*, *Valorant*)

* **ECS Adoption:** **High / Core Engine**
* **Why it works:** *Overwatch* is famous for its custom ECS architecture (presented at GDC by Tim Ford).
* **The Netcode Superpower:** In a competitive shooter, **prediction, rollback, and state synchronization** are notoriously difficult. Because ECS isolates pure data into components and decouples logic into systems, Blizzard reduced their netcode surface area down to just a handful of state systems (movement, weapons, prediction). Serializing, diffing, and rolling back state frames becomes an exercise in snapshotting plain data buffers without managing complex C++ object pointers.

### MOBAs (e.g., *League of Legends*, *Dota 2*)

* **ECS Adoption:** **Low / Hybrid Component-Based**
* **Why pure ECS is rare:** MOBAs generally deal with low entity counts per match (10 champions, 50–100 active minions, turrets, projectiles). The CPU bottleneck is almost never L1/L2 cache line iteration across millions of entities.
* **What they use instead:** Heavy **data-driven component hierarchies** coupled with deterministic simulation loops. Game logic is heavily script-driven (e.g., Lua/LuaJIT or custom bytecode) to allow gameplay designers to create unique champion mechanics without fighting the strict archetype constraints of an ECS framework.

### MMORPGs (e.g., *World of Warcraft*, *FFXIV*, *New World*)

* **ECS Adoption:** **Hybrid / Subsystem Specific**
* **Why pure ECS is rare:** MMO entities (like a Player or Raid Boss) carry massive amounts of disparate, highly interconnected state: quest trees, talent grids, complex threat tables, trade skills, social lists, and inventory buffers. In a pure ECS, breaking a 2KB character state into dozens of tiny sparse components creates high query overhead and system-wiring complexity.
* **Where ECS *is* used:** MMOs use ECS (or sparse data-oriented arrays) for **high-density spatial and physical world systems**:
* AOI (Area of Interest) interest management grid queries.
* Massive flocking/crowd simulation (e.g., 500-player RvR battles, ambient creatures).
* Projectile/particle tick loops.
* Server-side collision partitioning.

---

## 2. Are There "Better" Approaches?

Rather than viewing ECS as a silver bullet, modern game engines use **hybrid, task-oriented architectures**. The primary alternatives or complementary patterns include:

```
                  ┌────────────────────────────────────────────────────────┐
                  │                 Engine Architecture                    │
                  └───────────────────────────┬────────────────────────────┘
                                              │
         ┌────────────────────────────────────┼────────────────────────────────────┐
         ▼                                    ▼                                    ▼
┌──────────────────┐                 ┌──────────────────┐                 ┌──────────────────┐
│ Hybrid ECS / SoA │                 │   Fat Structs    │                 │ Data-Driven OOP  │
│ (Hot-Path Loops) │                 │ + Secondary Pools│                 │ + Task Scheduler │
└──────────────────┘                 └──────────────────┘                 └──────────────────┘
• Projectiles & Particles            • Core Player/NPC Entities           • Complex UI Logic
• Physics & Collision                • High-frequency gameplay            • Quest / Dialogue
• Netcode Snapshots                  • Low-boilerplate debugging          • Scripted Events

```

### Approach A: The Hybrid "Fat Struct + Secondary Pools" Pattern

Instead of full archetype graph queries, core entities live in a uniform, flat base struct containing common fields (`position`, `velocity`, `health`, `flags`). Rare data (inventories, AI blackboards) lives in sparse secondary pools.

* **Why developers like it:** It avoids framework boilerplate, compiles instantly, works seamlessly in standard debuggers, and gives you 80% of ECS cache performance with 20% of the architectural friction.

### Approach B: Data-Oriented Subsystems (Job System + Parallel Loops)

Modern engines (like Unreal Engine's MassEntity framework or Unity's DOTS) acknowledge that gameplay code doesn't need to be 100% ECS. Instead, engines keep traditional C++ objects or UObjects for complex gameplay logic, but delegate heavy batch processing to **Data-Oriented Parallel Job Systems**:

* **Example:** Keep player stats in standard objects, but push bullet physics, animation blending, spatial queries, and pathfinding into contiguous Structure-of-Arrays (SoA) layouts processed in parallel across worker threads.

### Approach C: Actor Model / Message-Passing Architecture (Server Backends)

On distributed multiplayer server backends (e.g., Microsoft Orleans, SpatialOS, custom Erlang/Rust nodes), **Actor Systems** are often preferred over ECS. Each player or game zone operates as an isolated Actor receiving asynchronous network messages, isolating state mutation and preventing multi-threading data races across server clusters.

---

## Summary

| Requirement | Best Architectural Match |
| --- | --- |
| **Rollback Netcode & High-FPS Shooters** | **Pure / Strict ECS** (Data serialization & deterministic rollback) |
| **Massive Simulations (100k+ Units/Projectiles)** | **ECS / Pure SoA** (Cache line prefetching & batch processing) |
| **Complex RPG Mechanics / Rapid Gameplay Iteration** | **Fat Structs + Secondary Pools** or **Data-Driven OOP** |
| **Distributed Multi-Server MMO Backends** | **Actor Model / Spatial Grids** |

Most modern production games settle on a **hybrid approach**: utilizing Data-Oriented Design (SoA/ECS) for performance-critical hot paths, while retaining flat structs or component-based scripting for complex, low-density gameplay features.
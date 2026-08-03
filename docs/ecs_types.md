# Archetype ECS vs. Sparse-Dense ECS

There is no absolute "better" — it comes down to a fundamental trade-off: **Blazing fast iteration speed** versus **Cheap structural flexibility**.

Archetype ECS (e.g., Flecs, Bevy, Unity DOTS) and Sparse-Dense / Sparse Set ECS (e.g., EnTT, Shipyard) structure memory in completely opposite ways to solve different problems.

---

## 1. How They Differ in Memory Layout

To understand why one outperforms the other in specific scenarios, look at how they store an entity with `Position` and `Velocity`:

### Archetype ECS (Table-based)

Group entities by their **exact combination of components**. Each combination gets its own table where components are stored side-by-side in tightly packed, contiguous arrays.

```
Archetype [Position, Velocity]:
  Position Column:  [P1, P2, P3, P4]  <- Contiguous in memory
  Velocity Column:  [V1, V2, V3, V4]  <- Contiguous in memory

```

### Sparse-Dense ECS (Sparse Set / Component-based)

Components live in **their own global pools (Sparse Sets)** regardless of what other components an entity has. An entity ID acts as an index to look up its components.

```
Position Pool (Dense Array):  [P1, P2, P3]  <- Contiguous
Velocity Pool (Dense Array):  [V1, V3, V4]  <- Contiguous

Sparse Array Lookup: Entity 3 -> Index 2 in Position, Index 1 in Velocity

```

---

## 2. Head-to-Head Comparison

| Feature | Archetype ECS | Sparse-Dense ECS | Winner |
| --- | --- | --- | --- |
| **Multi-Component Query Speed** | **Maximum L1/L2 Cache Efficiency.** Perfect linear memory access for components residing in the same table. | **Requires Random Memory Access.** Iterating over multiple components requires matching indices via sparse lookups. | **Archetype** |
| **Single-Component Iteration** | Must iterate table by table across all matching archetypes. | Iterates a single dense array sequentially. | **Sparse-Dense** |
| **Adding / Removing Components** | **Expensive (`O(N)` data move).** Requires copying existing components to a new archetype table and updating pointers. | **Instant (`O(1)` append/pop).** Just add to or remove from the target component pool. | **Sparse-Dense** |
| **Flag / Tag Components** | Creates new archetype tables, expanding the archetype graph and causing table fragmentation. | Zero memory cost. Just an ID in a set (or virtually free). | **Sparse-Dense** |
| **Memory Fragmentation** | High risk if you have hundreds of rare, unique component combinations (many tiny tables). | Zero table fragmentation. Memory usage scales strictly with component count. | **Sparse-Dense** |

---

## 3. When to Use Which

### Choose Archetype ECS if:

* **Your core loops involve heavy multi-component queries** (e.g., processing 100,000 entities with `Position + Velocity + Transform + Mesh` every frame).
* **Component combinations are relatively static** (entities spawn, run for a long time with fixed components, and despawn).
* You want **maximum CPU instruction cache & prefetcher friendliness**.

### Choose Sparse-Dense ECS if:

* **Entities frequently change state** by adding or removing components dynamically at runtime (e.g., adding `Poisoned`, `Frozen`, `Selected`, `Stunned` tags).
* You rely on many **sparse components** (e.g., 10,000 entities exist, but only 5 have a `QuestGiver` component).
* You want **predictable `O(1)` performance** for structural operations without sudden memory-copy spikes.

---

## Summary: The Best of Both Worlds

Many modern engine designs realize neither approach is universally superior. As a result, advanced frameworks increasingly adopt **hybrid approaches**:

* Use **Archetypes** for core, high-density components (like transform, physics, and rendering data).
* Use **Sparse Sets** (or bitmasks) for fast-toggling flags, rare components, or temporary state markers.


## What type of ECS is ODE_ECS?

ODE_ECS supports both **sparse-dense** and **archetype** architectures:
* **Sparse-Dense Architecture:** Use [Tables](tables.md) (`Table`, `Tag_Table`, `Compact_Table`, `Tiny_Table`) combined with [Views](view.md) and [Groups](group.md).
* **Archetype Architecture:** Use [`Arch_Table`](arch_table.md).
* **You can mix both architectures** (e.g., an entity can hold components in Arch_Tables as well as other tables).

Check out the benchmark comparison of these approaches [here](https://github.com/zm69/ecs_bench).

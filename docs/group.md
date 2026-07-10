# Groups

A **`Group`** is the fastest way to iterate entities that have a specific set of components. Where a [View](view.md) *detects* when its tables happen to be aligned (with a transparent fallback to per-row pointers), a group **enforces** alignment: it takes exclusive ownership of a set of [tables](tables.md) and physically keeps the entities that have *all* owned components in the contiguous prefix `[0, group_len)` of every owned table — at the same row index in each.

That invariant is maintained automatically: when `add_component` completes a membership (the entity now has every owned component), the group swaps the entity's rows into the prefix; when `remove_component` or `destroy_entity` breaks one, it swaps them out. Iteration is therefore always a raw SoA sweep over `table.rows[:group_len]` — no per-row pointer records, no alignment checks, no rebuilds.

This is the classic *full-owning group* design (as in EnTT), adapted to ODE_ECS tables.

## Creating a group

```odin
import ecs "ode_ecs"

my_ecs:     ecs.Database
positions:  ecs.Table(Position)
velocities: ecs.Table(Velocity)
group:      ecs.Group

ecs.init(&my_ecs, entities_cap = 100_000)
ecs.table_init(&positions, &my_ecs, 100_000)
ecs.table_init(&velocities, &my_ecs, 100_000)

// Owns both tables: entities with Position AND Velocity form the group
ecs.group_init(&group, &my_ecs, {&positions, &velocities})
```

The group can be created before or after entities exist — `group_init` builds the prefix from whatever the tables already hold, and keeps it up to date from then on. No `rebuild` per frame, ever.

**Ownership rules:**

- Only the plain `Table` type can be owned (not `Compact_Table`, `Tiny_Table`, or `Tag_Table`) — the group needs dense rows it is allowed to reorder. Owning a `Compact_Table` returns `API_Error.Only_Table_Can_Be_Owned_By_Group`.
- A table can be owned by **at most one** group (`API_Error.Table_Already_Owned_By_Group`). Terminate the owning group to free its tables for another group.
- Groups have no filters — membership is purely "has all owned components". If you need a filter, use a [View](view.md#filters).

## Iterating

`group_dense_slice` returns one owned table's components of all group members, in group order, as a contiguous slice. Slices of different owned tables share indexing — `ps[i]` and `vs[i]` belong to the same entity:

```odin
ps := ecs.group_dense_slice(&group, &positions)
vs := ecs.group_dense_slice(&group, &velocities)

for i in 0..<len(ps) {
    ps[i].x += vs[i].dx
    ps[i].y += vs[i].dy
}
```

To know *which* entity a row belongs to, ask any owned table — group members sit at the same row in all of them:

```odin
for i in 0..<ecs.group_len(&group) {
    eid := ecs.get_entity(&positions, i)
    // ...
}
```

Like `view_dense_slice`, the slices are invalidated by **any structural change** (add/remove component, create/destroy entity) — use them immediately, never store them. The same goes for component pointers in general: a group swap can move a member's component, so treat structural changes as invalidating held pointers (the pointer returned by `add_component` itself is always correct).

`group_dense_slice` returns `nil` when the table is not owned by this group, or while the group is *dirty* (see the pause section below).

## When to use a group vs a view

Groups trade structural-churn speed for iteration speed. From the `benchmarks/` suite (100K–1M entities, every entity has `Position`, every 2nd also has `Velocity`):

| | ns/op |
|---|---|
| raw sweep of one full table (the ceiling) | 0.38 |
| view iterator over the pos+vel entities | 0.41 – 0.51 |
| **group slices over the pos+vel entities** | **0.38** |
| add+remove the 2nd component, no group | ~4.5 |
| add+remove the 2nd component, with group | ~10.5 |

Rules of thumb:

- **Group** — a hot set you iterate every frame but whose membership changes rarely relative to how often you sweep it (e.g. "movable renderables"). Each join/leave costs one row swap per owned table.
- **View** — churn-heavy sets, filtered sets, sets over `Compact_Table`/`Tiny_Table`/`Tag_Table`, or when several overlapping queries need the same table (a table has only one owner, but any number of subscribed views).

Views and groups coexist on the same tables: group swaps notify subscribed views, which keep resolving correctly (a view over owned tables will usually run on its pointer path, since the group reorders rows underneath it).

## Removing while iterating (`pause_packing`)

Group maintenance moves rows, which is exactly what [`pause_packing`](database.md#pausing-tail-swap-mutating-tables-while-iterating) forbids. So while the tail swap is paused, membership changes are **deferred**: the group is marked *dirty*, `group_dense_slice` returns `nil`, and `resume_packing` rebuilds the group right after packing the tables:

```odin
ecs.pause_packing(&my_ecs)

for /* iterating rows */ {
    ecs.remove_component(&velocities, eid) // ok: cleared in place, group goes dirty
}

ecs.resume_packing(&my_ecs) // packs tables, then rebuilds dirty groups
// group slices are valid again
```

If nothing group-relevant changed during the pause, the group stays clean and its slices remain valid throughout.

## Lifecycle

Groups follow the same lifecycle rules as views:

- `ecs.terminate(&my_ecs)` terminates remaining groups automatically; `ecs.group_terminate(&group)` releases table ownership early.
- Terminating an owned table marks the group `Invalid` (a group missing one of its tables is meaningless); still call `group_terminate` on it to release its allocations.
- `ecs.clear(&my_ecs)` empties groups along with everything else; they resume tracking as new data arrives.

## Other operations

```odin
ecs.group_len(&group)          // number of entities in the group
ecs.group_rebuild(&group)      // rebuild membership from scratch (normally never needed)
ecs.is_valid(&group)
ecs.memory_usage(&group)       // bytes (tiny: the group stores no component data)
```

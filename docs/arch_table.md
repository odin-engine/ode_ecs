# Arch_Table (Archetype Table)

`Arch_Table` is ODE_ECS's archetype-style table: a single struct holding **N component columns that share one row index**, so every column of a row moves together as one unit. Contrast this with the sparse-dense tables ([`Table`](tables.md), `Compact_Table`, `Tiny_Table`, `Tag_Table`), where each component type lives in its own independently-allocated table and a [`Group`](group.md) has to coordinate N separate tables (and N separate row swaps) to keep them in lockstep.

Reach for `Arch_Table` when a fixed set of components always travels together on the same entities and you iterate that combination in a hot loop (e.g. `Position` + `Velocity` + `Sprite` on thousands of entities every frame) — see [Archetype ECS vs. Sparse-Dense ECS](ecs_types.md) for the general trade-off. Keep using sparse-dense tables for components that are frequently added/removed independently, or that only a small subset of entities carry.

`Arch_Table` is a peer of the other four table types, not a replacement — a single `Database` can mix both storage strategies, using `Arch_Table` for your dense hot-path component combinations and `Table`/`Compact_Table`/`Tiny_Table`/`Tag_Table` for everything else.

## Declaring an archetype

Component types are passed once, at init, as a `[]typeid`:

```odin
import ecs "ode_ecs"

Position :: struct { x, y: int }
AI       :: struct { IQ: f32, neurons_count: int }

my_ecs: ecs.Database
units:  ecs.Arch_Table

ecs.init(&my_ecs, entities_cap = 1000)
ecs.arch_table__init(&units, &my_ecs, cap = 500, component_types = {Position, AI})
```

There is no per-component `add_component`/`remove_component` for an archetype — an entity either has the whole row (every declared column) or none of it. This mirrors `Tag_Table`'s all-or-nothing `add_tag`/`remove_tag` more than `Table`'s per-component API.

## Creating, adding, removing

```odin
// allocates an entity id AND its archetype row in one call
robot, err := ecs.create_entity(&units)

// or: entity created elsewhere, add it to the archetype afterwards
soldier, _ := ecs.create_entity(&my_ecs)
ecs.arch_table__add_entity(&units, soldier)

// remove the whole row (every column) — one tail-swap moves all columns at once
ecs.arch_table__remove_entity(&units, soldier)
```

`arch_table__add_entity` returns `API_Error.Component_Already_Exist` if the entity already has a row, and `Container_Is_Full` once `cap` is reached — same error vocabulary as the sparse-dense tables.

## Reading and writing components

```odin
pos := ecs.get_component(&units, robot, Position)
pos.x = 67
pos.y = 43

ai := ecs.get_component(&units, robot, AI)
ai.neurons_count = 42

ecs.has_component(&units, robot)   // true
```

`get_component` returns `nil` for an entity with no row, or for a type that isn't one of this archetype's columns.

> **NOTE:** Like the other table types, removing a row tail-swaps the last row into the vacated slot — component **pointers are only valid until the archetype is mutated**. Store `entity_id`s, not component pointers, and re-`get_component` after mutations.

## Component enable/disable

A soft toggle: temporarily remove a component from query matching (any [View](view.md) that includes its table) without moving or losing the stored value — the opposite of `remove_component`/`add_component`, which is a real structural change that tail-swaps rows and re-zeroes the slot.
Same soft toggle as the sparse-dense tables (see [Tables](tables.md#component-enable-disable)).

```odin
ecs.disable_component(&units, robot) // robot drops out of any view including `units`
ecs.is_component_disabled(&units, robot) // true

pos := ecs.get_component(&units, robot, Position)
pos.x // still there, unchanged — disabling never touches the data

ecs.enable_component(&units, robot) // robot re-enters those views
```

## Iterating with Arch_Iterator

`Arch_Iterator` walks an `Arch_Table`'s own dense rows directly — there is no `View` involved, since every column is already packed in lockstep. There is a single `Arch_Iterator` type (not one struct per arity); component types are supplied at each `ecs.next` call instead of at init — this mirrors how `ecs.iterate` takes its tables at each call for the sparse-dense `Iterator`:

```odin
it: ecs.Arch_Iterator
ecs.arch_iterator_init(&it, &units)

for eid, pos, ai in ecs.next(&it, Position, AI) {
    pos.x += ai.neurons_count
}
```

The first `next` call after `arch_iterator_init` (or `arch_iterator_reset`) resolves each type's column index once and caches it on the iterator instance — every later call in the same loop reuses the cache instead of re-scanning the archetype's columns. Don't call `ecs.next` with a *different* set of types on the same iterator without an intervening `arch_iterator_reset` — the cache won't detect the mismatch.

`ecs.next` doubles as a manual step call outside a `for` loop too, same as `ecs.iterate` does for `Table($T)` columns:

```odin
eid, pos, ai, cond := ecs.next(&it, Position, AI)
```

### Type-free iteration

`ecs.next(&it)` — with no type arguments at all — just advances the cursor and returns the entity id, doing no column resolution whatsoever. Fetch whichever components you actually need afterward with `arch_table__get_component`:

```odin
for eid in ecs.next(&it) {
    pos := ecs.arch_table__get_component(&units, eid, Position)
    ai  := ecs.arch_table__get_component(&units, eid, AI)
    // ...
}
```

Reach for this when you don't want to commit to a fixed column set at the call site (e.g. generic code walking archetypes of varying shape) — the typed `next(&it, T1, ...)` form above is faster (cached column lookups, no per-entity re-scan) and should be preferred whenever the columns you need are known up front.

Use `start_row`/`end_row` on `arch_iterator_init` to process an archetype in batches (e.g. across worker threads):

```odin
ecs.arch_iterator_init(&it, &units, start_row = 0, end_row = 250)
```

`ecs.next` supports 1 to 7 component types per call (you can declare more than 7 columns on the `Arch_Table` itself — the arity limit is only on how many columns a single `next` call reads at once). Passing a type that isn't one of the archetype's columns doesn't error — `next` is `"contextless"`, so it can't assert; it simply reports `cond == false` forever, as if the iterator were already exhausted.

## Other operations

```odin
ecs.table_len(&units)          // number of rows currently stored
ecs.table_cap(&units)          // capacity
ecs.clear(&units)              // remove all rows, keep the archetype initialized
ecs.pack(&units)                // compact holes left while tail swap was paused
ecs.pause_packing(&units)       // defer this archetype's removals to holes
ecs.resume_packing(&units)      // resume and pack
ecs.memory_usage(&units)        // bytes
ecs.is_valid(&units)
ecs.arch_table__dense_slice(&units, Position) // []Position, row order, always packed (no alignment check needed)
```

## Mixing with sparse-dense tables in a View

An `Arch_Table` can be one of the tables in a [`View`](view.md)'s `includes`/`excludes` list, alongside `Table`/`Compact_Table`/`Tiny_Table`/`Tag_Table` — an entity must have a row in the archetype (and every other included table) to match. Arch_Table columns aren't part of the `Table($T)`-only `iterator__next1..7`/`ecs.iterate` sugar, so read them with the manual `iterator_next` + `get_component(&table, &it)` form, passing the component type for the archetype column:

```odin
speeds: ecs.Table(Speed)
units:  ecs.Arch_Table // Position + AI

view: ecs.View
ecs.view_init(&view, &my_ecs, {&speeds, &units})

it: ecs.Iterator
ecs.iterator_init(&it, &view)
for ecs.next(&it) {
    eid := ecs.get_entity(&it)
    spd := ecs.get_component(&speeds, &it)
    pos := ecs.get_component(&units, &it, Position)
    ai  := ecs.get_component(&units, &it, AI)
    // ...
}
```

This path doesn't cache the archetype's column index the way `Arch_Iterator` does (there's nowhere on a shared `View`/`Iterator` to cache it per column-type), so it's slower per read than `Arch_Iterator` + `ecs.next` — prefer iterating an archetype on its own with `Arch_Iterator` when you don't also need to filter/read sparse-dense columns in the same pass.

## Command_Buffer support

Deferred structural changes work the same way as for the other table types (see [Command Buffer](command_buffer.md)) — record during iteration, apply at a sync point:

```odin
ecs.cmd_arch_add_entity(&cb, &units, spawned, Position{x = 1, y = 1}, AI{IQ = 50, neurons_count = 3})
ecs.cmd_remove_component(&cb, &units, doomed)

ecs.replay(&cb)
```

Values passed to `cmd_arch_add_entity` must be in the same order as the archetype's columns were declared in `arch_table__init`. Recording against an entity that already has a row is not an error — replay overwrites it ("last write wins"), same as `cmd_add_component` for sparse-dense tables.

## Serialization

`Arch_Table` participates in whole-database snapshots exactly like the other table types — see [Serialization](serialization.md). No extra steps are needed; `database__serialize`/`database__deserialize` write and validate every column of every archetype automatically.

## Group ownership

A [`Group`](group.md) can own an `Arch_Table` alongside `Table`s — see [Group's "Owning an Arch_Table"](group.md#owning-an-arch_table) section. The whole point of `Arch_Table`'s single shared row index shows up here: a group membership change moves every owned column of an archetype row in **one** `arch_table__swap_rows` call, instead of one `table_raw__swap_rows` call per owned `Table($T)` column the way a Group-of-plain-Tables pays. The `benchmarks/` suite's `churn_arch` vs `churn_vel_group` scenarios measure this directly.

See [Sample14](../samples/sample14/main.odin) for a complete example covering basic `Arch_Table` usage plus mixing it into both a `View` and a `Group`.

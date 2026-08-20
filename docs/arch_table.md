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

None of the declared `component_types` may be zero-sized — `arch_table__init`/`create_entity`/`arch_table__add_entity` assert on this (`API_Error.Component_Size_Cannot_Be_Zero` when validations are compiled out). Use `Tag_Table` for a marker/tag component that carries no data.

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

## Iterating with `slice(&units, T)`

`slice(&units, T)` hands you a column as `[]T` — row order, always packed, no alignment check
needed — and `slice(&units)` gives the matching entity ids in the same order. This is the same
`entities_slice` + `column_slice` idiom used for [View](view.md#iterating-with-sliceview-t):

```odin
eids     := ecs.slice(&units)
pos_slice := ecs.slice(&units, Position)
ai_slice  := ecs.slice(&units, AI)

for i in 0..<len(eids) {
    pos_slice[i].x += ai_slice[i].neurons_count
    fmt.println(eids[i], pos_slice[i])
}
```

The slices are re-derived from the archetype's column storage each call — no allocation — but
they're only valid until the next structural change (add/remove entity); don't hold them across
one. Splitting the range into batches (e.g. across worker threads) is plain index math on
`eids`/the column slices — see [View's Batching](view.md#batching-eg-across-threads) for the same
pattern.

## Arch_Iterator (deprecated, back-compat)

`Arch_Iterator` is the older, per-row way to walk an `Arch_Table`'s own dense rows directly — kept
for whoever's already using it. `slice(&units)` + `slice(&units, T)` above covers the same ground
and is the recommended way to iterate now; the two are measured at parity (see
`benchmarks/main.odin`'s `iter_arch_slice_eids` vs `iter_arch_it`).

There is a single `Arch_Iterator` type (not one struct per arity); component types are supplied at
each `ecs.next` call instead of at init:

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
ecs.slice(&units, Position)    // []Position, row order, always packed (no alignment check needed)
ecs.slice(&units)              // []entity_id, same row order
```

## Mixing with sparse-dense tables in a View

An `Arch_Table` can be one of the tables in a [`View`](view.md)'s `includes`/`excludes` list, alongside `Table`/`Compact_Table`/`Tiny_Table`/`Tag_Table` — an entity must have a row in the archetype (and every other included table) to match.

Every component of an included `Arch_Table` is automatically available through `slice(&view, T)`, the same as a `Table`/`Compact_Table`/`Tiny_Table` column — `view_init` caches a real pointer per row for each of the archetype's component types, since that set never changes after `arch_table__init`, so there's nothing to opt into later:

```odin
speeds: ecs.Table(Speed)
units:  ecs.Arch_Table // Position + AI

view: ecs.View
ecs.view_init(&view, &my_ecs, {&speeds, &units})

spd_slice := ecs.slice(&view, Speed)
pos_slice := ecs.slice(&view, Position)
ai_slice  := ecs.slice(&view, AI)
eids      := ecs.entities_slice(&view)

for i in 0..<len(spd_slice) {
    // spd_slice[i], pos_slice[i], ai_slice[i] and eids[i] are the same entity
}
```

`Iterator` still works too, for a manual per-row walk — pass the component type to `get_component(&table, &it, T)`:

```odin
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

Both paths read the same cached pointer now, so neither is slower than the other for an Arch_Table column specifically — and `slice(&units)`/`slice(&units, T)` on the archetype directly (above) is measured at parity with `Arch_Iterator` + `ecs.next` for iterating an archetype on its own, so prefer `slice` there too unless you already have an `Arch_Iterator` in hand.

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

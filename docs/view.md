# Views

A **`View`** iterates entities that have a specific set of components — the ECS equivalent of a database query like *"all entities with `Position` AND `AI`"*. A view stores no component data: each view row holds an `entity_id` plus pointers into the component [tables](tables.md).

Views are **live**: creating/destroying entities and adding/removing components/tags automatically updates every subscribed view. You don't rebuild them per frame.

## Creating a view

```odin
import ecs "ode_ecs"

my_ecs:    ecs.Database
positions: ecs.Table(Position)
ais:       ecs.Table(AI)
view:      ecs.View

ecs.init(&my_ecs, entities_cap = 100)
ecs.table_init(&positions, &my_ecs, 100)
ecs.table_init(&ais, &my_ecs, 100)

// All entities that have BOTH a Position and an AI component
ecs.view_init(&view, &my_ecs, {&positions, &ais})
```

Any table variant can be included — `Table`, `Compact_Table`, `Tiny_Table`, `Tag_Table`, `Arch_Table`. A `Tag_Table` in the include list restricts the view to tagged entities.

The view's capacity is the smallest capacity among the included tables (`ecs.view_cap`). Like tables, views are terminated automatically with the database; terminating one of a view's tables early marks the view `Invalid`.

If the view is created **before** entities/components exist, it stays up to date by itself. If you create it later, populate it once with:

```odin
ecs.rebuild(&view) // O(n) over the smallest included table
```

## Iterating with `slice(&view, T)`

`slice(&view, T)` hands you a column as `[]^T` — live component pointers, in view row order —
and `entities_slice(&view)` gives the matching entity ids in the same order:

```odin
pos_slice := ecs.slice(&view, Position)
ai_slice  := ecs.slice(&view, AI)
eids      := ecs.entities_slice(&view)

for i in 0..<len(pos_slice) {
    eid := eids[i]
    pos := pos_slice[i]
    ai  := ai_slice[i]

    pos.x += 1
    fmt.println(eid, pos, ai)
}
```

Covers `Table`/`Compact_Table`/`Tiny_Table` columns, and every component of an included
`Arch_Table` too — `view_init` caches a real pointer per row for each of the archetype's
component types automatically (its component set never changes after `arch_table__init`, so
there's nothing to opt into later); see
[Arch_Table](arch_table.md#mixing-with-sparse-dense-tables-in-a-view). `Tag_Table` columns carry
no data at all and are never sliceable; use the `Iterator` below (or membership alone, via
`excludes`/`any_of`/a `Tag_Table` in `includes`) for those.

The slices are re-derived from the view's column storage each call — no allocation — but they're
only valid until the next structural change (add/remove component, create/destroy entity); don't
hold them across one.

### Batching (e.g. across threads)

`slice(&view, T)` is a plain Odin slice, so splitting it into disjoint batches is plain index
math — derive the bounds from the view's actual length, then index (or sub-slice) within them:

```odin
batch := ecs.view_len(&view) / N_WORKERS
// worker i: start = i * batch, end = i == N_WORKERS-1 ? ecs.view_len(&view) : (i+1) * batch

pos_slice := ecs.slice(&view, Position)
vel_slice := ecs.slice(&view, Velocity)

for i in start..<end {
    pos_slice[i].x += vel_slice[i].dx
    pos_slice[i].y += vel_slice[i].dy
}
```

Two workers touching disjoint index ranges of the same slice is race-free — nothing about this is
View-specific, it's the same rule as any parallel-disjoint-slice-write pattern. What *is*
View-specific: don't do structural changes (create/destroy entity, add/remove component) during
the parallel phase — they'd move rows and invalidate the slices out from under a batch that hasn't
finished reading them yet. Record them into a per-worker `Command_Buffer` instead and replay at a
single-threaded sync point; see [Sample11](../samples/sample11/main.odin).

The bounds must come from `ecs.view_len(&view)` (or the slice's own `len`) at split time, not a
hardcoded literal — a stale constant silently drifts out of sync with the view's actual size as
entities are added/removed over the program's life, producing either an out-of-bounds index or
unprocessed rows.

## Iterator (back-compat)

`Iterator` is the older, per-row way to walk a view — kept for `Tag_Table` columns, which carry
no data and are never sliceable.
Everything else, `Arch_Table` columns included, is covered by `slice(&view, T)`; prefer it — it's
faster and doesn't need a cursor object.

```odin
it: ecs.Iterator
ecs.iterator_init(&it, &view)

for ecs.next(&it) {
    eid := ecs.get_entity(&it)
    pos := ecs.get_component(&positions, &it)
    ai  := ecs.get_component(&ais, &it)

    pos.x += 1
    fmt.println(eid, pos, ai)
}
```

`ecs.next(&it)` with no table arguments just advances the cursor and reports whether a row is left — fetch the entity/components yourself, as above. Or fuse `get_entity`/`get_component` into the same call, `Table($T)` columns only, arity 0-7:

```odin
for eid, pos, ai in ecs.next(&it, &positions, &ais) {
    fmt.println(eid, pos, ai)
}
```

Mutating component **values** while iterating is fine. Structural changes (add/remove component, create/destroy entity) are not reflected by a running iterator — call `ecs.iterator_reset(&it)` after them, or avoid structural changes mid-loop (see [pause_packing](database.md#pausing-tail-swap-mutating-tables-while-iterating) for removal-while-iterating patterns).

> `ecs.iterate` (component counts 1–4, no entity id in the return) also still exists, predating `ecs.next` — same back-compat status.

Internally, `Iterator` still uses a dense fast path when the view is "aligned" (view row `i` corresponds to row `i` in every `Table` column) — this is automatic and not something you opt into or check. `iterator_init` also takes optional `start_row`/`end_row` for batching, the same idea as [Batching](#batching-eg-across-threads) above, just via a cursor instead of index math — kept for whoever's already using it, not the recommended way to start.

## Excludes

Besides the included tables, `view_init` takes an optional `excludes` list — an entity enters the view only if it has a component in **none** of the excluded tables ("has `Position` but NOT `Stunned`"):

```odin
positions: ecs.Table(Position)
stunned:   ecs.Tag_Table
view:      ecs.View

// All entities with a Position that are NOT tagged stunned
ecs.view_init(&view, &my_ecs, {&positions}, excludes = {&stunned})
```

Any table variant can be excluded. Excluded tables are **not** columns: they contribute no component data, don't affect `view_cap`, and can't be read through the view — they only gate membership. The view keeps itself up to date automatically: adding the excluded component (or tag) to a member removes it from the view, removing the component puts it back (if everything else still matches).

Excludes cost one extra bitset test per membership check — prefer them over an equivalent proc filter, which costs an indirect call plus manual re-evaluation.

## `any_of` (OR)

`view_init` also takes an optional `any_of` list — if non-empty, an entity enters the view only if it has a component in **at least one** of these tables ("has `Position` AND (`Enemy` OR `Boss`)"), alongside `includes` (AND) and `excludes` (NOT):

```odin
positions: ecs.Table(Position)
enemy:     ecs.Tag_Table
boss:      ecs.Tag_Table
view:      ecs.View

// All entities with a Position that are tagged Enemy or Boss (or both)
ecs.view_init(&view, &my_ecs, {&positions}, any_of = {&enemy, &boss})
```

Like `excludes`, `any_of` tables are **not** columns — no component data is read from them, they don't affect `view_cap`, and they're auto-maintained: tagging/adding to any one of them can admit an entity, and only losing the *last* matching one evicts it (having two of the three `any_of` tables and losing one leaves the entity a member).

A table can't be in both `includes` and `any_of` (redundant — AND already guarantees it; `view_init` returns `API_Error.Table_Cannot_Be_Included_And_Any_Of`). A table *can* be in both `excludes` and `any_of` — not a contradiction, just two independent constraints on the same table (`excludes` still wins if the entity has it).

`any_of` costs one extra bitset test per membership check, same tier as `excludes` — well below a filter proc.

## Component enable/disable

Unlike `excludes`/`any_of` (structural properties of the view itself, fixed at `view_init`), [`disable_component`/`enable_component`](tables.md#component-enable-disable) is a *per-entity* toggle that works with any view — disabling one of a view's included tables for an entity evicts it, without removing the component:

```odin
ecs.disable_component(&positions, robot) // robot leaves any view that includes `positions`
ecs.enable_component(&positions, robot)  // robot re-enters
```

Same cost as `excludes`/`any_of` — one bitset test against a per-entity bitset instead of a per-view one — and no data movement at all, unlike a real `remove_component`/`add_component` round-trip.

## Filters

Five ways to narrow a view beyond "has all included components", fastest first:

1. **`excludes`** (above) — for *structural* negation ("has A, not B"). Auto-maintained, one bitset test.
2. **`any_of`** (above) — for *structural* disjunction ("has A, and (B or C)"). Auto-maintained, one bitset test.
3. **`disable_component`/`enable_component`** (above) — a per-entity toggle on a component already present, same bitset-test cost as `excludes`/`any_of`, with no data movement.
4. **A `Tag_Table` in `includes`** — for predicates over *mutable data* that you can maintain explicitly. Instead of filtering on `health.hp > 0`, keep an `alive` tag and `add_tag`/`remove_tag` where `hp` changes; the view follows automatically.
5. **A filter proc** (below) — when the predicate genuinely needs code. Costs an indirect call per candidate entity, and *you* must re-evaluate entities whose data changes.

A filter is a proc passed to `view_init` that decides per entity whether it enters the view, on top of the component match:

```odin
Health :: struct { hp: int }

healths:     ecs.Table(Health)
alive_view:  ecs.View

// Runs whenever an entity is considered for view membership;
// return true to include it.
alive_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil) -> bool {
    health := ecs.get_component(&healths, row) // components are readable inside the filter
    return health.hp > 0
}

ecs.view_init(&alive_view, &my_ecs, {&healths, &positions}, filter = alive_filter)
```

You can pass custom state through `view.user_data` (set it **before** entities start flowing in):

```odin
My_User_Data :: struct { min_hp: int }
data := My_User_Data{ min_hp = 10 }

my_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil) -> bool {
    if user_data == nil do return false
    data := (^My_User_Data)(user_data)
    return ecs.get_component(&healths, row).hp >= data.min_hp
}

view.user_data = &data
ecs.view_init(&view, &my_ecs, {&healths}, filter = my_filter)
```

The filter runs when membership *changes* (component added/removed etc.), not when component values change. If your filter depends on mutable data (like `hp`), re-evaluate affected entities after mutating:

```odin
health := ecs.get_component(&healths, eid)
health.hp = 0
ecs.rerun_views_filters(&healths, eid) // re-runs filters of subscribed views for eid
```

(A proc group over `table__rerun_views_filters` / `compact_table__rerun_views_filters` / `tiny_table__rerun_views_filters`. Note there is no Tag_Table entry: tags carry no component data for a filter to read, so a filtered view that includes a tag table must re-run its filter through one of its *data* tables.)

After *bulk* mutations, re-evaluate the whole view in one sweep instead:

```odin
for eid in wave_of_damage { ecs.get_component(&healths, eid).hp -= 10 }
ecs.refilter(&view) // removes rows that stopped matching, adds candidates that now match
```

`refilter` is cheaper than `rebuild`: it doesn't clear the view, surviving rows keep their positions (and their dense alignment), and only entities whose match actually changed move. It's a no-op on a view without a filter.

See [Sample06](../samples/sample06/main.odin) for a complete filter example.

## Suspend / resume

`suspend` stops a view from receiving updates; `resume` re-enables them. Useful when doing bulk structural changes you know the view doesn't care about mid-way:

```odin
ecs.suspend(&view)
// ... bulk create/destroy/add/remove ...
ecs.resume(&view)
ecs.rebuild(&view) // the view missed the updates — rebuild it
```

What a suspended view misses matters:

- **Missed adds** are safe — the view is merely incomplete until you `rebuild`.
- **Missed removals or row moves of entities already in the view** are not: the
  view's rows then reference table rows that no longer belong to those entities
  (tables keep tail-swapping regardless), so iterating reads other entities'
  data. The view tracks this with an internal `stale` flag (`ECS_VALIDATIONS`
  builds only): initializing an iterator over a stale view asserts with a
  message telling you to `rebuild`. `rebuild` (or `clear`) resets the flag.

So the rule stays: after a suspend window that could have removed or moved
members, `rebuild` before iterating. The assert is a safety net, not a
substitute.

## Other operations

```odin
ecs.view_len(&view)                       // number of rows (matching entities)
ecs.view_cap(&view)                       // max rows = min(cap of included tables)
ecs.view_components_match(&view, eid)     // would this entity match the view's tables? (ignores filter)
ecs.clear(&view)                          // empty the view (e.g. before a manual rebuild)
ecs.memory_usage(&view)                   // bytes
ecs.is_valid(&view)
```

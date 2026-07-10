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

Any table variant can be included — `Table`, `Compact_Table`, `Tiny_Table`, `Tag_Table`. A `Tag_Table` in the include list restricts the view to tagged entities.

The view's capacity is the smallest capacity among the included tables (`ecs.view_cap`). Like tables, views are terminated automatically with the database; terminating one of a view's tables early marks the view `Invalid`.

If the view is created **before** entities/components exist, it stays up to date by itself. If you create it later, populate it once with:

```odin
ecs.rebuild(&view) // O(n) over the smallest included table
```

## Iterating with an Iterator

```odin
it: ecs.Iterator
ecs.iterator_init(&it, &view)

for ecs.iterator_next(&it) {
    eid := ecs.get_entity(&it)
    pos := ecs.get_component(&positions, &it)
    ai  := ecs.get_component(&ais, &it)

    pos.x += 1
    fmt.println(eid, pos, ai)
}
```

Mutating component **values** while iterating is fine. Structural changes (add/remove component, create/destroy entity) are not reflected by a running iterator — call `ecs.iterator_reset(&it)` after them, or avoid structural changes mid-loop (see [pause_packing](database.md#pausing-tail-swap-mutating-tables-while-iterating) for removal-while-iterating patterns).

### Batched iteration

`iterator_init` takes optional `start_row` / `end_row`, letting you split a view into batches — e.g. to process them on separate threads (parallel *reads* are safe; do structural changes in a single-threaded phase):

```odin
half := ecs.view_len(&view) / 2

it1, it2: ecs.Iterator
ecs.iterator_init(&it1, &view, 0, half)
ecs.iterator_init(&it2, &view, half, ecs.view_len(&view))
```

## The dense fast path and `view_dense_slice`

The iterator automatically uses a *dense fast path* when the view is "aligned" — when view row `i` corresponds to row `i` in every `Table` of the view. This is the common case (it holds when components are added in the same order per entity and survives despawn/respawn churn) and reads components straight from the tables' dense arrays, roughly 2× faster. It is fully automatic with a transparent fallback.

For the absolute fastest iteration, `view_dense_slice` hands you the raw component slices in view-row order (or `nil` when the view is not aligned):

```odin
pos_slice := ecs.view_dense_slice(&view, &positions)
ai_slice  := ecs.view_dense_slice(&view, &ais)

if pos_slice != nil && ai_slice != nil {
    for i in 0..<len(pos_slice) {
        // pos_slice[i] and ai_slice[i] belong to the same entity (view row i)
        pos_slice[i].x += ai_slice[i].neurons_count
    }
} else {
    // Not dense-aligned right now: fall back to the Iterator
}
```

Only `Table` columns participate (`Compact_Table`/`Tiny_Table`/`Tag_Table` columns never do). The slices are invalidated by any structural change — use them immediately, never store them.

Alignment here is *detected*, so it can be lost (e.g. an entity removes one component but keeps the other). If you need slices that are **always** valid for a hot set of components, a [Group](group.md) enforces alignment instead of detecting it — at the cost of a row swap per membership change.

## Filters

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

ecs.view_init(&alive_view, &my_ecs, {&healths, &positions}, alive_filter)
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
ecs.view_init(&view, &my_ecs, {&healths}, my_filter)
```

The filter runs when membership *changes* (component added/removed etc.), not when component values change. If your filter depends on mutable data (like `hp`), re-evaluate affected entities after mutating:

```odin
health := ecs.get_component(&healths, eid)
health.hp = 0
ecs.table__rerun_views_filters(&healths, eid) // re-runs filters of subscribed views for eid
```

(`compact_table__rerun_views_filters` / `tiny_table__rerun_views_filters` for the other variants.)

See [Sample06](../samples/sample06/main.odin) for a complete filter example.

## Suspend / resume

`suspend` stops a view from receiving updates; `resume` re-enables them. Useful when doing bulk structural changes you know the view doesn't care about mid-way:

```odin
ecs.suspend(&view)
// ... bulk create/destroy/add/remove ...
ecs.resume(&view)
ecs.rebuild(&view) // the view missed the updates — rebuild it
```

## Other operations

```odin
ecs.view_len(&view)                       // number of rows (matching entities)
ecs.view_cap(&view)                       // max rows = min(cap of included tables)
ecs.view_components_match(&view, eid)     // would this entity match the view's tables? (ignores filter)
ecs.clear(&view)                          // empty the view (e.g. before a manual rebuild)
ecs.memory_usage(&view)                   // bytes
ecs.is_valid(&view)
```

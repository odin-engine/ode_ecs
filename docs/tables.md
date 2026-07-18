# Tables

A **table** is a dense array of components of one type — very much like a table in a relational database. Each component type gets its own table, and every table is attached to a [Database](database.md). Components are stored 100% densely (no gaps, no per-component metadata), so iterating a table is just iterating a slice.

ODE_ECS has four table variants. They share the same core operations but trade memory for capacity differently:

| Variant | Component data | When to use |
|---|---|---|
| `Table(T)` | dense array, `cap` up to `entities_cap` | Default choice. Fastest lookup (`eid → ptr` is a flat array sized to `entities_cap`). |
| `Compact_Table(T)` | dense array | Memory saver: the `eid → ptr` index is a Robin Hood hash map instead of a flat array. Good when `cap` is much smaller than `entities_cap` (rule of thumb: `cap < entities_cap / 4`) but bigger than a Tiny_Table. |
| `Tiny_Table(T)` | fixed 8 rows stored inline in the struct | Very small tables (singletons, a handful of bosses). No row allocation at all. |
| `Tag_Table` | none | Stores no data — only "tags" entities. Useful as a [view](view.md) filter. |

All variants preallocate everything at init and never reallocate. `cap` cannot exceed the database's `entities_cap`.

Tables do **not** need to be terminated manually — terminating the database terminates them. (Manual `table_terminate` etc. is available if you need to tear one down early; note it invalidates any views that include the table.)

## Table(T)

```odin
import ecs "ode_ecs"

Position :: struct { x, y: int }

my_ecs:    ecs.Database
positions: ecs.Table(Position)

ecs.init(&my_ecs, entities_cap = 100)
ecs.table_init(&positions, &my_ecs, cap = 100)
```

### Adding, getting, removing components

```odin
robot, _ := ecs.create_entity(&my_ecs)

// Add — returns a pointer to the (zeroed) component inside the table
pos, err := ecs.add_component(&positions, robot)
pos.x = 67
pos.y = 43

// Get — nil if the entity has no such component
pos2 := ecs.get_component(&positions, robot)
assert(pos == pos2)

// Query
ecs.has_component(&positions, robot)   // true

// Remove
ecs.remove_component(&positions, robot)
```

`add_component` returns `API_Error.Component_Already_Exist` (together with the existing component pointer) if the entity already has one, and `Container_Is_Full` when the table is at `cap`.

> **NOTE:** Removing a component tail-swaps the last row into the vacated slot, so component **pointers are only valid until the table is mutated**. Store `entity_id`s, not component pointers, and re-`get_component` after mutations. (Exception: while [tail swap is paused](database.md#pausing-tail-swap-mutating-tables-while-iterating), pointers stay stable until the table is packed.)

### Iterating a table

`positions.rows` is a plain dense slice — iterate it directly:

```odin
for &pos, index in positions.rows {
    eid := ecs.get_entity(&positions, index)   // entity that owns this row
    ai  := ecs.get_component(&ais, eid)        // reach its other components
    fmt.println(eid, pos, ai)
}
```

To iterate entities that have a specific *set* of components, use a [View](view.md) instead.

Avoid mutating a table while iterating over it (removals move rows). Either drain it:

```odin
for ecs.table_len(&my_table) > 0 {
    eid := ecs.get_entity(&my_table, 0)
    ecs.destroy_entity(&my_ecs, eid)
}
```

…or use `pause_packing` / `resume_packing` — see the [Database doc](database.md#pausing-tail-swap-mutating-tables-while-iterating). These also work on a single table directly (`ecs.pause_packing(&my_table)`), independent of the database-wide pause — see [Pause scope: Database, Table, or Group](database.md#pause-scope-database-table-or-group). Rejected with `ecs.API_Error.Cannot_Pause_Table_Owned_By_Group` if the table is owned by a [Group](group.md) — pause the group instead.

### Copying and moving components between tables

Both tables must hold the same component type (useful e.g. for moving entities between "active"/"inactive" tables):

```odin
backup: ecs.Table(Position)
ecs.table_init(&backup, &my_ecs, cap = 100)

dst, src, _ := ecs.copy_component(&backup, &positions, robot) // copy data, keep source
dst2, _     := ecs.move_component(&backup, &positions, robot) // copy, then remove from source
```

### Other operations

```odin
ecs.table_len(&positions)      // number of components currently stored
ecs.table_cap(&positions)      // capacity
ecs.clear(&positions)          // remove all rows, keep the table initialized
ecs.pack(&positions)           // compact holes left while tail swap was paused
ecs.pause_packing(&positions)  // defer this table's removals to holes, independent of the database-wide pause
ecs.resume_packing(&positions) // resume and pack this table
ecs.memory_usage(&positions)   // bytes
ecs.is_valid(&positions)
```

## Compact_Table(T)

Same API as `Table`, initialized with `compact_table__init`:

```odin
AI :: struct { neurons_count: int }

ais: ecs.Compact_Table(AI)
ecs.compact_table__init(&ais, &my_ecs, cap = 50) // cap much smaller than entities_cap

ai, _ := ecs.add_component(&ais, robot)   // same proc group as Table
ai.neurons_count = 88
```

`add_component`, `remove_component`, `get_component`, `has_component`, `copy_component`, `move_component`, `table_len`, `table_cap`, `clear`, `pack` all work through the same proc groups. The difference is purely internal: `eid → component` lookups go through a hash map, saving `(entities_cap - map) * 8` bytes at a small lookup cost.

## Tiny_Table(T)

Fixed capacity of `ecs.TINY_TABLE__ROW_CAP` (8) rows, stored inline in the struct — no per-table row allocation. There is no `cap` parameter:

```odin
Camera :: struct { zoom: f32 }

cameras: ecs.Tiny_Table(Camera)
ecs.tiny_table__init(&cameras, &my_ecs)

cam, _ := ecs.add_component(&cameras, main_camera_eid)
cam.zoom = 2.0
```

Everything else works like the other tables (`get_component`, `remove_component`, `has_component`, `copy_component` / `move_component` between two Tiny_Tables, etc.). At most `TINY_TABLE__VIEWS_CAP` (8) views can subscribe to a Tiny_Table.

**Usage example:**

```odin
pos_table : ecs.Tiny_Table(Position) // Tiny_Table !!!
err = ecs.tiny_table__init(&pos_table, &db)
```

**Iteration example:**

```odin
for i := 0; i < ecs.table_len(&pos_table); i += 1 {
    component := &pos_table.rows[i]
    eid := ecs.get_entity(&pos_table, i)

    if eid == human {
        fmt.println("Human: ", eid, component)
    } else if eid == bird {
        fmt.println("Bird: ", eid, component)
    } else {
        fmt.println("Unknown entity: ", eid, component)
    }
}
```

See [this sample](../samples/sample04/main.odin) for more usage examples.

> **NOTE:** In most cases, start by using `Table`. If memory optimization becomes necessary at later stages, consider switching to `Tiny_Table` or `Compact_Table` in some places. As Donald Knuth famously stated: *“Premature optimization is the root of all evil.”*

## Tag_Table

A `Tag_Table` stores no component data at all — it only marks ("tags") entities. Its `rows` is a dense slice of `entity_id`:

```odin
is_alive: ecs.Tag_Table
ecs.tag_table__init(&is_alive, &my_ecs, cap = 100)

human, _ := ecs.create_entity(&my_ecs)

ecs.tag(&is_alive, human)      // alias: ecs.add_tag
ecs.untag(&is_alive, human)    // alias: ecs.remove_tag

// O(1) membership query (ecs.has_component also dispatches to it)
if ecs.has_tag(&is_alive, human) { /* ... */ }

// Iterate tagged entities directly
for eid in is_alive.rows {
    fmt.println("alive:", eid)
}
```

Tags participate in views exactly like components, which is their main use — narrowing a view to tagged entities without paying for component storage:

```odin
view: ecs.View
// all entities that have AI + Position AND are tagged alive
ecs.view_init(&view, &my_ecs, {&ais, &positions, &is_alive})
```

See [Sample06](../samples/sample06/main.odin) for a complete Tag_Table example.

## Choosing a variant

Use `Tiny_Table` if `cap <= 8`; use `Compact_Table` if you want to save memory and `cap` is less than `entities_cap / 4` (but more than 8); otherwise — or if you don't care about memory — use `Table`. Use `Tag_Table` when there is no data to store at all. [Sample02](../samples/sample02/main.odin) demonstrates memory optimization with the different variants.

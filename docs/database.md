# Database

A **`Database`** is the "world" object of ODE_ECS — it owns entities, component tables, views and (optionally) parent/child relations. Other ECS libraries call this concept a *World* or *Scene*. A single game can use as many independent databases as it wants; they share nothing.

All memory is preallocated when the database (and its tables/views) are initialized. Nothing reallocates during the game loop.

See also: [Tables](tables.md) · [Views](view.md) · [Relations](relations.md) · [Groups](group.md)  · [Command Buffer](command_buffer.md)

## Initialization

```odin
import ecs "ode_ecs"

my_ecs: ecs.Database

// entities_cap is the maximum number of entities that can be alive at once
ecs.init(&my_ecs, entities_cap = 100)
defer ecs.terminate(&my_ecs)
```

You can pass a custom allocator; every table and view attached to this database will use it too:

```odin
ecs.init(&my_ecs, entities_cap = 100, allocator = my_allocator)
```

`terminate` frees everything owned by the database, including all attached tables and views — you do not need to terminate them individually. After `terminate` the struct is back in the `Not_Initialized` state and can be re-`init`-ed.

Multiple databases are fully supported:

```odin
world_ecs: ecs.Database
ui_ecs:    ecs.Database

ecs.init(&world_ecs, entities_cap = 100_000)
ecs.init(&ui_ecs,    entities_cap = 200)
```

## Entities

An entity is just an ID (`ecs.entity_id`) — a `bit_field` packing an index (`ix`, 56 bits) and a generation (`gen`, 8 bits). All entity data lives in component [tables](tables.md).

```odin
robot, err := ecs.create_entity(&my_ecs)
if err != nil { /* Container_Is_Full when entities_cap is reached */ }

// ... add components, play the game ...

ecs.destroy_entity(&my_ecs, robot)
```

`destroy_entity` automatically removes the entity's components from **every** table it belongs to (the database tracks per-entity membership in a bitset, so this is O(number of components), not O(number of tables)). If a [Relations_Table](relations.md) exists, the entity is also unlinked from its parent and its children are orphaned — or destroyed too, with the optional flag:

```odin
ecs.destroy_entity(&my_ecs, boss, destroy_children = true) // destroys boss and all descendants
```

### Stale IDs and generations

When an entity is destroyed its index is recycled, but the generation is bumped. A saved `entity_id` from before the destroy will no longer match:

```odin
saved := robot                            // stored somewhere in game code
ecs.destroy_entity(&my_ecs, robot)

ecs.is_entity_expired(&my_ecs, saved)     // true — this ID refers to a destroyed entity
```

Procedures that take an `entity_id` validate it and return `API_Error.Entity_Id_Expired` (or `Entity_Id_Out_of_Bounds`) for stale IDs.

### Other entity procedures

```odin
n   := ecs.entities_len(&my_ecs)        // number of currently alive entities
eid := ecs.get_entity(&my_ecs, index)   // alive entity by internal index (0 ..< entities_len)
```

## Clearing

`ecs.clear(&my_ecs)` wipes all data — every table, every view, relations and all entities — but keeps every object initialized with its capacity intact. Generations are bumped so entity IDs held across the clear are detected as expired. Useful for "restart level" without re-initializing anything.

## Pausing tail swap (mutating tables while iterating)

Normally, removing a component tail-swaps the last row into the vacated slot, which moves another entity's component. That makes removal during iteration unsafe. `pause_packing` defers this:

```odin
ecs.pause_packing(&my_ecs)

for i in 0..<ecs.table_len(&monsters) {
    eid := ecs.get_entity(&monsters, i)
    if eid.ix == ecs.DELETED_INDEX do continue // hole (already removed this frame)

    monster := ecs.get_component(&monsters, eid)
    if monster.hp <= 0 do ecs.destroy_entity(&my_ecs, eid) // safe: nothing moves
}

ecs.resume_packing(&my_ecs) // packs all tables with holes, re-enables tail swap
```

While paused, removals clear components **in place**, leaving holes: no row moves, component pointers stay stable, and views are still notified. `get_entity` for a hole returns an ID with `ix == ecs.DELETED_INDEX`, and `table_len` keeps reporting the full row span including holes. `resume_packing` packs every table that accumulated holes. You can also call `ecs.pack(&table)` on an individual table mid-pause (holes do not free capacity until packed).

### Pause scope: Database, Table, or Group

`pause_packing`/`resume_packing`/`pack` work at three levels:

- **Database** (`ecs.pause_packing(&my_ecs)`, above) — pauses every table in the database.
- **Table** (`ecs.pause_packing(&monsters)`) — pauses just that one table (`Table`, `Compact_Table`, `Tiny_Table`, or `Tag_Table`), independent of the database-wide flag. Rejected with `ecs.API_Error.Cannot_Pause_Table_Owned_By_Group` if the table belongs to a `Group` — pause the group instead (see [group.md](group.md)).
- **Group** (`ecs.pause_packing(&my_group)`) — pauses every table the group owns, as one atomic unit, since a group's owned tables must move rows in lock-step.

Use table- or group-level pause to isolate one table (or one group) from a concurrent database-wide pause/resume — e.g. one thread mutates/iterates `&monsters` under a table-level pause while another thread runs a database-wide `pause_packing`/`resume_packing` cycle over unrelated tables. The scopes compose (OR together): a database-wide `resume_packing` still packs every table, but does not forcibly clear a table's or group's own independent pause.

## Utilities

```odin
ecs.is_valid(&my_ecs)       // is the database initialized and in a Normal state?
ecs.memory_usage(&my_ecs)   // total bytes used by the database, all tables and all views
```

## Error handling

Most procedures return `ecs.Error`, a union of `API_Error` (ECS-level failures such as `Entity_Id_Expired` or `Container_Is_Full`), core-library errors, and `runtime.Allocator_Error`. They compose with `or_return`:

```odin
setup :: proc(db: ^ecs.Database) -> ecs.Error {
    ecs.init(db, entities_cap = 1000) or_return
    ecs.table_init(&positions, db, 1000) or_return
    return nil
}
```

Parameter/state validation (nil checks, initialization-state checks) is done with asserts guarded by the `ECS_VALIDATIONS` define (default `true`). Build with `-define:ECS_VALIDATIONS=false` for a slight speed gain in release builds.

## Compile-time configuration

| Define | Default | Meaning |
|---|---|---|
| `ECS_VALIDATIONS` | `true` | Assert-based parameter/state validation |
| `ECS_TABLES_MULT` | `1` | Max component types = `128 * ECS_TABLES_MULT` |
| `ECS_VIEWS_CAP` | `TABLES_CAP` | Max number of views |

Example: `odin build . -define:ECS_TABLES_MULT=2` allows 256 component types.

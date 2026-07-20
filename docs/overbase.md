# Overbase

An **`Overbase`** is a shareable entity ID space. Normally every [`Database`](database.md) owns its own, private entity IDs. Sometimes you want two or more Databases to refer to the *same* logical entities — e.g. a `world_ecs` (gameplay components) and a `render_ecs` (rendering components) that both need to talk about "robot #42" — without merging their component tables together. Attaching multiple Databases to one `Overbase` does exactly that: the same `entity_id` is valid, and means the same thing, in every Database attached to it.

See also: [Database](database.md) · [Tables](tables.md) · [Views](view.md)

## Initialization

You don't need to touch `Overbase` at all for a single, independent database — `ecs.init` already creates and owns one internally, exactly as before:

```odin
my_ecs: ecs.Database
ecs.init(&my_ecs, entities_cap = 100)
defer ecs.terminate(&my_ecs)
```

To share entities, create an `Overbase` explicitly and attach Databases to it with `init_from_overbase` instead of `init`:

```odin
overbase: ecs.Overbase
ecs.overbase_init(&overbase, entities_cap = 1000, databases_cap = 2)
defer ecs.overbase_terminate(&overbase)

world_ecs, render_ecs: ecs.Database
defer ecs.terminate(&render_ecs)
defer ecs.terminate(&world_ecs)

ecs.init_from_overbase(&world_ecs, &overbase)
ecs.init_from_overbase(&render_ecs, &overbase)
```

`databases_cap` is the maximum number of Databases that can attach to this Overbase — like every other capacity in ODE_ECS, it's preallocated up front (defaults to `1`, the size needed for the common single-owner case). `init_from_overbase` fails with `oc.Core_Error.Container_Is_Full` if you try to attach more Databases than that.

By default a Database attached this way uses the Overbase's own allocator for its tables/views/groups. Pass one explicitly to override it:

```odin
ecs.init_from_overbase(&render_ecs, &overbase, my_allocator)
```

### Termination order

A Database terminated with `ecs.terminate` never terminates a shared Overbase — you own its lifetime separately. But every Database attached to an Overbase must be terminated *before* the Overbase itself (`overbase_terminate` asserts this). Since `defer` runs LIFO, declare the `overbase_terminate` defer *first*, so it executes *last*:

```odin
defer ecs.overbase_terminate(&overbase) // declared first -> runs last
defer ecs.terminate(&render_ecs)
defer ecs.terminate(&world_ecs)
```

## Entity lifecycle is controlled by Overbase

Entity creation and destruction are owned entirely by `Overbase`, even for a plain `ecs.init`-created Database (it just owns a private one under the hood). `create_entity`/`destroy_entity` (and `is_expired`/`entities_len`/`get_entity`) accept either a `^Database` or a `^Overbase`:

```odin
robot, _ := ecs.create_entity(&overbase)   // not attached to any Database's components yet
// or equivalently, since world_ecs shares `overbase`:
robot, _ = ecs.create_entity(&world_ecs)
```

The important guarantee: **destroying an entity through *any* Database (or the Overbase directly) removes its components from *every* Database attached to that Overbase**, not just the one you called it on:

```odin
pos, _ := ecs.add_component(&positions, robot)   // world_ecs
spr, _ := ecs.add_component(&sprites, robot)      // render_ecs

ecs.destroy_entity(&world_ecs, robot)             // destroy through world_ecs...

ecs.has_component(&sprites, robot) // false — render_ecs was cleaned up too
```

This matters because entity indices are recycled: without this guarantee, a Database that was never told an entity died could keep stale component data mapped to that index, which would silently resurface under a completely unrelated new entity once the index is reused. `destroy_children` works the same way — descendants discovered through any attached Database's [Relations_Table](relations.md) are fully destroyed (id freed, components removed everywhere) before the id_factory recycles their index.

## Clearing

`ecs.clear` only resets the id space (bumping generations so held-over IDs expire) when called on a Database that **owns** its Overbase — for a Database attached via `init_from_overbase`, `clear` wipes that Database's own tables/views/relations but leaves the shared Overbase's entity IDs untouched, since bumping them would invalidate IDs still valid for sibling Databases. Clear (or terminate) every attached Database, then use `ecs.clear`/re-init on the Overbase itself if you need to reset the whole shared id space.

## Serialization

A Database's own [binary snapshot](/README.md#-saving-and-loading-snapshots) (`ecs.serialize`/`ecs.deserialize`) captures its tables *and*, when it **owns** its Overbase (the common case — a plain `ecs.init`-created Database), the entity-id state (generations, freed list) too — exactly as before.

A Database attached to a **shared** Overbase instead snapshots *only its own tables* — `serialize` omits the entity-id section entirely, and `deserialize` never touches the shared Overbase, no matter what a loaded buffer contains. This is automatic: it's decided by whether the Database owns its Overbase, not by a flag you pass. Row `entity_id`s in such a snapshot are validated against the Overbase's *live* state at load time instead of the snapshot's own recorded state — so `deserialize` correctly rejects a buffer with `Snapshot_Invalid` if it references an entity that no longer matches the live id-space (e.g. it was destroyed and its index recycled since the snapshot was taken), rather than silently writing stale data back under the wrong entity.

To save and restore the shared id-space itself, use `Overbase`'s own snapshot functions — independent of which, or how many, Databases are attached (the attached-Database list is runtime-only and is never part of either format):

```odin
size, _ := ecs.overbase_serialized_size(&overbase)
buf := make([]byte, size)
ecs.overbase_serialize(&overbase, buf)
// ... later, into an Overbase already init'd with cap >= the saved cap ...
ecs.overbase_deserialize(&overbase, buf)

// or to/from a file:
ecs.overbase_save_to_file(&overbase, "world.overbase.snap")
ecs.overbase_load_from_file(&overbase, "world.overbase.snap")
```

**Restore order matters**: when restoring a full shared setup, call `overbase_deserialize` *before* deserializing any attached Database — a Database's own rows are validated against whatever id-space is live at that moment, so restoring the shared id-space first is what makes its entities valid again for the Databases' own `deserialize` calls that follow:

```odin
ecs.overbase_deserialize(&overbase, buf_overbase) // shared id-space first
ecs.deserialize(&world_ecs, buf_world)             // then each attached Database
ecs.deserialize(&render_ecs, buf_render)
```

See [sample13](/samples/sample13/main.odin) for a complete two-Database save/restore example.

## Utilities

```odin
ecs.is_valid(&overbase)       // is the overbase initialized and in a Normal state?
ecs.memory_usage(&overbase)   // total bytes used by the overbase (id factory + attached-database list)
```

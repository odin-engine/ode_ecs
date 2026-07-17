# Relations (parent/child)

`Relations_Table` is an optional table that adds **parent/child relations** between entities: every entity can have at most one parent and any number of children. Typical uses: transform hierarchies, inventories, squads, attachments.

Like everything else in ODE_ECS, all memory is preallocated at init, and set/remove/re-parent are all **O(1)** (intrusive linked-tree arrays indexed by `eid.ix` — direct array accesses, no hashing).

At most **one** `Relations_Table` per [Database](database.md) (a second `relations_table__init` returns `Relations_Table_Already_Exists`).

> **NOTE:** Relations are *not* components — they never affect [Views](view.md). If you need to iterate "all entities that have a parent", pair relations with a [Tag_Table](tables.md#tag_table) you tag on `set_parent`.

## Setup

```odin
import ecs "ode_ecs"

my_ecs: ecs.Database
rt:     ecs.Relations_Table

ecs.init(&my_ecs, entities_cap = 1000)

// cap = max number of concurrent parent links (child→parent edges),
// must be <= entities_cap
ecs.relations_table__init(&rt, &my_ecs, cap = 500)
```

The table is terminated automatically with the database. Memory cost: `entities_cap * 36` bytes + `cap * 8` bytes.

Once initialized, all relation operations go through **database-level procedures**. Calling them before `relations_table__init` returns `API_Error.Relations_Table_Not_Created`.

## Linking and unlinking

```odin
squad,   _ := ecs.create_entity(&my_ecs)
soldier, _ := ecs.create_entity(&my_ecs)

// Make `squad` the parent of `soldier`
ecs.set_parent(&my_ecs, soldier, squad)

// Re-parenting is in place — just call set_parent again;
// the previous link is replaced (O(1))
other_squad, _ := ecs.create_entity(&my_ecs)
ecs.set_parent(&my_ecs, soldier, other_squad)

// Remove the link (alias: ecs.unparent)
ecs.remove_parent(&my_ecs, soldier)   // Not_Found if soldier has no parent
```

`set_parent` errors:

- `Relation_Cycle` — `child == parent`, or the link would make an entity its own ancestor. The check walks the new parent's ancestor chain (O(tree depth)) **before** any mutation, so nothing changes on failure.
- `Container_Is_Full` — creating a **new** link would exceed `cap`. Re-parenting an already-linked child always succeeds.
- `Entity_Id_Expired` / `Entity_Id_Out_of_Bounds` — stale or invalid entity IDs.

## Queries

```odin
p, _   := ecs.parent_of(&my_ecs, soldier)      // parent id, or p.ix == ecs.DELETED_INDEX if none
kids, _ := ecs.children_of(&my_ecs, squad)     // []entity_id — use immediately, see note below
n, _    := ecs.children_count(&my_ecs, squad)

yes, _ := ecs.is_child_of(&my_ecs, soldier, squad)     // is `soldier` a child of `squad`?
yes, _  = ecs.is_parent_of(&my_ecs, squad, soldier)    // is `squad` the parent of `soldier`?
yes, _  = ecs.has_relations(&my_ecs, soldier)          // does it have a parent or any children?
yes, _  = ecs.is_relation_of(&my_ecs, squad, soldier)  // direct link in either direction
```

Checking for "no parent":

```odin
p, _ := ecs.parent_of(&my_ecs, eid)
if p.ix == ecs.DELETED_INDEX {
    // eid is a root (no parent)
}
```

> **NOTE:** The slice returned by `children_of` points into an internal preallocated scratch buffer. It is valid only until the next `children_of` call or any structural change (`set_parent` / `remove_parent` / `destroy_entity` / `clear`) — use it immediately, do not store it and do not mutate relations while walking it. Copy it first if you need to.

## Automatic cleanup on destroy

`destroy_entity` keeps relations consistent — every `entity_id` stored in the relations table is always alive:

```odin
// Default: unlink from parent, ORPHAN the children (their parent link is cleared)
ecs.destroy_entity(&my_ecs, squad)

// Cascade: destroy the entity AND all of its descendants
ecs.destroy_entity(&my_ecs, squad, destroy_children = true)
```

The cascade is iterative (no recursion, uses the preallocated scratch buffer) and destroys the deepest entities first; each destroyed entity is removed from all its component tables as usual. Without a `Relations_Table`, `destroy_children = true` is a harmless no-op.

## Complete example

```odin
Transform :: struct { x, y: f32 }

my_ecs:     ecs.Database
rt:         ecs.Relations_Table
transforms: ecs.Table(Transform)

main :: proc() {
    defer ecs.terminate(&my_ecs)
    ecs.init(&my_ecs, entities_cap = 100)
    ecs.relations_table__init(&rt, &my_ecs, cap = 100)
    ecs.table_init(&transforms, &my_ecs, 100)

    ship, _    := ecs.create_entity(&my_ecs)
    turret1, _ := ecs.create_entity(&my_ecs)
    turret2, _ := ecs.create_entity(&my_ecs)

    for eid in ([]ecs.entity_id{ship, turret1, turret2}) {
        t, _ := ecs.add_component(&transforms, eid)
        t^ = { 10, 20 }
    }

    ecs.set_parent(&my_ecs, turret1, ship)
    ecs.set_parent(&my_ecs, turret2, ship)

    // Move all direct children of the ship
    kids, _ := ecs.children_of(&my_ecs, ship)
    for kid in kids {
        t := ecs.get_component(&transforms, kid)
        t.x += 5
    }

    // Ship explodes — turrets go with it
    ecs.destroy_entity(&my_ecs, ship, destroy_children = true)

    ecs.is_expired(&my_ecs, turret1) // true
}
```

## Other operations

```odin
ecs.table_len(&rt)        // current number of parent links
ecs.table_cap(&rt)        // cap (max concurrent links)
ecs.clear(&rt)            // remove ALL relations (entities themselves are untouched)
ecs.memory_usage(&rt)     // bytes
ecs.is_valid(&rt)
```

Tests with more usage patterns: [tests/relations_table_test.odin](../tests/relations_table_test.odin).

# `Any_Table` (type-erased table handle)

`Any_Table` is a handle to *any* table variant — [`Table(T)`](tables.md), `Compact_Table(T)`, `Tiny_Table(T)`, `Tag_Table`, [`Arch_Table`](arch_table.md) — for code that has to work with tables whose component type isn't known at compile time: data-driven loaders, serializers, inspectors, debug dumps, CLI tools.

Gameplay should keep using `^Table(Mass)` and `get_component(&mass, eid)`. Reach for `Any_Table` only where the type genuinely isn't known until runtime.

```odin
import ecs "ode_ecs"

positions: ecs.Table(Position)
ecs.table_init(&positions, &my_ecs, 1000)

a := ecs.any_table(&positions)
```

`any_table` accepts every table variant, because they all embed the same header. It is the public spelling of the pointer [`view_init`](view.md) and [`group_init`](group.md) already take, so these speak the same currency:

```odin
ecs.view_init(&view, &my_ecs, includes = {&positions})
a := ecs.any_table(&positions)
```

Converting is free — `Any_Table` is a pointer, not a wrapper object. Each *operation* costs one switch on the table type.

> **NOTE:** This erases the **table variant**. That is a different thing from what the internal `Table_Raw` does (erase the component type `T` within a variant that is already known, for free, via a same-layout cast). The procedures below are built on those.

## Metadata

```odin
ecs.any_table_id(a)              // table_id — see the two-registry note below
ecs.any_table_type(a)            // Table_Type.Table / .Compact_Table / .Tiny_Table / .Tag_Table / .Arch_Table
ecs.any_table_component_type(a)  // typeid; nil for Tag_Table (no data) and Arch_Table (many types per row)
ecs.any_table_component_size(a)  // bytes; 0 for Tag_Table
ecs.any_table_len(a)
ecs.any_table_cap(a)
ecs.any_table_is_valid(a)
ecs.any_table_memory_usage(a)
```

An `Arch_Table` row spans several component types, so it answers through the column procs instead:

```odin
n := ecs.any_table_column_count(a)     // 0 for Tag_Table, N for Arch_Table, 1 otherwise
for col in 0..<n {
    t := ecs.any_table_column_type(a, col)
}
```

This is what lets a loader match a KDL property name to a registered table:

```odin
by_name: map[string]ecs.Any_Table
by_name["mass"] = ecs.any_table(&masses)
```

## Rows

```odin
ecs.any_table_has_component(a, eid)          // the real membership answer for every variant
ecs.any_table_get_component(a, eid)          // rawptr; nil for a Tag_Table or an absent row
ecs.any_table_add_component(a, eid, data)    // data may be nil to add a zeroed row
ecs.any_table_remove_component(a, eid)
ecs.any_table_clear(a)

ecs.any_table_entities_slice(a)              // []entity_id, row order
ecs.any_table_get_entity(a, row_number)
```

For a `Tag_Table`, `any_table_add_component` tags the entity and `any_table_remove_component` untags it; `any_table_get_component` is always nil, so use `any_table_has_component` for membership.

> **UNSAFE:** `data` is an untyped pointer the caller promises matches `any_table_component_type(a)`. Nothing checks it. This is a tooling path — never put it in a frame loop.

## Enumeration

```odin
buf: [64]ecs.Any_Table

all, _ := ecs.any_tables(&my_ecs, buf[:])   // every attached table: component tables, then tag tables
n      := ecs.any_tables_len(&my_ecs)
```

`any_tables` fills a caller-provided buffer so it allocates nothing; a buffer too small to hold them all returns `Container_Is_Full` along with the ones that fit.

> **NOTE:** Component tables and tag tables live in **two independent registries** with independent id spaces — the same `table_id` value can name a component table *and* a tag table. A `table_id` therefore only identifies a table together with its `Table_Type`, which is why `any_table_by_id` takes both:

```odin
a, ok := ecs.any_table_by_id(&my_ecs, id, ecs.Table_Type.Table)
a, ok  = ecs.any_table_by_id(&my_ecs, id, ecs.Table_Type.Tag_Table)
```

## What is this entity made of?

```odin
buf: [64]ecs.Any_Table
tables, _ := ecs.entity_tables(&my_ecs, guard42, buf[:])

for a in tables {
    // a is a table guard42 currently has a row (or tag) in
}
```

Walks the entity's internal membership bitsets, so it costs O(#tables the entity is in), not O(#tables). It reports component tables and tag tables both, and includes disabled components — a disabled component still has its data. Allocation-free, same caller-buffer contract as `any_tables`.

## Cloning a component between entities

```odin
ecs.any_table_clone_component(a, archetype, instance)
```

Copies one entity's row onto another entity **within the same table** — the direction prototype/prefab instantiation needs. (The typed [`clone_component`](tables.md#cloning-a-component-between-entities) is the same operation with the type known; `copy_component` is the *other* direction, one entity across two tables.)

For a `Tag_Table`, tagging the destination is the whole job. `Arch_Table` returns `API_Error.Table_Type_Not_Supported` — a row spans several columns there, so use `copy`/`move` from [Arch_Table](arch_table.md) instead.

Together with `entity_tables`, that is a complete data-driven instantiate:

```odin
tables, _ := ecs.entity_tables(&config_db, archetype, buf[:])
for a in tables {
    ecs.any_table_clone_component(a, archetype, instance)
}
```

Tests: [tests/any_table_test.odin](../tests/any_table_test.odin).

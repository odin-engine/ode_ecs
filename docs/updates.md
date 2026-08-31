# 🐑 Updates Timeline

**August 2026**
- ** BREAKABLE CHANGE ** - sorry, moved source code to src/ folder to declutter root folder. Now you need to `import ecs "ode_ecs/src"` instead of `import ecs "ode_ecs"`.
- Internally separate component types and tags.
- **new** •  `slice(&view, &table)` — an opt-in dense fast path: hands back a `Table`'s real `[]T`
  rows directly (no per-row pointer-cache indirection) when that table happens to be aligned to
  the view's row order, `nil` otherwise. Restores, as a `slice()` overload, the fast path
  `Iterator` used to reach internally via its own alignment check; see
  [View: Opt-in dense fast path](/docs/view.md#opt-in-dense-fast-path-slice-view-table).
- **new** •  `entities_slice(&table)` now works on `Table`/`Compact_Table`/`Tiny_Table`/`Tag_Table` too (already existed for `View` and `Arch_Table`) — row-aligned with `slice(&table)`, so a table can be iterated the same zipped way as a `View`, without a `get_entity(&table, index)` lookup per row.
- **new** •  `Arch_Table` iteration now matches View's idiom: `arch_table__dense_slice` renamed to `arch_table__column_slice`, and a new `arch_table__entities_slice` was added — both wired into the `slice()` proc group, so `slice(&arch)` + `slice(&arch, T)` is the recommended way to iterate an archetype directly. 
- **new** •  Every component of an `Arch_Table` mixed into a `View` is now automatically available through `slice(&view, T)`/`entities_slice(&view)` — `view_init` caches a real pointer per row for each of the archetype's component types (its set never changes after `arch_table__init`, so there's nothing to opt into later, no separate call needed).
- `Iterator` demoted to back-compat status — `slice(&view, T)` + `entities_slice(&view)` is now the recommended way to iterate a View's columns; see [Iterator (back-compat)](/docs/view.md#iterator-back-compat).
- View's row storage now stores direct component pointers (kept correct on every tail-swap) instead of row-ids for `Table`/`Compact_Table`/`Tiny_Table` columns — faster `get_component` off the Iterator's dense fast path, at a small extra memory/churn cost.
- **new** •  [Observers](/docs/observers.md) (`Observer`) — structural-change callbacks.
- `Command_Buffer` is now auto-terminated by `database__terminate`.
- **new** •  [Pairs](/docs/pair_table.md) (`Pair_Table(T)`) — many-to-many relations that, unlike `Relations_Table`, participate in `View` matching via an embedded `Tag_Table`.
- **new** •  [Relations hierarchy walk](/docs/relations.md#hierarchy-walk) — read-only parent-before-child traversal. See [Sample15](/samples/sample15/main.odin).
- Bump gen in ix_gen to 32 bits.
- **new** •  [Fat Struct discussion](/docs/fat_struct_vs_ecs.md) and samples.
- Allow autogrow (Database, Tables, Views) during the init stage, not the frame loop.

**July 2026**
- **new** •  Component `enable_component`/`disable_component` — a soft, bitset-based toggle that excludes a component from View matching without moving or losing its data; see [Tables](tables.md#component-enable-disable).
- **new** •  View `any_of` — structural OR, completing the AND (`includes`) / NOT (`excludes`) / OR (`any_of`) query combinators; see [View](view.md#any_of-or).
- **new** •  [Arch_Table](arch_table.md) feature - archetype-style (SoA) tables, with full `View`, `Group`, `Command_Buffer` and snapshot-serialization support alongside regular Tables; see [Archetype vs. Sparse-Dense ECS](ecs_types.md).
- **new** •  Unified `next()` iteration sugar - one proc group covering both `Iterator` and `Arch_Iterator`, 0 to 7 typed components per call; replaces `iterator_next`/`iterate`.
- **new** •  [Overbase](overbase.md) feature - share one entity ID space across multiple Databases.
- **new** •  [Pause packing](/README.md#mutating-tables-while-iterating-pause_packing--resume_packing--pack) feature - deferred-tail-swap mode.
- **new** •  [Groups](group.md) feature - the fastest way to iterate entities that have a specific set of components.
- **new** •  [Relations_Table](relations.md) feature - parent/child entity relations.
- **new** •  [Command buffers](command_buffer.md) - defer the structural changes.
- **new** •  [Saving and loading (snapshots)](serialization.md) - database serialization.
- **new** •  View `excludes` — `view_init(..., excludes = {&table})`, `refilter(&view)` feature.
- **new** •  +8 new samples, including [Sample14](/samples/sample14/main.odin) (Arch_Table, mixed into a View and a Group).
- **new** •  Added a dense (aligned) path optimization for Views (~2x speed increase if aligned).
- **new** •  View filter rerun path optimized: each re-evaluated row is now filled once instead of twice.
- Reduced memory footprint and faster structural churn across `Table`, `Compact_Table`, `Tiny_Table`, `Tag_Table` and `View`.
- Improvements, polishing and bug fixes.
- More tests.
- Improved README and docs.

**v1.2.2**
- Added new procedures: `view__rerun_filter` and `table__rerun_views_filters`.
- Renamed configuration variables — `ecs_validation` → `ECS_VALIDATIONS`, `ecs_tables_mult` → `ECS_TABLES_MULT`, and `ecs_views_cap` → `ECS_VIEWS_CAP` — to comply with Odin naming standards.
- Updated sample06
- More tests related to View filters

**v1.2.1**
- **new** •  [Tag_Table](tables.md) – used when you only want to tag an entity; can be useful with views.
- **new** •  View filter – an additional way to filter entities for a View.
- Iterator bug fix 
- Improved object validation.
- **new** •  sample06

**v1.2.0**
- **new** •  Compact_Table - compact version of Table (less memory usage but slower)
- **new** •  Tiny_Table - table on stack
- **new** •  sample04 - Tiny_Table usage
- **new** •  sample05 - Tiny_Table, Table and Compact_Table comparison

**v1.1.2**
- Table update

**v1.1.1**
- sample03 implemented (comparison between the Archetype and View approaches)
- small updates to Iterator for a slight speed improvement.
- a small update to View
- small updates to other samples

**v1.1.0**
- View rework, making it ~25% faster.

# 🐑 Updates Timeline

**September 2026**
- **new** •  [Flags_Table](/docs/flags_table.md) — up to 128 flags per entity, stored as a `Compact_Table(Bits)`. `flag`/`unflag`/`has_flag` (also `tag`/`untag`/`has_tag` with a bit), with integer bits or enums. Views filter on flags with `Flags` terms and a `Flags_Op` (`And`, `Or`, `Xor`, `Nor`, `Nand`, `Exact`); `&status` alone means "has any flag". Works with Command_Buffer (`cmd_flag`), Observers (`Flags_Changed`), snapshots, Sync and `pause_packing`/`resume_packing`/`pack`. `Bits` is now public.
- **new** •  [`View_Term`](/docs/view.md#pair-tables) — `view_init`'s `includes`/`excludes`/`any_of` now take `[]View_Term`, so a `Pair_Table` can be passed directly: `includes = {&positions, &likes}` means "has Position and at least one pair". Every existing call compiles unchanged; `&likes.presence` still works.
- **new** •  [Any_Table](/docs/any_table.md) — a type-erased handle to any table variant, for data-driven loaders, inspectors and serializers. It is the public spelling of the pointer `view_init`/`group_init` already take, so `any_table(&positions)` and `view_init(includes = {&positions})` use the same currency. Comes with `any_tables`/`any_table_by_id` enumeration and `entity_tables` ("what is this entity made of?").
- **new** •  `clone_component` — copies a component between two **entities** within one table (`copy_component` copies one entity's component between two **tables**). Prototype/prefab instantiation wants this direction. `any_table_clone_component` is the type-erased form, so a baker can clone every component of a template entity without knowing any of their types.
- **new** •  [Inherited lookup](/docs/relations.md#inherited-lookup) — `get_component_up`/`has_tag_up` walk an entity's parent chain and return the first owner plus the entity the value came from; `find_up` is the general primitive. The relations-owning `Database` is passed explicitly, so the table and the hierarchy can live in different Databases sharing one `Overbase`.
- **new** •  [Upward hierarchy traversal](/docs/relations.md#upward-traversal) — `ancestors_of`, `root_of`, `depth_of`, `is_ancestor_of`, `is_descendant_of`. Complements the existing downward `children_of`/`walk_subtree`/`walk_hierarchy`; unlike `is_child_of`, `is_ancestor_of` is not limited to a direct link.
- `Pair_Row_Id` is renamed to `pair_row_id`, matching every other id type, and is now `distinct i32` (was `distinct int`), halving a `Pair_Table`'s fixed per-entity index cost. Matters when you keep one `Pair_Table` per relation flavor; see [Pairs](/docs/pair_table.md).
- **new** •  [Pair row cursor](/docs/pair_table.md#row-cursor) — `pair_first_row_of`/`pair_next_row_of` and `pair_first_row_to`/`pair_next_row_to` walk every pair row in either direction, with `pair_row_holder`/`pair_row_target`/`pair_row_data` reading the row. Previously only a holder's head row could be reached (`pair_first_data`).
- **new** •  `pair_holders_of` — the reverse of `pair_targets_of` ("who points at this?"), O(#pairs for that target), on its own scratch buffer so the two sides do not clobber each other. Plus `pair_get_data`, `pair_count_of`, `pair_count_to` and `pair_remove_all_to`.

**August 2026**
- ** BREAKABLE CHANGE ** - sorry, moved source code to src/ folder to declutter root folder. Now you need to `import ecs "ode_ecs/src"` instead of `import ecs "ode_ecs"`.
- More updates to Arch_Table (move, copy, sudo_move, sudo_copy). 
- API polishing.
- Internally separate component types and tags.
- **new** •  `slice(&view, &table)` — an opt-in dense fast path: hands back a `Table`'s real `[]T`
  rows directly (no per-row pointer-cache indirection) when that table happens to be aligned to
  the view's row order, `nil` otherwise. Restores, as a `slice()` overload, the fast path
- **new** •  `entities_slice(&table)` now works on `Table`/`Compact_Table`/`Tiny_Table`/`Tag_Table` too (already existed for `View` and `Arch_Table`) — row-aligned with `slice(&table)`, so a table can be iterated the same zipped way as a `View`, without a `get_entity(&table, index)` lookup per row.
-  `Arch_Table` iteration now matches View's idiom: `arch_table__dense_slice` renamed to `arch_table__column_slice`, and a new `arch_table__entities_slice` was added — both wired into the `slice()` proc group, so `slice(&arch)` + `slice(&arch, T)` is the recommended way to iterate an archetype directly. 
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

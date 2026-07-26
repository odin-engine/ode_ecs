# 🐑 Updates Timeline

**July 2026**
* \*new\* View `any_of` — structural OR, completing the AND (`includes`) / NOT (`excludes`) / OR (`any_of`) query combinators; see [View](view.md#any_of-or).
* \*new\* [Arch_Table](arch_table.md) feature - archetype-style (SoA) tables, with full `View`, `Group`, `Command_Buffer` and snapshot-serialization support alongside regular Tables; see [Archetype vs. Sparse-Dense ECS](ecs_types.md).
* \*new\* Unified `next()` iteration sugar - one proc group covering both `Iterator` and `Arch_Iterator`, 0 to 7 typed components per call; replaces `iterator_next`/`iterate`.
* \*new\* [Overbase](overbase.md) feature - share one entity ID space across multiple Databases.
* \*new\* [Pause packing](/README.md#mutating-tables-while-iterating-pause_packing--resume_packing--pack) feature - deferred-tail-swap mode.
* \*new\* [Groups](group.md) feature -  the fastest way to iterate entities that have a specific set of components.
* \*new\* [Relations_Table](relations.md) feature - parent/child entity relations.
* \*new\* [Command buffers](command_buffer.md) - defer the structural changes.
* \*new\* [Saving and loading (snapshots)](serialization.md) - database serialization.
* \*new\* View `excludes` — `view_init(..., excludes = {&table})`, `refilter(&view)` feature.
* \*new\* +8 new samples, including [Sample14](/samples/sample14/main.odin) (Arch_Table, mixed into a View and a Group).
* \*new\* Added a dense (aligned) path optimization for Views (~2x speed increase if aligned).
* \*new\* View filter rerun path optimized: each re-evaluated row is now filled once instead of twice.
* Reduced memory footprint and faster structural churn across `Table`, `Compact_Table`, `Tiny_Table`, `Tag_Table` and `View`.
* Improvements, polishing and bug fixes.
* More tests. 
* Improved README and docs.

**v1.2.2**
* Added new procedures: `view__rerun_filter` and `table__rerun_views_filters`.
* Renamed configuration variables — `ecs_validation` → `ECS_VALIDATIONS`, `ecs_tables_mult` → `ECS_TABLES_MULT`, and `ecs_views_cap` → `ECS_VIEWS_CAP` — to comply with Odin naming standards.
* Updated sample06 
* More tests related to View filters

**v1.2.1**
- \*new\* **[Tag_Table](tables.md)** – used when you only want to tag an entity; can be useful with views.
- \*new\* **View filter** – an additional way to filter entities for a View.
- **Iterator bug fix** 
- **Improved object validation**.
- \*new\* sample06

**v1.2.0**
- \*new\* Compact_Table - compact version of Table (less memory usage but slower)
- \*new\* Tiny_Table - table on stack
- \*new\* sample04 - Tiny_Table usage
- \*new\* sample05 - Tiny_Table, Table and Compact_Table comparison

**v1.1.2**
- Table update

**v1.1.1**
- sample03 implemented (comparison between Archetype and View approach)
- small updates to Iterator to improve speed a little
- a small update to View
- small updates to other samples

**v1.1.0**
- View rework, made it ~25% faster

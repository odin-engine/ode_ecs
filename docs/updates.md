# Updates Timeline

**July 2026**
* \*new\* View `excludes` — `view_init(..., excludes = {&table})` keeps entities that have a component in **none** of the excluded tables ("has A, not B"), auto-maintained, no filter proc needed. Works with every table variant.
* \*new\* `refilter(&view)` — re-evaluates a view's filter for all rows and candidates in one sweep after bulk mutations (cheaper than `rebuild`: no clear, surviving rows stay put).
* \*new\* `rerun_views_filters` proc group (over the per-table-variant procs).
* View filter rerun path optimized: each re-evaluated row is now filled once instead of twice.
* \*new\* [Groups](group.md)
* \*new\* Defer tail-swap feature (pause_packing/resume_packing/pack) ([Database](database.md), [Group](group.md) and [Table](tables.md) levels).
* \*new\* [Relations_Table](relations.md) (parent/child entity relations) feature.
* \*new\* Command buffers.
* \*new\* Saving and loading (snapshots).
* Added a dense (aligned) path optimization for Views (~2x speed increase if the view and tables are aligned).
* Micro-optimizations.
* Improvements and bug fixes.

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

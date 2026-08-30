# API Reference

The full public ODE_ECS surface, grouped by object. This is a flat reference — for narrative
explanations and examples see [Database](database.md), [Tables](tables.md),
[Arch_Table](arch_table.md), [View](view.md), [Group](group.md), [Overbase](overbase.md),
[Command_Buffer](command_buffer.md), [Observers](observers.md), [Relations](relations.md),
[Pairs](pair_table.md) and [Serialization](serialization.md).

Every name below is a public alias or proc-group entry defined in
[`/src/ecs.odin`](/src/ecs.odin) — the only file you need to import from (`import ecs "ode_ecs/src"`).
A `proc group` note means the short name is overloaded across several object types; the compiler
picks the match by argument types. Signatures drop `loc := #caller_location` (present on most
procedures purely for better assert/error messages) and other implementation-only attributes for
brevity.

All procedures take their object by pointer (`self: ^Database`, `self: ^Table($T)`, ...) as the
first argument, shown here as `self`.

---

## Database

The "world" object — owns entities, tables, views, and (optionally) a relations table, pair
tables, command buffers, sync channels, and observers. See [Database](database.md).

```odin
init(self, entities_cap: u32, allocator := context.allocator,
     tables_cap: int = TABLES_CAP, views_cap: int = VIEWS_CAP, tiny_tables_cap: int = TINY_TABLES_CAP,
     pair_tables_cap: int = PAIR_TABLES_CAP, command_buffers_cap: int = COMMAND_BUFFERS_CAP,
     observers_cap: int = OBSERVERS_CAP) -> Error
init_from_overbase(self, overbase: ^Overbase, allocator: Maybe(runtime.Allocator) = nil,
     tables_cap := TABLES_CAP, views_cap := VIEWS_CAP, tiny_tables_cap := TINY_TABLES_CAP,
     pair_tables_cap := PAIR_TABLES_CAP, command_buffers_cap := COMMAND_BUFFERS_CAP,
     observers_cap := OBSERVERS_CAP) -> Error
terminate(self) -> Error
clear(self) -> Error   // proc group: also every table type, View, Relations_Table, Command_Buffer, Sync_Channel

create_entity(self) -> (entity_id, Error)                 // proc group: also Overbase, Arch_Table
destroy_entity(self, eid: entity_id, destroy_children := false) -> Error  // proc group: also Overbase
get_entity(self, index: int) -> entity_id                 // proc group: also Overbase, every table type (by row number), Iterator, View_Row
entities_len(self) -> int                                 // proc group: also Overbase
is_expired(self, eid: entity_id) -> bool                  // proc group: also Overbase

pause_tail_swap(self)
resume_tail_swap(self) -> Error
pause_packing(self)                 // proc group: also every table type, Group (same underlying call as pause_tail_swap)
resume_packing(self) -> Error       // proc group: also every table type, Group (same underlying call as resume_tail_swap)

memory_usage(self) -> int   // proc group: also every other object
is_valid(self) -> bool      // proc group: also every other object
```

### Relations shortcuts (require a `Relations_Table`, see [Relations](relations.md))

These take `self: ^Database` and forward into the database's attached `Relations_Table`.
`relations_init`/`relations_terminate` take the `Relations_Table` directly.

```odin
relations_init(self: ^Relations_Table, db: ^Database, cap: int) -> Error
relations_terminate(self: ^Relations_Table) -> Error

set_parent(self: ^Database, child: entity_id, parent: entity_id) -> Error
remove_parent(self: ^Database, child: entity_id) -> Error
unparent(self: ^Database, child: entity_id) -> Error       // alias of remove_parent
parent_of(self: ^Database, eid: entity_id) -> (entity_id, Error)
children_of(self: ^Database, parent: entity_id) -> ([]entity_id, Error)
children_count(self: ^Database, eid: entity_id) -> (int, Error)
is_child_of(self: ^Database, a: entity_id, b: entity_id) -> (bool, Error)
is_parent_of(self: ^Database, a: entity_id, b: entity_id) -> (bool, Error)
has_relations(self: ^Database, eid: entity_id) -> (bool, Error)
is_relation_of(self: ^Database, target: entity_id, eid: entity_id) -> (bool, Error)

is_root(self: ^Database, eid: entity_id) -> (bool, Error)
roots(self: ^Database) -> (entities: []entity_id, err: Error)
walk_subtree(self: ^Database, root: entity_id) -> (entities: []entity_id, err: Error)
walk_hierarchy(self: ^Database) -> (entities: []entity_id, level_offsets: []int, err: Error)

table_len(self: ^Relations_Table) -> int   // proc group
table_cap(self: ^Relations_Table) -> int   // proc group
```

---

## Overbase

A shareable entity-id space: multiple `Database`s can attach to one `Overbase` so an `entity_id`
means the same logical entity across all of them. See [Overbase](overbase.md).

```odin
overbase_init(self: ^Overbase, entities_cap: u32, databases_cap := 1,
     allocator := context.allocator) -> Error
overbase_terminate(self: ^Overbase) -> Error
init_from_overbase(db: ^Database, overbase: ^Overbase, ...) -> Error   // see Database section — attaches a Database to this Overbase

create_entity(self: ^Overbase) -> (entity_id, Error)          // proc group
destroy_entity(self: ^Overbase, eid: entity_id, destroy_children := false) -> Error  // proc group
get_entity(self: ^Overbase, index: int) -> entity_id            // proc group
entities_len(self: ^Overbase) -> int                             // proc group
is_expired(self: ^Overbase, eid: entity_id) -> bool              // proc group

memory_usage(self: ^Overbase) -> int   // proc group
is_valid(self: ^Overbase) -> bool      // proc group
```

---

## Table(T)

A dense array of one component type; `eid_to_rid` is a full array sized to entity capacity. See
[Tables](tables.md).

```odin
table_init(self: ^Table($T), db: ^Database, cap: int,
     subscribers_cap: int = SUBSCRIBERS_CAP, sync_channels_cap: int = SYNC_CHANNELS_CAP) -> Error
table_terminate(self: ^Table($T)) -> Error

add_component(self: ^Table($T), eid: entity_id) -> (component: ^T, err: Error)   // proc group: also Compact_Table, Tiny_Table
remove_component(self: ^Table($T), eid: entity_id) -> Error                      // proc group: also Compact_Table, Tiny_Table, Arch_Table (whole-row remove)
rerun_views_filters(self: ^Table($T), eid: entity_id) -> Error                   // proc group: also Compact_Table, Tiny_Table

get_component(self: ^Table($T), eid: entity_id) -> ^T          // proc group
get_component_mut(self: ^Table($T), eid: entity_id) -> ^T      // proc group; like get_component, but also marks the row dirty for Sync delta collection
has_component(self: ^Table($T), eid: entity_id) -> bool        // proc group
get_entity(self: ^Table($T), row_number: int) -> entity_id     // proc group (by row number); also under the narrower get_entity_by_row_number group (Table/Compact_Table/Tiny_Table/Tag_Table/Arch_Table only)

copy_component(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error)   // proc group: also Compact_Table, Tiny_Table
move_component(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, err: Error)                      // proc group: also Compact_Table, Tiny_Table
copy(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error)             // proc group — same shape as copy_component here; also Arch_Table's whole-row copy under a different signature (see Arch_Table)
move(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, err: Error)                                // proc group — same shape as move_component here; also Arch_Table's whole-row move under a different signature (see Arch_Table)

disable_component(self: ^Table($T), eid: entity_id) -> Error          // proc group: also every other table type
enable_component(self: ^Table($T), eid: entity_id) -> Error           // proc group: also every other table type
is_component_disabled(self: ^Table($T), eid: entity_id) -> bool       // proc group: also every other table type

clear(self: ^Table($T)) -> Error                // proc group
pack(self: ^Table($T)) -> Error                 // proc group — compacts holes left by a paused tail-swap
pause_packing(self: ^Table($T)) -> Error        // proc group
resume_packing(self: ^Table($T)) -> Error       // proc group
table_len(self: ^Table($T)) -> int              // proc group
table_cap(self: ^Table($T)) -> int              // proc group

entities_slice(self: ^Table($T)) -> []entity_id     // proc group — row-order entity ids
slice(self: ^Table($T)) -> []T                      // proc group — row-order components, by value

memory_usage(self: ^Table($T)) -> int   // proc group
is_valid(self: ^Table($T)) -> bool      // proc group
```

## Compact_Table(T)

Memory-saving variant of `Table(T)` — `eid_to_rid` is a Robin Hood map instead of a full array. Use
when `cap` is small relative to entity capacity. See [Tables](tables.md). Same operations as
`Table(T)` above, all through the same proc groups:

```odin
compact_table_init(self: ^Compact_Table($T), db: ^Database, cap: int,
     subscribers_cap: int = SUBSCRIBERS_CAP, sync_channels_cap: int = SYNC_CHANNELS_CAP) -> Error
compact_table_terminate(self: ^Compact_Table($T)) -> Error

// add_component, remove_component, rerun_views_filters, get_component, get_component_mut,
// has_component, get_entity, copy_component, move_component, copy, move,
// disable_component, enable_component, is_component_disabled,
// clear, pack, pause_packing, resume_packing, table_len, table_cap,
// entities_slice, slice, memory_usage, is_valid
// — same shapes as Table(T) above, self: ^Compact_Table($T)
```

## Tiny_Table(T)

Fixed `TINY_TABLE__ROW_CAP` (8) rows stored inline in the struct — for very small tables. See
[Tables](tables.md). `init` takes no `cap` (always 8):

```odin
tiny_table_init(self: ^Tiny_Table($T), db: ^Database) -> Error
tiny_table_terminate(self: ^Tiny_Table($T)) -> Error

// add_component, remove_component, rerun_views_filters, get_component, get_component_mut,
// has_component, get_entity, copy_component, move_component, copy, move,
// disable_component, enable_component, is_component_disabled,
// clear, pack, pause_packing, resume_packing, table_len, table_cap,
// entities_slice, slice, memory_usage, is_valid
// — same shapes as Table(T) above, self: ^Tiny_Table($T)
```

## Tag_Table

Stores no component data, only "tags" entities — useful as a view filter. See
[Tables](tables.md).

```odin
tag_table_init(self: ^Tag_Table, db: ^Database, cap: int,
     sync_channels_cap: int = SYNC_CHANNELS_CAP) -> Error
tag_table_terminate(self: ^Tag_Table) -> Error

add_tag(self: ^Tag_Table, eid: entity_id) -> Error       // = tag
remove_tag(self: ^Tag_Table, eid: entity_id) -> Error    // = untag
has_tag(self: ^Tag_Table, eid: entity_id) -> bool        // also under has_component proc group
remove_component(self: ^Tag_Table, eid: entity_id) -> Error   // alias of remove_tag, for symmetry with other table types
get_entity(self: ^Tag_Table, row_number: int) -> entity_id    // proc group (by row number)

disable_component(self: ^Tag_Table, eid: entity_id) -> Error        // proc group
enable_component(self: ^Tag_Table, eid: entity_id) -> Error         // proc group
is_component_disabled(self: ^Tag_Table, eid: entity_id) -> bool     // proc group

clear(self: ^Tag_Table) -> Error                // proc group
pack(self: ^Tag_Table) -> Error                 // proc group
pause_packing(self: ^Tag_Table) -> Error        // proc group
resume_packing(self: ^Tag_Table) -> Error       // proc group
table_len(self: ^Tag_Table) -> int              // proc group
table_cap(self: ^Tag_Table) -> int              // proc group

entities_slice(self: ^Tag_Table) -> []entity_id   // proc group
slice(self: ^Tag_Table) -> []entity_id            // proc group — Tag_Table has no component data, so slice == entities_slice

memory_usage(self: ^Tag_Table) -> int   // proc group
is_valid(self: ^Tag_Table) -> bool      // proc group
```

## Arch_Table

A true-SoA archetype table: N type-erased columns sharing one row index — an entity has the whole
row or none of it. An entity can be in **at most one** `Arch_Table` at a time. See
[Arch_Table](arch_table.md).

```odin
arch_table_init(self: ^Arch_Table, db: ^Database, cap: int, component_types: []typeid,
     subscribers_cap: int = SUBSCRIBERS_CAP) -> Error
arch_table_terminate(self: ^Arch_Table) -> Error

create_entity(self: ^Arch_Table) -> (eid: entity_id, err: Error)     // proc group — creates a new entity and adds it to this table
add_entity(self: ^Arch_Table, eid: entity_id) -> Error                // proc group — adds an existing entity; fails with API_Error.Entity_Already_In_Table if it's in a different Arch_Table
remove_component(self: ^Arch_Table, eid: entity_id) -> Error          // proc group — removes the whole row for this entity

get_component(self: ^Arch_Table, eid: entity_id, $T: typeid) -> ^T             // proc group
get_component(self: ^Arch_Table, row: int, $T: typeid) -> ^T                   // proc group — by row number
has_component(self: ^Arch_Table, eid: entity_id) -> bool                       // proc group — does this entity have a row here
is_in(self: ^Arch_Table, eid: entity_id) -> bool                                // is this entity currently a member of this table
get_entity(self: ^Arch_Table, row_number: int) -> entity_id                    // proc group (by row number)

move(eid: entity_id, from: ^Arch_Table, to: ^Arch_Table) -> Error                          // `to` must be a superset of `from`'s columns
sudo_move(eid: entity_id, from: ^Arch_Table, to: ^Arch_Table) -> Error                     // drops columns `to` doesn't have, instead of erroring
copy(eid: entity_id, from: ^Arch_Table, to: ^Arch_Table) -> (new_eid: entity_id, err: Error)       // duplicates the row as a new entity; source untouched
sudo_copy(eid: entity_id, from: ^Arch_Table, to: ^Arch_Table) -> (new_eid: entity_id, err: Error)  // like copy, dropping columns `to` doesn't have

disable_component(self: ^Arch_Table, eid: entity_id) -> Error        // proc group
enable_component(self: ^Arch_Table, eid: entity_id) -> Error         // proc group
is_component_disabled(self: ^Arch_Table, eid: entity_id) -> bool     // proc group

clear(self: ^Arch_Table) -> Error                // proc group
pack(self: ^Arch_Table) -> Error                 // proc group
pause_packing(self: ^Arch_Table) -> Error        // proc group
resume_packing(self: ^Arch_Table) -> Error       // proc group
table_len(self: ^Arch_Table) -> int              // proc group
table_cap(self: ^Arch_Table) -> int              // proc group

entities_slice(self: ^Arch_Table) -> []entity_id     // proc group
slice(self: ^Arch_Table, $T: typeid) -> []T          // proc group — one column, by value

memory_usage(self: ^Arch_Table) -> int   // proc group
is_valid(self: ^Arch_Table) -> bool      // proc group
```

`cmd_arch_add_entity` (see [Command_Buffer](#command_buffer-deferred-structural-operations)) is the
deferred equivalent of `create_entity`/`add_entity` with typed values for up to 4 columns.

---

## View

Iterates entities possessing a given set of component tables, stored column-major. See
[View](view.md).

```odin
view_init(self: ^View, db: ^Database, includes: []^Shared_Table,
     excludes: []^Shared_Table = nil, any_of: []^Shared_Table = nil,
     filter: proc(row: ^View_Row, user_data: rawptr = nil) -> bool = nil) -> Error
view_terminate(self: ^View) -> Error

view_len(self: ^View) -> int
view_cap(self: ^View) -> int
clear(self: ^View) -> Error          // proc group
rebuild(self: ^View) -> Error        // full O(n) repopulation
refilter(self: ^View) -> Error       // re-evaluates the filter for every current member
rerun_filter(self: ^View, eid: entity_id) -> Error   // re-evaluates the filter for one entity
view_components_match(self: ^View, eid: entity_id) -> bool

suspend(self: ^View)   // pauses per-mutation view updates
resume(self: ^View)    // resumes them (does not itself rebuild — call rebuild if needed)

get_component(table: ^Table($T), view_row: ^View_Row) -> ^T             // proc group
get_component(table: ^Compact_Table($T), view_row: ^View_Row) -> ^T     // proc group
get_component(table: ^Tiny_Table($T), view_row: ^View_Row) -> ^T        // proc group
get_component(table: ^Arch_Table, view_row: ^View_Row, $T: typeid) -> ^T  // proc group
get_entity(view_row: ^View_Row) -> entity_id                             // proc group

view_column_slice(self: ^View, $T: typeid) -> []^T   // = slice(&view, T) — pointers to structs
view_entities_slice(self: ^View) -> []entity_id       // = slice(&view) — matching entity ids, same order as the columns
slice(self: ^View, table: ^Table($T)) -> []T          // proc group — dense slice for one included Table(T), or nil if not densely packed

memory_usage(self: ^View) -> int   // proc group
is_valid(self: ^View) -> bool      // proc group
```

`View_Row` is the per-row handle passed to a `filter` callback and returned while iterating; it
carries the current row's entity and lets you fetch any included table's component for that row via
`get_component`.

---

## Group

Takes exclusive ownership of a set of `Table`s/`Arch_Table`s and keeps their commonly-owned
entities in an aligned dense prefix across all of them. See [Group](group.md).

```odin
group_init(self: ^Group, db: ^Database, owned: []^Shared_Table) -> Error
group_terminate(self: ^Group) -> Error

group_len(self: ^Group) -> int
group_cap(self: ^Group) -> int   // the smallest cap among the group's owned tables — the group can never exceed it
group_rebuild(self: ^Group) -> Error

slice(self: ^Group, table: ^Table($T)) -> []T                  // proc group — the aligned dense prefix of one owned Table(T)
slice(self: ^Group, table: ^Arch_Table, $T: typeid) -> []T     // proc group — same, for one column of an owned Arch_Table
entities_slice(self: ^Group) -> []entity_id                     // proc group

pack(self: ^Group) -> Error                 // proc group
pause_packing(self: ^Group) -> Error        // proc group
resume_packing(self: ^Group) -> Error       // proc group

memory_usage(self: ^Group) -> int   // proc group
is_valid(self: ^Group) -> bool      // proc group
```

---

## Iterator

A back-compat cursor over a `View`, for generic per-row access without predeclaring columns and for
`Tag_Table` columns (no data, never sliceable). Prefer `slice(&view, T)` / `entities_slice(&view)`
for everything else. See [View](view.md).

```odin
iterator_init(self: ^Iterator, view: ^View, start_row: int = 0, end_row: int = 0) -> Error
iterator_next(self: ^Iterator) -> bool
iterator_reset(self: ^Iterator) -> Error
get_entity(self: ^Iterator) -> entity_id                          // proc group

get_component(table: ^Table($T), it: ^Iterator) -> ^T             // proc group
get_component(table: ^Compact_Table($T), it: ^Iterator) -> ^T     // proc group
get_component(table: ^Tiny_Table($T), it: ^Iterator) -> ^T        // proc group
get_component(table: ^Arch_Table, it: ^Iterator, $T: typeid) -> ^T  // proc group

// sugar iteration over Table(T) columns only, no entity_id: `for c1, c2 in iterate(it, t1, t2)`
iterate(it: ^Iterator, t1: ^Table($T1)) -> (v1: ^T1, cond: bool)                        // proc group, 1..4 tables
iterate(it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2)) -> (v1: ^T1, v2: ^T2, cond: bool)

// sugar iteration with entity_id, shared with Arch_Iterator below: `for eid, c1, c2 in next(it, t1, t2)`
next(it: ^Iterator, t1: ^Table($T1)) -> (eid: entity_id, v1: ^T1, cond: bool)           // proc group, 1..7 tables
```

## Arch_Iterator (deprecated — prefer `slice(&arch)` + `slice(&arch, T)`)

```odin
arch_iterator_init(self: ^Arch_Iterator, arch_table: ^Arch_Table, start_row: int = 0, end_row: int = 0) -> Error
arch_iterator_reset(self: ^Arch_Iterator) -> Error

// `for eid in next(it)`, `for eid, c1 in next(it, T1)` ... up to 7 typed columns
next(it: ^Arch_Iterator) -> (eid: entity_id, cond: bool)                         // proc group
next(it: ^Arch_Iterator, $T1: typeid) -> (eid: entity_id, v1: ^T1, cond: bool)   // proc group, 1..7 columns
```

---

## Command_Buffer (deferred structural operations)

Records structural changes (add/remove component, destroy entity, tag, parent, pair) for later
`replay`, so mutation doesn't have to happen mid-iteration. See [Command_Buffer](command_buffer.md).

```odin
command_buffer_init(self: ^Command_Buffer, db: ^Database, commands_cap: int, payload_cap: int) -> Error
command_buffer_terminate(self: ^Command_Buffer) -> Error
command_buffer_len(self: ^Command_Buffer) -> int
command_buffer_cap(self: ^Command_Buffer) -> int
clear(self: ^Command_Buffer) -> Error   // proc group — discards pending, unreplayed commands

replay(self: ^Command_Buffer) -> (skipped: int, err: Error)

cmd_destroy_entity(self: ^Command_Buffer, eid: entity_id, destroy_children := false) -> Error

cmd_add_component(self: ^Command_Buffer, table: ^Table($T), eid: entity_id, value: T) -> Error          // proc group
cmd_add_component(self: ^Command_Buffer, table: ^Compact_Table($T), eid: entity_id, value: T) -> Error  // proc group
cmd_add_component(self: ^Command_Buffer, table: ^Tiny_Table($T), eid: entity_id, value: T) -> Error     // proc group

cmd_remove_component(self: ^Command_Buffer, table: ^Table($T), eid: entity_id) -> Error          // proc group
cmd_remove_component(self: ^Command_Buffer, table: ^Compact_Table($T), eid: entity_id) -> Error  // proc group
cmd_remove_component(self: ^Command_Buffer, table: ^Tiny_Table($T), eid: entity_id) -> Error     // proc group
cmd_remove_component(self: ^Command_Buffer, table: ^Arch_Table, eid: entity_id) -> Error         // proc group — whole-row remove

cmd_arch_add_entity(self: ^Command_Buffer, arch: ^Arch_Table, eid: entity_id, v1: $T1) -> Error   // proc group, 1..4 typed column values

cmd_add_tag(self: ^Command_Buffer, table: ^Tag_Table, eid: entity_id) -> Error       // = cmd_tag
cmd_remove_tag(self: ^Command_Buffer, table: ^Tag_Table, eid: entity_id) -> Error    // = cmd_untag

cmd_set_parent(self: ^Command_Buffer, child: entity_id, parent: entity_id) -> Error
cmd_remove_parent(self: ^Command_Buffer, child: entity_id) -> Error   // = cmd_unparent

cmd_pair_add(self: ^Command_Buffer, pt: ^Pair_Table($T), holder: entity_id, target: entity_id, data: T) -> Error
cmd_pair_remove(self: ^Command_Buffer, pt: ^Pair_Table($T), holder: entity_id, target: entity_id) -> Error

memory_usage(self: ^Command_Buffer) -> int   // proc group
is_valid(self: ^Command_Buffer) -> bool      // proc group
```

`replay` returns the number of commands skipped (target entity/table no longer valid) and the first
error hit, if any — it always runs every recorded command, it doesn't stop at the first failure.

---

## Sync (delta-change replication over an unreliable transport) — experimental, off by default

Compile with `-define:ECS_SYNC_ENABLED=true`. Without it, `sync_register` returns
`API_Error.Sync_Feature_Disabled` and every other call below is a no-op against empty state; the
API may still change.

```odin
sync_channel_init(self: ^Sync_Channel, db: ^Database, tables_cap: int,
     structural_events_cap: int = 256) -> Error
sync_channel_terminate(self: ^Sync_Channel) -> Error
sync_decoder_init(self: ^Sync_Decoder, db: ^Database, tables_cap: int) -> Error
sync_decoder_terminate(self: ^Sync_Decoder) -> Error

sync_register(self: ^Sync_Channel, table: ^Table($T), allow_non_pod := false) -> Error   // proc group: also Compact_Table, Tiny_Table
sync_register(self: ^Sync_Channel, table: ^Tag_Table) -> Error                           // proc group — no allow_non_pod, Tag_Table carries no component data
sync_register(self: ^Sync_Decoder, table: ^Table($T), allow_non_pod := false) -> Error   // proc group: also Compact_Table, Tiny_Table
sync_register(self: ^Sync_Decoder, table: ^Tag_Table) -> Error                           // proc group
// registering an Arch_Table returns API_Error.Sync_Table_Type_Not_Supported — out of scope for v1
sync_unregister(self: ^Sync_Channel, table: ^Shared_Table) -> Error

collect_delta(self: ^Sync_Channel, buf: []byte) -> (written: int, err: Error)
delta_max_size(self: ^Sync_Channel) -> int      // upper bound for buf's size
apply_delta(self: ^Sync_Decoder, data: []byte) -> Error
resync(self: ^Sync_Channel) -> Error            // rebuilds the shadow copy + drops pending structural events

clear(self: ^Sync_Channel) -> Error   // proc group — zeroes shadow copies + pending events

memory_usage(self: ^Sync_Channel | ^Sync_Decoder) -> int   // proc group
is_valid(self: ^Sync_Channel | ^Sync_Decoder) -> bool      // proc group
```

---

## Observers (structural-change callbacks) — off by default

Compile with `-define:ECS_OBSERVERS_ENABLED=true`; otherwise `Database.observers` exists but
nothing is ever notified. One database-wide registry, not per-table subscriber lists — an
`Observer` sees every event kind in `interested_in` it cares about. See [Observers](observers.md).

```odin
observer_init(self: ^Observer, db: ^Database,
     callback: proc(event: ^Observer_Event, user_data: rawptr),
     interested_in: bit_set[Observer_Event_Kind] = ~{}, user_data: rawptr = nil) -> Error
observer_terminate(self: ^Observer) -> Error

memory_usage(self: ^Observer) -> int   // proc group
is_valid(self: ^Observer) -> bool      // proc group
```

```odin
Observer_Event_Kind :: enum {
    Entity_Created, Entity_Destroyed,
    Component_Added, Component_Removed,
    Tag_Added, Tag_Removed,
    Component_Enabled, Component_Disabled,
    Parent_Set, Parent_Removed,
    Pair_Added, Pair_Removed,
    Arch_Entity_Added, Arch_Entity_Removed,
}

Observer_Event :: struct {
    kind:          Observer_Event_Kind,
    eid:           entity_id,      // primary entity (child for Parent_*, holder for Pair_*)
    table_id:      table_id,       // Component_*/Tag_*/enable-disable/Arch_Entity_*; sentinel otherwise
    pair_table_id: pair_table_id,  // Pair_Added/Removed; sentinel otherwise
    related:       entity_id,      // Parent_*: parent; Pair_*: target; sentinel otherwise
    data:          rawptr,         // component/pair payload where applicable — valid only during the callback
}
```

Events that remove/destroy something fire *before* the mutation (so the callback can still read
live state); events that add/set something fire *after* (so the new value is already readable).

---

## Relations (`Relations_Table`)

Single-parent/many-children tree relations, one `Relations_Table` per `Database`. See
[Relations](relations.md). Every operation is listed under **Database** above — the shortcuts take
`^Database` and forward into the attached table.

---

## Pairs (`Pair_Table($T)`)

Many-to-many relations between entities (holder → target, optional typed payload `T`), independent
of table/`Relations_Table` membership. See [Pairs](pair_table.md).

```odin
pair_init(self: ^Pair_Table($T), db: ^Database, holders_cap: int, pairs_cap: int) -> Error
pair_terminate(self: ^Pair_Table($T)) -> Error
pair_len(self: ^Pair_Table($T)) -> int
pair_cap(self: ^Pair_Table($T)) -> int

pair_add(self: ^Pair_Table($T), holder: entity_id, target: entity_id, data: T) -> (row: Pair_Row_Id, err: Error)
pair_remove(self: ^Pair_Table($T), holder: entity_id, target: entity_id) -> Error
pair_remove_all(self: ^Pair_Table($T), holder: entity_id) -> Error   // removes every pair for that holder

pair_has_pair(self: ^Pair_Table($T), holder: entity_id, target: entity_id) -> bool
pair_has_any(self: ^Pair_Table($T), holder: entity_id) -> bool             // O(1): does holder have >= 1 pair?
pair_first_target(self: ^Pair_Table($T), holder: entity_id) -> (target: entity_id, ok: bool)
pair_first_data(self: ^Pair_Table($T), holder: entity_id) -> (data: ^T, ok: bool)
pair_targets_of(self: ^Pair_Table($T), holder: entity_id) -> (res: []entity_id, err: Error)  // valid until next call or structural change

memory_usage(self: ^Pair_Table($T)) -> int   // proc group
is_valid(self: ^Pair_Table($T)) -> bool      // proc group
```

---

## Serialization (whole-`Database` binary snapshot)

Round-trips a whole `Database` — entities, every table's components, relations, and pairs. See
[Serialization](serialization.md).

```odin
serialized_size(self: ^Database) -> (size: int, err: Error)
serialize(self: ^Database, buf: []byte, allow_non_pod := false) -> (written: int, err: Error)
deserialize(self: ^Database, data: []byte) -> Error
save_to_file(self: ^Database, path: string, allocator := context.allocator,
     allow_non_pod := false) -> Error
load_from_file(self: ^Database, path: string, allocator := context.allocator) -> Error
```

### Overbase serialization

Same idea, for a shared `Overbase`'s id space (its attached `Database`s are serialized separately,
via the calls above).

```odin
overbase_serialized_size(self: ^Overbase) -> (size: int, err: Error)
overbase_serialize(self: ^Overbase, buf: []byte) -> (written: int, err: Error)
overbase_deserialize(self: ^Overbase, data: []byte) -> Error
overbase_save_to_file(self: ^Overbase, path: string, allocator := context.allocator) -> Error
overbase_load_from_file(self: ^Overbase, path: string, allocator := context.allocator) -> Error
```

---

## Core types & errors

```odin
entity_id ::            oc.ix_gen              // bit_field { ix: u32, gen: u32 }
table_id ::              distinct int
table_record_id ::       distinct int
view_id ::               distinct int
view_record_id ::        distinct u32
view_column_id ::        int
pair_table_id ::         distinct int
command_buffer_id ::     distinct int
observer_id ::           distinct int
Pair_Row_Id ::           distinct int           // row handle returned by pair_add, stable until pair_remove

is_not_set(e: entity_id) -> bool        // true when e.ix == DELETED_INDEX (a "no entity" value)
DELETED_INDEX                            // sentinel index value

Object_State :: enum {
    Not_Initialized, Normal, Invalid, Terminated,
}

Table_Type :: enum {
    Auto, Table, Tiny_Table, Compact_Table, Tag_Table, Arch_Table,
}

API_Error :: enum {
    None,
    Entities_Cap_Should_Be_Greater_Than_Zero, Component_Already_Exist,
    Tables_Array_Should_Not_Be_Empty, Unexpected_Error,
    Entity_Id_Out_of_Bounds, Entity_Id_Expired,
    Cannot_Add_Record_To_View_Container_Is_Full, Object_Invalid,
    Component_Size_Cannot_Be_Zero,
    Relations_Table_Already_Exists, Relations_Table_Not_Created, Relation_Cycle,
    Only_Table_Can_Be_Owned_By_Group, Table_Already_Owned_By_Group,
    Cannot_Pause_Table_Owned_By_Group,
    Table_Cannot_Be_Included_And_Excluded, Table_Cannot_Be_Included_And_Any_Of,
    Snapshot_Invalid, Snapshot_Version_Mismatch, Snapshot_Schema_Mismatch,
    Snapshot_Capacity_Too_Small, Snapshot_Component_Not_POD,
    Cannot_Serialize_While_Packing_Paused, Serialize_Buffer_Too_Small, File_Error,
    Sync_Table_Type_Not_Supported, Sync_Too_Many_Fields, Sync_Table_Already_Registered,
    Sync_Buffer_Too_Small, Sync_Feature_Disabled,
    Tables_Cap_Exceeds_Compile_Time_Limit, Observers_Feature_Disabled,
    Entity_Not_In_Table, Table_To_Cannot_Contain_Entity, Entity_Already_In_Table,
}

Error :: union #shared_nil {
    API_Error, oc.Core_Error, oc.Error, runtime.Allocator_Error,
}
```

### Compile-time configuration

| Define | Default | Meaning |
|---|---|---|
| `ECS_VALIDATIONS` | `true` | Assert-based parameter/state validation (`VALIDATIONS`); disable for a slight speed gain in release builds |
| `ECS_TABLES_MULT` | `1` | Max component types = `128 * ECS_TABLES_MULT`. Bump only past 128 component types — lower is faster and smaller |
| `ECS_TABLES_CAP` | `16` | Initial preallocation for `Database.tables`/`tag_tables`/`groups` |
| `ECS_VIEWS_CAP` | `16` | Initial preallocation for `Database.views` |
| `ECS_TINY_TABLES_CAP` | `32` | Initial preallocation for `Tiny_Table` subscriber slots |
| `ECS_PAIR_TABLES_CAP` | `8` | Initial preallocation for attached `Pair_Table`s |
| `ECS_COMMAND_BUFFERS_CAP` | `8` | Initial preallocation for attached `Command_Buffer`s |
| `ECS_SUBSCRIBERS_CAP` | `8` | Initial preallocation for a table's `View` subscriber list |
| `ECS_SYNC_ENABLED` | `false` | Compiles in `Sync_Channel`/`Sync_Decoder` |
| `ECS_SYNC_CHANNELS_CAP` | `8` | Max sync channels a single table can be registered to |
| `ECS_OBSERVERS_ENABLED` | `false` | Enables the `Observer` notification call sites |
| `ECS_OBSERVERS_CAP` | `8` | Initial preallocation for `Database.observers` |

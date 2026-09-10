# Flags_Table (up to 128 flags per table)

A [`Tag_Table`](tables.md#tag_table) gives each entity one boolean. A `Flags_Table` gives each entity a whole set of up to 128 flags — a `Bits` value (`bit_set[0..<128]`). The limit is per table: an entity can be in any number of Flags_Tables, so the total number of flags per entity is not limited to 128. Views can filter on specific flags with an operation (all of, any of, exactly one of, …).

```odin
import ecs "ode_ecs/src"

my_ecs: ecs.Database
status: ecs.Flags_Table

ecs.init(&my_ecs, entities_cap = 100_000)
ecs.flags_table_init(&status, &my_ecs, cap = 1000)   // cap = entities that may have flags at once
```

The table is terminated with the database; `flags_table_terminate` terminates it early.

## Setting and reading flags

Flags are integer bits `0..<128`, or values of your own enum (values must be below 128).

```odin
ALERT, ARMED :: 0, 1

ecs.flag(&status, guard, ALERT)            // same as ecs.tag(&status, guard, ALERT)
ecs.unflag(&status, guard, ALERT)          // same as ecs.untag(&status, guard, ALERT)
ecs.has_flag(&status, guard, ALERT)        // same as ecs.has_tag(&status, guard, ALERT)
ecs.has_tag(&status, guard)                // has any flag

Status :: enum u8 { Alert, Armed, Wounded }
ecs.flag(&status, guard, Status.Armed)
ecs.has_flag(&status, guard, Status.Armed)

ecs.set_flags(&status, guard, ecs.flags_of(Status.Alert, Status.Wounded))   // replace the whole set
ecs.set_flags(&status, guard, ecs.flags_of(bit_set[Status]{.Alert, .Wounded}))   // same, from a bit_set
ecs.get_flags(&status, guard)              // Bits; {} when the entity has none
ecs.clear_flags(&status, guard)
ecs.has_flags(&status, guard, {1, 2}, .Or) // any Flags_Op, see below
```

## Operations

`Flags_Op` decides how a set of bits is tested against an entity's flags `E`:

| op | holds when | meaning |
|---|---|---|
| `And` (default) | `bits <= E` | has all of `bits` |
| `Or` | `E & bits != {}` | has any of `bits` |
| `Xor` | `card(E & bits) == 1` | has exactly one of `bits` |
| `Nor` | `E & bits == {}` | has none of `bits` |
| `Nand` | `!(bits <= E)` | lacks at least one of `bits` |
| `Exact` | `E == bits` | has exactly `bits` and nothing else; `{}` means no flags at all |

## Views

Pass the table itself for "has any flag", or a `Flags` term for specific flags:

```odin
positions: ecs.Table(Position)

ecs.view_init(&v1, &my_ecs, {&positions, &status})                                    // has any flag
ecs.view_init(&v2, &my_ecs, {&positions, ecs.flags_term(&status, {ALERT, ARMED})})    // has both
ecs.view_init(&v3, &my_ecs, {&positions, ecs.Flags{&status, {ALERT, ARMED}, .Or}})    // has either
ecs.view_init(&v4, &my_ecs, {&positions}, excludes = {ecs.flags_term(&status, {ALERT})})
ecs.view_init(&v5, &my_ecs, {&positions}, any_of = {
    ecs.flags_term(&status, {ALERT}),
    ecs.flags_term(&status, {ARMED}, .Nor),   // alert, or unarmed
})
```

`flags_term(table, bits, op := .And)` builds a `Flags` term. A positional `ecs.Flags{...}` literal needs all three fields; a named one (`ecs.Flags{table = &status, bits = {ALERT}}`) defaults `op` to `And`.

In `includes` a term must hold, in `excludes` it must not, and in `any_of` at least one term — flags or table — must hold. Views follow flag changes automatically.

A term whose op implies the entity has flags (`And`, `Or`, `Xor`, and `Exact` with non-empty bits) also restricts the view to the table's rows, so a view can consist of flag terms alone and still has a capacity and a `rebuild` source:

```odin
ecs.view_init(&alert, &my_ecs, {ecs.flags_term(&status, {ALERT})})
```

`view_init` returns:
- `Flags_Bits_Cannot_Be_Empty` for empty `bits` with any op but `Exact` — `{}` would make the term always true or always false.
- `View_Includes_Need_A_Table` when `includes` holds no table and only `Nor`/`Nand`/`Exact {}` terms — those also match entities without any flags, so there is nothing to size the view from. Add a table.

Passing `&status` also gives the view a `^Bits` column: `ecs.slice(&view, ecs.Bits)`.

## Flags_Table or Tag_Table?

Prefer a Flags_Table for entity state: one table holds many flags, so you don't need a table per flag. A [`Tag_Table`](tables.md#tag_table) is still faster for a single condition that is toggled often or that views are built around. 

So use a Tag_Table for a condition that changes very often in a hot path, or for a rare condition a view is built around. Use a Flags_Table for everything else.

## Storage and memory

A `Flags_Table` is a [`Compact_Table(Bits)`](tables.md#compact_tablet): a Robin Hood map from entity to row, plus dense rows of `Bits` sized to `cap`. An entity has a row exactly when it has at least one flag — clearing its last flag removes the row.

Memory is `24·cap + 8·next_pow2(2·cap)` bytes (about 40 KB at `cap = 1000`), independent of `entities_cap`. Each Flags_Table uses one component-table id, from the same 128 × `ECS_TABLES_MULT` budget as other component tables.

Because it is a real table, the usual machinery applies: `destroy_entity` clears the entity's flags; `table_len`, `table_cap`, `slice` (flags in row order), `entities_slice`, `memory_usage`, `is_valid` and `pause_packing`/`resume_packing`/`pack` work; `any_table(&status)` reports component type `Bits` and `entity_tables` lists it.

The generic component procedures (`add_component`, `get_component_mut`, …) do not accept a `^Flags_Table` — use the flag API, which keeps views and observers in sync. Through `Any_Table`, `any_table_add_component` with `nil` or empty bits returns `Flags_Bits_Cannot_Be_Empty`.

## Clearing

`clear(&status)` removes every entity's flags row by row, so views, observers and sync all see each change. `clear(&my_ecs)` resets the table silently along with the rest of the database.

## Command_Buffer

```odin
ecs.cmd_flag(&cb, &status, guard, Status.Alert)     // also cmd_tag / cmd_add_tag
ecs.cmd_unflag(&cb, &status, guard, Status.Alert)   // also cmd_untag / cmd_remove_tag
ecs.replay(&cb)
```

Commands for an entity destroyed before replay are skipped.

## Observers

Every change fires `Flags_Changed` after the write. `event.table_id` identifies the table and `event.data` points to a `Flags_Change{old, new: Bits}`, valid only during the callback. Gaining the first flag or losing the last one also fires `Component_Added` / `Component_Removed`.

## Snapshots and Sync

Snapshots include Flags_Tables like any compact table; a snapshot containing a row with empty bits is rejected with `Snapshot_Invalid`. For Sync, register the table on both sides:

```odin
ecs.sync_register(&channel, &status)
ecs.sync_register(&decoder, &status_on_receiver)
```

The decoder applies incoming flags through `set_flags`, so views and observers on the receiving side react as usual.

Tests: [tests/flags_table_test.odin](../tests/flags_table_test.odin), [tests/view_flags_test.odin](../tests/view_flags_test.odin), [tests/flags_table_integration_test.odin](../tests/flags_table_integration_test.odin).

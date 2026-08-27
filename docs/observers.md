# Observers (structural-change callbacks)

`Observer` lets you register a callback that fires when a structural change happens: an entity is
created or destroyed, a component/tag/pair is added or removed, a component is enabled/disabled,
or a parent link is set/removed. Off by default — build with `-define:ECS_OBSERVERS_ENABLED=true`
(see `OBSERVERS_ENABLED` in [ecs.odin](/src/ecs.odin)). With it off, every notify call site is
`when OBSERVERS_ENABLED`-gated: the code does not exist in the binary, not just a skipped runtime
branch — enabling the feature costs nothing until you actually attach an observer.

## Setup

```odin
import ecs "ode_ecs"

my_ecs: ecs.Database
ecs.init(&my_ecs, entities_cap = 1000)

on_event :: proc(event: ^ecs.Observer_Event, user_data: rawptr) {
    // ...
}

obs: ecs.Observer
ecs.observer_init(&obs, &my_ecs, on_event) // interested_in defaults to every kind
```
Building without `-define:ECS_OBSERVERS_ENABLED=true` makes `observer_init` return
`API_Error.Observers_Feature_Disabled` — the struct/enum types still exist either way, only the
notify/init code paths are gated.

`database__terminate` automatically terminates any still-attached `Observer` — same as
`Command_Buffer`/`Pair_Table`. `observer_terminate` remains available for early/explicit
termination; both paths are the same underlying code, so calling it yourself and then letting the
database also clean up is safe, not a double-free.

## One database-wide registry, not per-table subscriber lists

Unlike Views (and Sync), an Observer isn't attached to a specific table — you register it once per
`Database` and it sees every event kind it's interested in, filtered by `interested_in`. The event
payload carries enough context (`table_id`, `pair_table_id`, `related` entity) for the callback to
act on it:

```odin
Observer_Event :: struct {
    kind:          Observer_Event_Kind,
    eid:           entity_id,          // primary entity (child for Parent_*, holder for Pair_*)
    table_id:      table_id,           // Component_*/Tag_*/Component_Enabled/Disabled/Arch_Entity_*
    pair_table_id: pair_table_id,      // Pair_Added/Removed
    related:       entity_id,          // Parent_*: parent; Pair_*: target
    data:          rawptr,             // component/pair payload pointer, where applicable
}
```
Fields that don't apply to a given `kind` are set to a `DELETED_INDEX` sentinel (`table_id`/
`pair_table_id`) or `{ix = DELETED_INDEX}` (`related`), not left at a misleading zero value.

To only hear about some kinds:
```odin
ecs.observer_init(&obs, &my_ecs, on_event, interested_in = {.Entity_Created, .Entity_Destroyed})
```

**`event.data` is valid only for the duration of the callback — do not store the pointer.**

## Event kinds and timing

Events that remove/destroy something fire **before** the mutation, so the callback can still read
live state. Events that add/set something fire **after**, so the new value is already readable.

| Kind | Fires |
|---|---|
| `Entity_Created` | after the id is allocated |
| `Entity_Destroyed` | before any cleanup (relations/components/pairs still intact) |
| `Component_Added` | after the row exists — but `add_component` itself hands back a pointer for *you* to fill in, so `data` reads as freshly-zeroed unless the value was supplied directly (e.g. `cmd_add_component`, which supplies it up front) |
| `Component_Removed` | before the swap/zero — `data` still holds the about-to-be-removed value |
| `Tag_Added` / `Tag_Removed` | same timing as Component_Added/Removed |
| `Component_Enabled` / `Component_Disabled` | right after the bits toggle, before Views are admitted/evicted |
| `Parent_Set` | after linking — not fired on the "re-parent to the same parent" no-op |
| `Parent_Removed` | before unlinking — not fired if the entity has no parent (`Not_Found`) |
| `Pair_Added` | after the row is linked — not fired on the idempotent duplicate-add no-op |
| `Pair_Removed` | before unlinking — fires for every holder affected, including the automatic cleanup when a pair's **target** entity is destroyed (see [Pairs](pair_table.md#automatic-cleanup-on-destroy)) |
| `Arch_Entity_Added` / `Arch_Entity_Removed` | same timing as Component_Added/Removed; `data` is always nil (a whole row spans several columns, no single pointer to hand back) |

**`Pair_Table`'s `presence` field is an ordinary `Tag_Table`** (see [Pairs](pair_table.md)), so
adding a holder's *first* pair also fires `Tag_Added`, and removing their *last* pair also fires
`Tag_Removed` — same principle that already gives `presence` free View integration extends to
Observers, not a special case.

## Command_Buffer

Every event fires the same way whether it happened immediately or via
[`Command_Buffer`](command_buffer.md) replay — every hook lives in the lowest-level shared proc
(the same one `command_buffer__replay` itself calls), so there's nothing extra to do:

```odin
cb: ecs.Command_Buffer
ecs.command_buffer_init(&cb, &my_ecs, commands_cap = 64, payload_cap = 1024)
ecs.cmd_add_component(&cb, &positions, eid, Position{ x = 1, y = 2 })
ecs.replay(&cb) // Component_Added fires here, with data already populated — not at record time
```
`Entity_Created` has no `Command_Buffer` command at all (`create_entity` is deliberately not
deferrable — see [Command_Buffer](command_buffer.md)), and neither does
`Component_Enabled`/`Component_Disabled` — both only fire via their one immediate-API call path.

## Other operations

```odin
ecs.observer__is_valid(&obs)
ecs.observer__memory_usage(&obs) // also reachable via the generic ecs.memory_usage
```

Tests: [tests/observer_test.odin](../tests/observer_test.odin) — run with
`-define:ECS_OBSERVERS_ENABLED=true` (see the "ECS Tests Observers" task).

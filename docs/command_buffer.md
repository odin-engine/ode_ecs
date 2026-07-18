# Command_Buffer: record now, apply at a sync point

Where `pause_packing` keeps *table rows* stable, a `Command_Buffer` defers the structural changes themselves: it records `destroy_entity`, `add/remove component`, `tag/untag` and `set_parent/remove_parent` **without touching the database**, and applies them later, in recorded order, with `replay`. Nothing moves or grows until the replay — so mutating while iterating anything (tables, views, dense slices, groups) becomes safe, and spawned/despawned entities become visible at the sync point instead of mid-loop. Like everything else it is fully preallocated: `commands_cap` records plus `payload_cap` bytes for component values, zero allocations while recording or replaying.

```Odin
cb: ecs.Command_Buffer
ecs.command_buffer_init(&cb, &db, commands_cap = 1024, payload_cap = 16 * 1024)
defer ecs.command_buffer_terminate(&cb) // the Database does not track/terminate buffers

// while iterating a view — the database is not mutated:
ecs.cmd_destroy_entity(&cb, dying_eid)
ecs.cmd_remove_component(&cb, &shields, hit_eid)

spawned, _ := ecs.create_entity(&db) // creating entities is already iteration-safe
ecs.cmd_add_component(&cb, &positions, spawned, Position{ x = 10, y = 20 })
ecs.cmd_tag(&cb, &is_enemy, spawned)

// relations (needs a Relations_Table on the db, see relations.md):
ecs.cmd_set_parent(&cb, spawned, squad_eid)
ecs.cmd_remove_parent(&cb, deserter_eid) // alias: ecs.cmd_unparent

// sync point, single-threaded:
skipped, err := ecs.replay(&cb) // applies in order, then clears the buffer
```

Semantics: a command whose entity id expired before it applied (destroyed by an earlier command, another buffer, or your code) is skipped and counted in `skipped` — destroys and removes are idempotent; adding a component that already exists **overwrites its value** (last write wins). Real errors (e.g. a full table) don't abort the replay — remaining commands still run and the first error is returned.

Relations commands follow the same rules: a `cmd_set_parent` whose *parent* expired by replay time is skipped (the child keeps whatever parent it had), a `cmd_remove_parent` for a child that has no parent is skipped, while a cycle (`Relation_Cycle`), a full relations table, or a database without a `Relations_Table` (`Relations_Table_Not_Created` — the check happens at replay, not at record) are real errors.

`create_entity` is intentionally *not* deferred — it only allocates an id and is safe during iteration, so you create the entity immediately and record component commands against the real `entity_id` (no temporary-id remapping needed).

Threading: recording only writes to the buffer's own memory, so use **one Command_Buffer per thread (or per system)** and record concurrently without locks; `replay` mutates the database and must run single-threaded at the sync point, one buffer after another. Replay also composes with `pause_packing` (adds append past holes, removes leave holes).



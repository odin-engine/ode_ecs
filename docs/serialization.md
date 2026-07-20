## 💾 Saving and loading (snapshots)

A whole `Database` can be serialized into a binary snapshot — entities (including their generations, so `entity_id`s you saved inside components or elsewhere stay valid after loading), all components across every table type, tags and parent/child relations. Views and groups are derived data: they are not stored, and are rebuilt automatically after a load.

```odin
// to/from a file (the only allocation is a temporary buffer):
ecs.save_to_file(&db, "world.snap")
ecs.load_from_file(&db, "world.snap")

// or zero-allocation, into your own buffer:
size, _ := ecs.serialized_size(&db)
buf := make([]byte, size)
written, _ := ecs.serialize(&db, buf)
// ... write buf[:written] wherever you want ...
ecs.deserialize(&db, buf[:written])
```

Rules:

* **Load into a matching schema.** `deserialize` requires an already-initialized `Database` with the same tables initialized in the same order (and the same init/terminate history, so table ids coincide), the same component types, and capacities that are **at least** as large as the saved data (`entities_cap` and table caps may be larger). Anything else fails with `Snapshot_Schema_Mismatch` / `Snapshot_Capacity_Too_Small` — the buffer is fully validated before anything is mutated, so a failed load never leaves the database in a torn state.
* **Components must be POD** — plain old data (POD) with no pointers, slices, strings, maps or dynamic arrays inside (component rows are copied as raw bytes). `serialize` rejects non-POD component types with `Snapshot_Component_Not_POD`; pass `allow_non_pod = true` to blob-copy them anyway (only meaningful if you fix such fields up yourself after loading). Per-table custom serialization callbacks are planned for a future version.
* **Pack before saving.** While packing is paused (or tables still hold holes), `serialize` returns `Cannot_Serialize_While_Packing_Paused` — call `resume_packing`/`pack` first.
* Entity generations are 8-bit: an `entity_id` held across exactly 256 destroy/create reuses of the same index compares equal again. This is a general property of ODE_ECS ids, but long-lived snapshots make old ids more likely to stick around — don't keep `entity_id`s from *other*, older snapshots and expect `is_expired` to catch them.
* The format is versioned and validated (magic, endianness, version); a corrupt or truncated buffer fails with `Snapshot_Invalid` without touching the database.

### Overbase snapshots (shared entity ID space)

A Database attached to a shared [`Overbase`](/docs/overbase.md) (`ecs.init_from_overbase`) snapshots *only its own tables* — the entity-id section is included automatically when (and only when) the Database owns its Overbase, so a shared Database's `deserialize` can never clobber id-space state a sibling Database also depends on. Save/restore the shared id-space itself with `Overbase`'s own snapshot functions:

```odin
size, _ := ecs.overbase_serialized_size(&overbase)
buf := make([]byte, size)
ecs.overbase_serialize(&overbase, buf)
// ... later ...
ecs.overbase_deserialize(&overbase, buf)   // into an Overbase already init'd with cap >= the saved cap

// or to/from a file:
ecs.overbase_save_to_file(&overbase, "world.overbase.snap")
ecs.overbase_load_from_file(&overbase, "world.overbase.snap")
```

When restoring a full shared setup, restore the Overbase *before* deserializing any Database attached to it — a Database's own rows are validated against whichever id-space is live at that moment. See [docs/overbase.md](/docs/overbase.md#serialization) and [sample13](/samples/sample13/main.odin) for the full two-Database workflow.
## 💾 Saving and loading (snapshots)

A whole `Database` can be serialized into a binary snapshot — entities (including their generations, so `entity_id`s you saved inside components or elsewhere stay valid after loading), all components across every table type, tags, [`Flags_Table`](/docs/flags_table.md) flags, parent/child relations, and [`Pair_Table`](/docs/pair_table.md) many-to-many relations (including their payload data — `presence` round-trips as an ordinary `Tag_Table` section, and the `(holder, target, data)` rows round-trip alongside it). Views and groups are derived data: they are not stored, and are rebuilt automatically after a load.

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

* **Load into a matching schema.** `deserialize` requires an already-initialized `Database` with the same tables **and the same `Pair_Table`s** initialized in the same order (and the same init/terminate history, so table/pair-table ids coincide), the same component types, and capacities that are **at least** as large as the saved data (`entities_cap` and table caps may be larger). Anything else fails with `Snapshot_Schema_Mismatch` / `Snapshot_Capacity_Too_Small` — the buffer is fully validated before anything is mutated, so a failed load never leaves the database in a torn state.
* **Components must be POD** — plain old data (POD) with no pointers, slices, strings, maps or dynamic arrays inside (component rows are copied as raw bytes). `serialize` rejects non-POD component types with `Snapshot_Component_Not_POD`; pass `allow_non_pod = true` to blob-copy them anyway (only meaningful if you fix such fields up yourself after loading). Per-table custom serialization callbacks are planned for a future version.
* **Pack before saving.** While packing is paused (or tables still hold holes), `serialize` returns `Cannot_Serialize_While_Packing_Paused` — call `resume_packing`/`pack` first.
* Entity generations are 32-bit: an `entity_id` held across exactly 4,294,967,296 destroy/create reuses of the same index compares equal again. This is a general property of ODE_ECS ids, but long-lived snapshots make old ids more likely to stick around — don't keep `entity_id`s from *other*, older snapshots and expect `is_expired` to catch them.
* The format is versioned and validated (magic, endianness, version); a corrupt or truncated buffer fails with `Snapshot_Invalid` without touching the database.
* **No files on js or freestanding wasm.** `save_to_file`/`load_from_file` and the KDL snapshots below don't exist on the `js` and `freestanding` targets, which have no file system (`ecs.HAS_FILE_SYSTEM` is false there). `serialize`/`deserialize` into your own buffer work everywhere.

### Human-readable KDL snapshots

The same snapshot can be written as a folder of [KDL](https://kdl.dev) text files (via the embedded `src/ode_kdl` library). You can read these files, diff them, and edit them by hand:

```odin
ecs.save_to_kdl(&db, "saves/slot1")                   // fails with Snapshot_Already_Exists if a snapshot is already there
ecs.save_to_kdl(&db, "saves/slot1", overwrite = true) // replaces it
ecs.load_from_kdl(&db, "saves/slot1")
```

The folder holds one file per table, plus a few shared files:

* `_snapshot.kdl` is the manifest: the format version, `entities_cap`, and every file that belongs to the snapshot. It is written last, and it sorts to the top of the folder.
* A table's file is named after its component, in snake_case plural: `File_Info` → `file_infos.kdl`. When several tables share a name, each one gets its init order: `positions1.kdl`, `positions2.kdl`.
* Tag, Flags and Arch tables use `tags.kdl`, `flags.kdl` and `archetypes.kdl`. A `Pair_Table` is named after its data type, or `pairs.kdl` when the data is empty.
* `entities.kdl` holds the entity ids and generations. It is written only when the Database owns its Overbase.
* `relations.kdl` holds the parent/child links.

Here is part of a table file:

```kdl
table id=0 type=Table component=game.Position cap=1024
row 5 1 x=1.5 y=-2.0
(disabled)row 9 1 x=3.0 y=4.0
```

* **Row layout.** Each `row` starts with the entity's `ix gen`. Struct fields become properties.
* **Nested types.** Nested structs, arrays, `bit_set`s and `bit_field`s (including `entity_id`) become child nodes.
* **Scalar values.** Enums are written by name. Types with no readable form (unions, complex numbers, matrices, SIMD vectors, raw unions) are written as `(hex)"…"`.
* **Hand edits.** On load, fields are matched **by name**, so their order doesn't matter, and an omitted field loads as zero. An unknown field, or a value of the wrong type, fails with `Snapshot_Invalid`.
* **Schema checks.** Tables are matched by the `id`/`type` in their header, not by file name. A different `component` name fails with `Snapshot_Schema_Mismatch`.
* **Loading.** The folder is transcoded to the binary format and passed to `deserialize`. All the binary rules above still apply: matching schema, POD components, all-or-nothing validation. The one difference is that there is no `allow_non_pod` option.
* **Overwrite.** `overwrite = true` deletes only the files the old manifest lists, plus the manifest itself. It refuses a manifest entry that is not a plain `*.kdl` name inside the folder. Other files in the folder are left alone. If a file the new snapshot needs already exists and the old snapshot doesn't own it, the save fails with `Snapshot_Already_Exists`.

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
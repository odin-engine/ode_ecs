# Pairs (many-to-many relations) — `Pair_Table(T)`

`Pair_Table(T)` is a many-to-many relation type, unlike [`Relations_Table`](relations.md)'s single-parent model: a holder can point at any number of targets, and a target can be pointed at by any number of holders. Typical uses: "Likes", "Equipped", "TargetedBy" — anything relational that isn't a strict tree.

Unlike `Relations_Table`, a `Pair_Table` **does** affect [Views](view.md). Every `Pair_Table` owns a real `Tag_Table` (`presence`) with one row per holder that currently has ≥ 1 pair — that `Tag_Table` gets full, correct View-subscriber notification for free, so `{&pairs.presence}` is usable directly in `view_init`'s `includes`/`excludes`/`any_of` to mean "has (or doesn't have) at least one pair of this relation."

The actual `(holder, target, data)` rows live in a separate, non-View-visible row array, cross-indexed by **two** intrusive doubly-linked lists per row — one by holder (for `targets_of`/`remove`/`remove_all`, the same technique `Relations_Table` uses for `first_child`/`next_sibling`, generalized from "children of a parent" to "pair-rows of a holder"), one by target (for O(1) cleanup when a target entity is destroyed — see "Automatic cleanup on destroy" below). Rows are never tail-swapped/compacted (unlike `Table(T)`) — that would break row-id stability for both linked lists on every remove.

## Setup

```odin
import ecs "ode_ecs"

my_ecs: ecs.Database
likes:  ecs.Pair_Table(struct{})  // T = struct{} for tag-only pairs (no payload)

ecs.init(&my_ecs, entities_cap = 1000)

// holders_cap bounds distinct holders with >= 1 pair (sizes the internal presence
// Tag_Table). pairs_cap bounds total concurrent (holder, target) rows — usually
// pairs_cap >= holders_cap since one holder can have several pairs.
ecs.pair_init(&likes, &my_ecs, holders_cap = 500, pairs_cap = 2000)
```

`database__terminate` automatically terminates any still-attached `Pair_Table` — same as [`Relations_Table`](relations.md), which is also not itself a `Shared_Table` (only its embedded `presence` is). `pair_table__terminate` remains available for early/explicit termination; both paths are the same underlying code, so calling it yourself and then letting the database also clean up is safe, not a double-free:

```odin
defer ecs.terminate(&my_ecs)
defer ecs.pair_table__terminate(&likes) // optional — database termination alone is enough
```

Memory cost: `presence`'s own `Tag_Table` cost (see [Tables](tables.md)) plus, for the pair-row storage, roughly `pairs_cap * (size_of(entity_id)*2 + size_of(T) + size_of(Pair_Row_Id)*4) + entities_cap * size_of(Pair_Row_Id)*2` bytes (the two doubly-linked lists cost `Pair_Row_Id`-sized `next`/`prev` arrays each, one indexed by holder and one by target).

## Adding and removing pairs

```odin
alice, _ := ecs.create_entity(&my_ecs)
bob,   _ := ecs.create_entity(&my_ecs)
carol, _ := ecs.create_entity(&my_ecs)

ecs.pair_add(&likes, alice, bob, struct{}{})    // alice likes bob
ecs.pair_add(&likes, alice, carol, struct{}{})  // alice also likes carol — many-to-many
ecs.pair_add(&likes, alice, bob, struct{}{})    // adding the exact same pair again is a no-op

ecs.pair_has_pair(&likes, alice, bob)  // true
ecs.pair_has_any(&likes, alice)        // true — has at least one pair (== has_tag(&likes.presence, alice))

ecs.pair_remove(&likes, alice, bob)    // removes just that one pair; alice still likes carol
ecs.pair_remove_all(&likes, alice)     // removes every pair alice holds — also drops her presence tag
```

Adding an already-existing exact `(holder, target)` pair is a no-op that returns the existing row (its payload is **not** overwritten) — matches `Tag_Table`/`Relations_Table`'s idempotent-add idiom.

`pair_add` returns `Container_Is_Full` if `holder` needs a *new* presence slot and `presence` is full, or the pair-row array itself is full — validated before any mutation, so a failed add never partially mutates either side. `pair_remove` returns `Not_Found` for a pair that doesn't exist.

## Automatic cleanup on destroy

Destroying either side of a pair cleans it up automatically — same "every stored `entity_id` is always alive" guarantee [`Relations_Table`](relations.md#automatic-cleanup-on-destroy) makes:

- Destroying a **holder** removes its presence tag via the normal per-entity table-bit cleanup path, same as any other component.
- Destroying a **target** removes every row referencing it — `pair_table_base__remove_target`, called automatically from `destroy_entity`, walks only that target's own pair rows (via the target-side doubly-linked list), not the whole `Pair_Table`. This is O(#pairs for that target), independent of `pairs_cap` — `destroy_entity` is a universal hot path, so this costs nothing for entities that never appear in any `Pair_Table`. If that was a holder's last remaining pair, its presence tag drops too (evicting it from any subscribed View), exactly as if you'd called `pair_remove` yourself.

```odin
ecs.destroy_entity(&my_ecs, bob) // bob was alice's target
ecs.pair_has_pair(&likes, alice, bob) // false — the row is gone, not stale
```

## Queries

```odin
target, ok := ecs.pair_first_target(&likes, alice)  // O(1): most-recently-added target
data, ok    = ecs.pair_first_data(&likes, alice)     // O(1): pointer to that same row's payload

targets, _ := ecs.pair_targets_of(&likes, alice)     // O(#pairs for alice), all targets
```

> **NOTE:** `pair_first_target` returns an arbitrary target among several (pairs are head-inserted, most-recently-added first) — not a stable/deterministic choice, don't rely on which one you get when a holder has more than one pair.

> **NOTE:** The slice returned by `pair_targets_of` points into an internal scratch buffer. It is valid only until the next `pair_targets_of` call or any structural change (`pair_add`/`pair_remove`/`pair_remove_all`) — use it immediately, do not store it. Same contract as [`children_of`](relations.md#queries).

## Using pairs in a View

```odin
view: ecs.View
ecs.view_init(&view, &my_ecs, includes = {&positions}, excludes = {&likes.presence}) // has Position, likes nobody
// or:
ecs.view_init(&view, &my_ecs, includes = {&likes.presence}) // likes at least one thing
```

This works with **zero** extra View code — `presence` is an ordinary `Tag_Table`, and `View` doesn't know or care that it happens to be embedded inside a `Pair_Table`.

## Command_Buffer

```odin
cb: ecs.Command_Buffer
ecs.command_buffer_init(&cb, &my_ecs, commands_cap = 64, payload_cap = 1024)

ecs.cmd_pair_add(&cb, &likes, alice, bob, struct{}{})
ecs.cmd_pair_remove(&cb, &likes, alice, carol)

ecs.replay(&cb) // applies in recorded order, then clears the buffer
```

Both check entity liveness for **both** the holder and the target at replay time (mirroring `cmd_set_parent`'s parent-liveness check) — an expired target is skipped, counted in `skipped`, same as any other command. Unlike `cmd_add_component`'s overwrite-on-duplicate ("last write wins"), `cmd_pair_add` inherits `pair_add`'s own idempotent no-overwrite dedupe: replaying two `cmd_pair_add`s for the exact same `(holder, target)` in one buffer keeps the **first** recorded payload. See [Command_Buffer](command_buffer.md).

## Serialization

`Pair_Table` round-trips through [`serialize`/`deserialize`](serialization.md) like any other part of the database — `presence`'s membership and every `(holder, target, data)` row both survive, kept in sync. As with tables and views, the target `Database` must have the same `Pair_Table`s `pair_init`'d in the same order before `deserialize` runs:

```odin
size, _ := ecs.serialized_size(&my_ecs)
buf := make([]byte, size)
ecs.serialize(&my_ecs, buf)

// elsewhere: my_ecs2 already has `likes2` pair_init'd the same way
ecs.deserialize(&my_ecs2, buf)
```

The saved format stores only the canonical `(holder, target, data)` triples for occupied rows — not the freelist/linked-list bookkeeping, which gets rebuilt from scratch on load (a `Pair_Table` row isn't `entity_id`-indexed the way `Relations_Table`'s arrays are, so unlike relations there's no structural forest to validate, only per-row entity liveness and schema/capacity checks).

## Complete example

```odin
Likes_Data :: struct { strength: int }

my_ecs: ecs.Database
likes:  ecs.Pair_Table(Likes_Data)

main :: proc() {
    defer ecs.terminate(&my_ecs)
    defer ecs.pair_table__terminate(&likes)

    ecs.init(&my_ecs, entities_cap = 100)
    ecs.pair_init(&likes, &my_ecs, holders_cap = 100, pairs_cap = 300)

    alice, _ := ecs.create_entity(&my_ecs)
    bob,   _ := ecs.create_entity(&my_ecs)
    carol, _ := ecs.create_entity(&my_ecs)

    ecs.pair_add(&likes, alice, bob, Likes_Data{ strength = 8 })
    ecs.pair_add(&likes, alice, carol, Likes_Data{ strength = 3 })

    targets, _ := ecs.pair_targets_of(&likes, alice) // alice's targets: {bob, carol}
    for target in targets {
        // process each (alice, target) pair — e.g. look up its data with
        // a dedicated per-target lookup if you need more than first_data below
    }

    strongest_target, _ := ecs.pair_first_target(&likes, alice) // most-recently-added: carol
    strongest_data, _   := ecs.pair_first_data(&likes, alice)   // -> &Likes_Data{ strength = 3 }

    ecs.pair_remove(&likes, alice, bob)
    ecs.pair_has_pair(&likes, alice, bob) // false
}
```

## Other operations

```odin
ecs.pair_table__len(&likes)         // current number of (holder, target) rows
ecs.pair_table__cap(&likes)         // pairs_cap
ecs.pair_table__memory_usage(&likes) // bytes (also reachable via the generic ecs.memory_usage)
ecs.is_valid(&likes)
```

Tests: [tests/pair_table_test.odin](../tests/pair_table_test.odin) — including target-destroy cleanup (both the "last pair" and "not last pair" branches), database auto-terminate, `Command_Buffer` record+replay, and a full serialization round-trip.

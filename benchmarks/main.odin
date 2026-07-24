/*
    2026 (c) Oleh, https://github.com/zm69

    ODE_ECS micro-benchmarks. The referee for performance work: run before and
    after a change and compare ns/op. Uses a fixed seed and reports the best of
    REPS repetitions (min is the most stable statistic for micro-benchmarks).

    Run:
        odin run . -o:speed -out:out/bench.exe

    For release-like numbers also try:
        odin run . -o:speed -disable-assert -no-bounds-check -define:ECS_VALIDATIONS=false -out:out/bench.exe

    Scenarios:
        iter_table          direct sweep of table.rows (the speed ceiling)
        iter_dense_slice    view_dense_slice sweep (dense/aligned fast path)
        iter_dense_it       Iterator over a dense-aligned 2-column view
        iter_mixed_it       Iterator over a misaligned 2-column view (pointer path)
        iter_mixed_1col_it  Iterator over the same view reading only the still-aligned
                            column (pointer path)
        iter_mixed_1col_sl  same single-column read via view_dense_slice — possible
                            because alignment is tracked per column, not per view
        iter_group_slice    both columns of the same population via an owned group
                            (group_dense_slice) — enforced alignment, raw SoA sweep
        churn_vel           add+remove a 2nd component, no group (baseline)
        churn_vel_group     same, with an owned group over both tables — every
                            add/remove pays the group's swap maintenance
        get_random          shuffled random get_component by entity (Table)
        get_random_compact  shuffled random get_component by entity (Compact_Table)
        get_random_compact_miss  same, against a half-populated Compact_Table
                            (50% lookups miss — exercises the Robin Hood probe exit)
        churn               add+remove a component with 2 subscribed views
        churn_partial       add+remove a component with 2 subscribed two-table views
                            that never match (entities lack the second component)
        churn_compact       churn against a Compact_Table (Rh_Map32 add/remove path)
        churn_tiny          churn against a Tiny_Table (Tt_Map path, 8-row cycles)
        churn_tag           tag/untag churn against a Tag_Table (tag map path)
        churn_small_view    churn on a small (512-cap) view inside an N-entity db —
                            measures the view's per-entity eid_to_rid representation
        destroy             create+destroy entities with 3 components, with
                            8 / 32 / 128 tables attached to the database
        rebuild             full view rebuild over N rows

    Measured dead ends (do not re-attempt without new evidence):
    - Merging the id-factory entry with eid_to_bits into one per-entity record
      (generic Ix_Gen_Factory item {id, bits}): neutral at CHURN_N=10K, clear
      LOSS at 500K shuffled — churn +20%, churn_partial +50% (interleaved A/B).
      The split arrays' independent loads already overlap (memory-level
      parallelism), so co-locating saves no latency; meanwhile u128 alignment
      pads the 24 B record to 32 B, inflating the hot footprint by a third.
    - An "unchecked" get_component that skips entity validation showed zero gain
      at N=100K and N=1M — the validation load and the component lookup are
      independent, so the CPU overlaps them (memory-level parallelism);
      validation is effectively free.
    - Per-column dense reads in Iterator (mask consulted when only some view
      columns are aligned): cost the fully-dense loop ~60% and gained the mixed
      loop nothing. Per-column alignment lives in view_dense_slice instead.
    - Bits pre-filter on remove notifications (skip view__remove_record when
      view.bits can't be a subset of the entity's bits): churn 10.9 -> 12.0,
      churn_partial 9.4 -> 10.2 ns/op at CHURN_N=500K shuffled — its own
      best-case scenario. The per-view eid_to_ptr probes are independent loads
      the CPU overlaps (memory-level parallelism); the bits test adds a
      dependent branch that serializes the loop.
    - Adaptive View eid_to_rid (Rh_Map32 backing for small views instead of the
      entities_cap-sized array): churn_small_view 9.3 -> 11.5 ns/op (+23%) in the
      map's own best-case scenario, and the array path paid +6% churn / +9%
      churn_partial for the backing-choice branch alone. At N=100K the 400 KB
      array is L2-resident and its independent loads overlap (memory-level
      parallelism); the map probe is a dependent hash->load->compare chain.
    - Rh_Map32 "high bits" Fibonacci hash ((k*C) >> shift instead of & mask):
      hits 1.48 -> 1.8 ns/op, misses 5.3 -> 6.0. Entity indexes are dense
      consecutive ints, and the low-bits multiplicative hash is a bijection on
      any aligned power-of-2 key range — zero collisions, strictly better than
      a "well-mixed" hash here. Likewise the Robin Hood probe-distance early
      exit for misses: neutral at best (chains are already ~1 long), and the
      extra per-probe hash pushed hit cost to 3.2 ns/op in one variant.
    - #force_inline on the database__create_entity -> overbase__create_entity ->
      oc.ix_gen_factory__new_id wrapper chain (Overbase split it across two
      procs): no gain, create_entity ~3.7-4.0 ns/op either way, B lost 3/5
      interleaved rounds. Unlike database__destroy_entity_local (a large,
      branchy proc where the same trick gave a consistent 2.3-2.6% win, see
      database.odin), this chain's callees are already tiny — the backend was
      likely auto-inlining them regardless of the explicit hint.
    - Merging Tiny_Table's tt_map__get + tt_map__add add_component path into a
      single tt_map__find_item probe (mirroring the Rh_Map32 get_or_insert
      change below): neutral in interleaved A/B, churn_tiny ~12.6-13.9 ns/op
      either way with no consistent direction across 10 rounds.
      TINY_TABLE__ROW_CAP=8 against a 32-slot map keeps chains so short
      (~1 slot) that the second walk's cost is already in the noise floor —
      unlike Rh_Map32's case, there was no auto-inlining-eligibility loss to
      offset (tt_map__get/add were never separately call-site-bloating), so
      there was nothing to gain by merging them. Reverted.
    - A CORE_VALIDATIONS #config flag in ode_core (mirroring ecs.odin's
      VALIDATIONS) gating ix_gen_factory__free_id's 4 checks and the explicit
      runtime.bounds_check_error_loc calls in dense_arr__remove_by_index /
      sparse_arr__remove_by_index / ix_gen_factory__get_id: zero gain on
      destroy (8/32 tables) and get_random with the flag off vs on in
      interleaved A/B (~21.7-21.8 ns/op and ~0.52-0.55 ns/op either way) —
      same "validation is free, the CPU overlaps it" pattern as the
      unchecked-get_component dead end above. Reverted; not worth the added
      double-free corruption risk (skipping ix_gen_factory__free_id's
      Already_Freed/Not_Found checks lets a duplicate free silently corrupt
      the free list) for no measured benefit.
    - #force_inline on table__get_component_by_entity / compact_table__ /
      tiny_table__get_component_by_entity (2-line validate-then-delegate
      wrappers): inconclusive in interleaved A/B — get_random and
      get_random_compact overlapped both ways across 5 rounds (no consistent
      winner), get_random_compact_miss leaned very slightly better inlined
      but within the same noise band as the other two. Same pattern as the
      create_entity wrapper-chain dead end above: these callees are already
      tiny and single-call-site, so the backend was likely auto-inlining them
      regardless of the hint. Reverted.

    Measured wins / accepted costs (2026-07):
    - Tiny_Table remove: deriving the tail pointer as &rows[len-1] instead of a
      tt_map probe — churn_tiny ~13.1 -> ~12.6 ns/op (-3.5%) at release flags,
      consistent across interleaved rounds.
    - Suspended-view stale guard (view__missed_update_for_member in the remove/
      move notify loops): VALIDATIONS-gated after measuring ~2% on churn
      scenarios when unconditional; release builds (ECS_VALIDATIONS=false)
      measure neutral with the gate.
    - view__rebuild/refilter over shared_table__rid_to_eid_slice (type dispatch
      once per scan instead of a 5-case switch per row): rebuild ~5.3 -> ~5.0
      ns/op (-5%) at release flags, consistent across interleaved rounds.
    - destroy: ctz (count_trailing_zeros) set-bit extraction instead of Odin's
      full-domain `for id in bit_set` scan — neutral at TABLES_MULT=1 (the 128
      register-resident bit tests were overlapping the removal work), kept for
      the true O(components) iteration: at TABLES_MULT>1 the old form scanned
      128*MULT positions per destroy, the ctz form touches only set bits and
      each word once.
*/
package ode_ecs_benchmarks

// Core
    import "core:fmt"
    import "core:time"
    import "core:math/rand"

// ODE_ECS
    import ecs "../"

//
// Components
//
    Position :: struct { x, y: f32 }
    Velocity :: struct { dx, dy: f32 }
    AI :: struct { neurons_count: int }

//
// Config
//
    N :: #config(BENCH_N, 100_000) // entities for iteration/lookup scenarios
    CHURN_N :: #config(BENCH_CHURN_N, 10_000) // entities for churn/destroy scenarios
    REPS :: 9
    SEED :: 881982019898081

    g_sink: f64 // checksum accumulator, prevents dead-code elimination

//
// Helpers
//
    report :: proc(name: string, best_ns: i64, ops: int) {
        fmt.printf("%-24s %10.2f ns/op    (best of %v, %v ops)\n", name, f64(best_ns) / f64(ops), REPS, ops)
    }

    elapsed_ns :: proc(sw: ^time.Stopwatch) -> i64 {
        return time.duration_nanoseconds(time.stopwatch_duration(sw^))
    }

//
// Globals (data lives on the heap; keeping roots global keeps main() readable)
//
    db: ecs.Database
    positions: ecs.Table(Position)
    velocities: ecs.Table(Velocity)
    ais: ecs.Compact_Table(AI)
    ais_half: ecs.Compact_Table(AI) // only every 2nd entity — for the miss benchmark
    both: ecs.View
    eids: []ecs.entity_id
    shuffled: []ecs.entity_id

    mixed_db: ecs.Database
    m_positions: ecs.Table(Position)
    m_velocities: ecs.Table(Velocity)
    m_both: ecs.View

    group_db: ecs.Database
    g_positions: ecs.Table(Position)
    g_velocities: ecs.Table(Velocity)
    g_group: ecs.Group

main :: proc() {
    rand.reset(SEED)

    fmt.printfln("ODE_ECS benchmarks: N=%v, CHURN_N=%v, REPS=%v, ECS_VALIDATIONS=%v", N, CHURN_N, REPS, ecs.VALIDATIONS)
    fmt.println()

    setup_main_db()
    bench_iter_table()
    bench_iter_dense_slice()
    bench_iter_dense_it()

    setup_mixed_db()
    bench_iter_mixed_it()
    bench_iter_mixed_1col()

    setup_group_db()
    bench_iter_group_slice()

    bench_get_random()
    bench_get_random_compact()
    bench_get_random_compact_miss()
    bench_rebuild()

    bench_churn()
    bench_churn_partial()
    bench_churn_group()
    bench_churn_compact()
    bench_churn_tiny()
    bench_churn_tag()
    bench_churn_small_view()

    bench_create_entity()

    bench_destroy(8)
    bench_destroy(32)
    bench_destroy(128)

    fmt.println()
    fmt.println("checksum:", g_sink) // consume results so nothing is optimized away
}

//
// Setup
//

setup_main_db :: proc() {
    if ecs.init(&db, N, context.allocator) != nil do panic("db init failed")
    if ecs.table_init(&positions, &db, N) != nil do panic("positions init failed")
    if ecs.table_init(&velocities, &db, N) != nil do panic("velocities init failed")
    if ecs.compact_table__init(&ais, &db, N) != nil do panic("ais init failed")
    if ecs.compact_table__init(&ais_half, &db, N / 2) != nil do panic("ais_half init failed")
    if ecs.view_init(&both, &db, {&positions, &velocities}) != nil do panic("view init failed")

    eids = make([]ecs.entity_id, N)
    shuffled = make([]ecs.entity_id, N)

    for i in 0..<N {
        eid, err := ecs.create_entity(&db)
        if err != nil do panic("create_entity failed")

        p, perr := ecs.add_component(&positions, eid)
        if perr != nil do panic("add position failed")
        p.x = f32(i)
        p.y = 1

        v, verr := ecs.add_component(&velocities, eid)
        if verr != nil do panic("add velocity failed")
        v.dx = 1
        v.dy = f32(i % 7)

        a, aerr := ecs.add_component(&ais, eid)
        if aerr != nil do panic("add ai failed")
        a.neurons_count = i

        if i % 2 == 0 {
            ah, aherr := ecs.add_component(&ais_half, eid)
            if aherr != nil do panic("add ai_half failed")
            ah.neurons_count = i
        }

        eids[i] = eid
    }

    copy(shuffled, eids)
    rand.shuffle(shuffled)
}

setup_mixed_db :: proc() {
    if ecs.init(&mixed_db, N, context.allocator) != nil do panic("mixed db init failed")
    if ecs.table_init(&m_positions, &mixed_db, N) != nil do panic("m_positions init failed")
    if ecs.table_init(&m_velocities, &mixed_db, N) != nil do panic("m_velocities init failed")
    if ecs.view_init(&m_both, &mixed_db, {&m_positions, &m_velocities}) != nil do panic("m_both init failed")

    // every entity has Position, every 2nd also Velocity -> the view's Position
    // refs don't line up with view rows, forcing the pointer (non-dense) path
    for i in 0..<N {
        eid, err := ecs.create_entity(&mixed_db)
        if err != nil do panic("create_entity failed")

        p, perr := ecs.add_component(&m_positions, eid)
        if perr != nil do panic("add position failed")
        p.x = f32(i)

        if i % 2 == 0 {
            v, verr := ecs.add_component(&m_velocities, eid)
            if verr != nil do panic("add velocity failed")
            v.dx = 1
        }
    }
}

//
// Iteration
//

bench_iter_table :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for &p in positions.rows {
            s += p.x + p.y
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_table", best, N)
}

bench_iter_dense_slice :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        ps := ecs.view_dense_slice(&both, &positions)
        vs := ecs.view_dense_slice(&both, &velocities)
        if ps == nil || vs == nil do panic("expected dense-aligned view")
        for i in 0..<len(ps) {
            s += ps[i].x + vs[i].dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_dense_slice", best, N)
}

bench_iter_dense_it :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)
    it: ecs.Iterator

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        if ecs.iterator_init(&it, &both) != nil do panic("iterator init failed")
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&positions, &it)
            v := ecs.get_component(&velocities, &it)
            s += p.x + v.dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_dense_it", best, N)
}

bench_iter_mixed_it :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)
    it: ecs.Iterator
    ops := ecs.view_len(&m_both)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        if ecs.iterator_init(&it, &m_both) != nil do panic("iterator init failed")
        if it.dense do panic("expected non-dense view")
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&m_positions, &it)
            v := ecs.get_component(&m_velocities, &it)
            s += p.x + v.dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_mixed_it", best, ops)
}

// A system that reads a single column of a misaligned view (e.g. only Velocity of the
// pos+vel view). Before per-column alignment this was forced onto the pointer path;
// now the still-aligned column is sliceable on its own.
bench_iter_mixed_1col :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)
    it: ecs.Iterator
    ops := ecs.view_len(&m_both)

    // pointer path baseline
    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        if ecs.iterator_init(&it, &m_both) != nil do panic("iterator init failed")
        for ecs.iterator_next(&it) {
            v := ecs.get_component(&m_velocities, &it)
            s += v.dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }
    report("iter_mixed_1col_it", best, ops)

    // per-column dense slice: velocities follow view-row order (they complete the
    // entity), positions do not — so vel is sliceable while pos is not
    best = max(i64)
    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        vs := ecs.view_dense_slice(&m_both, &m_velocities)
        if vs == nil do panic("expected vel column dense-aligned")
        for i in 0..<len(vs) {
            s += vs[i].dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }
    if ecs.view_dense_slice(&m_both, &m_positions) != nil do panic("expected pos column misaligned")
    report("iter_mixed_1col_sl", best, ops)
}

setup_group_db :: proc() {
    if ecs.init(&group_db, N, context.allocator) != nil do panic("group db init failed")
    if ecs.table_init(&g_positions, &group_db, N) != nil do panic("g_positions init failed")
    if ecs.table_init(&g_velocities, &group_db, N) != nil do panic("g_velocities init failed")
    if ecs.group_init(&g_group, &group_db, {&g_positions, &g_velocities}) != nil do panic("group init failed")

    // same population as the mixed db: every entity has Position, every 2nd also
    // Velocity — but here the group keeps the matching half in an aligned prefix
    for i in 0..<N {
        eid, err := ecs.create_entity(&group_db)
        if err != nil do panic("create_entity failed")

        p, perr := ecs.add_component(&g_positions, eid)
        if perr != nil do panic("add position failed")
        p.x = f32(i)

        if i % 2 == 0 {
            v, verr := ecs.add_component(&g_velocities, eid)
            if verr != nil do panic("add velocity failed")
            v.dx = 1
        }
    }

    if ecs.group_len(&g_group) != N / 2 do panic("unexpected group size")
}

// Same work as iter_mixed_it (sum a Position and a Velocity field of every
// pos+vel entity), but through the group's always-aligned prefix: a raw SoA
// sweep with no per-row rid records and no alignment rescans.
bench_iter_group_slice :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)
    ops := ecs.group_len(&g_group)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        ps := ecs.group_dense_slice(&g_group, &g_positions)
        vs := ecs.group_dense_slice(&g_group, &g_velocities)
        if ps == nil || vs == nil do panic("expected group slices")
        for i in 0..<len(ps) {
            s += ps[i].x + vs[i].dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_group_slice", best, ops)
}

//
// Random access
//

bench_get_random :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for eid in shuffled {
            s += ecs.get_component(&positions, eid).x
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("get_random", best, N)
}

bench_get_random_compact :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: int = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for eid in shuffled {
            s += ecs.get_component(&ais, eid).neurons_count
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("get_random_compact", best, N)
}

bench_get_random_compact_miss :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: int = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for eid in shuffled {
            c := ecs.get_component(&ais_half, eid)
            if c != nil do s += c.neurons_count
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("get_random_compact_miss", best, N)
}

//
// View rebuild
//

bench_rebuild :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        if ecs.rebuild(&both) != nil do panic("rebuild failed")
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.view_len(&both))

    report("rebuild", best, N)
}

//
// Structural churn
//

bench_churn :: proc() {
    churn_db: ecs.Database
    churn_pos: ecs.Table(Position)
    view_a: ecs.View
    view_b: ecs.View

    if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
    if ecs.table_init(&churn_pos, &churn_db, CHURN_N) != nil do panic("churn table init failed")
    if ecs.view_init(&view_a, &churn_db, {&churn_pos}) != nil do panic("view_a init failed")
    if ecs.view_init(&view_b, &churn_db, {&churn_pos}) != nil do panic("view_b init failed")

    churn_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(churn_eids)

    for i in 0..<CHURN_N {
        eid, err := ecs.create_entity(&churn_db)
        if err != nil do panic("create_entity failed")
        churn_eids[i] = eid
    }

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for eid in churn_eids {
            p, err := ecs.add_component(&churn_pos, eid)
            if err != nil do panic("add failed")
            p.x = 1
        }
        for eid in churn_eids {
            if ecs.remove_component(&churn_pos, eid) != nil do panic("remove failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&churn_pos))

    report("churn (add+remove)", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

// Two-table views subscribed to the churned table, but the entities never have the
// second component: every remove notifies both views about an entity that is not in
// them. Measures the cost of pointless view notifications during removal.
bench_churn_partial :: proc() {
    churn_db: ecs.Database
    churn_pos: ecs.Table(Position)
    churn_aux: ecs.Table(Velocity)
    view_a: ecs.View
    view_b: ecs.View

    if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
    if ecs.table_init(&churn_pos, &churn_db, CHURN_N) != nil do panic("churn pos init failed")
    if ecs.table_init(&churn_aux, &churn_db, CHURN_N) != nil do panic("churn aux init failed")
    if ecs.view_init(&view_a, &churn_db, {&churn_pos, &churn_aux}) != nil do panic("view_a init failed")
    if ecs.view_init(&view_b, &churn_db, {&churn_pos, &churn_aux}) != nil do panic("view_b init failed")

    churn_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(churn_eids)

    for i in 0..<CHURN_N {
        eid, err := ecs.create_entity(&churn_db)
        if err != nil do panic("create_entity failed")
        churn_eids[i] = eid
    }
    // removals in scattered order (creation order would be prefetcher-friendly
    // and hide the cost of the per-view random reads this scenario measures)
    rand.shuffle(churn_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for eid in churn_eids {
            p, err := ecs.add_component(&churn_pos, eid)
            if err != nil do panic("add failed")
            p.x = 1
        }
        for eid in churn_eids {
            if ecs.remove_component(&churn_pos, eid) != nil do panic("remove failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    if ecs.view_len(&view_a) != 0 || ecs.view_len(&view_b) != 0 do panic("views should stay empty")
    g_sink += f64(ecs.table_len(&churn_pos))

    report("churn_partial (2 views)", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

// The price of group maintenance on structural churn: every add of the 2nd
// component joins the group (a row swap per owned table), every remove leaves it.
// Run once without a group as the baseline, once with.
bench_churn_group :: proc() {
    run :: proc(name: string, with_group: bool) {
        churn_db: ecs.Database
        churn_pos: ecs.Table(Position)
        churn_vel: ecs.Table(Velocity)
        churn_group: ecs.Group

        if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
        if ecs.table_init(&churn_pos, &churn_db, CHURN_N) != nil do panic("churn pos init failed")
        if ecs.table_init(&churn_vel, &churn_db, CHURN_N) != nil do panic("churn vel init failed")
        if with_group {
            if ecs.group_init(&churn_group, &churn_db, {&churn_pos, &churn_vel}) != nil do panic("group init failed")
        }

        churn_eids := make([]ecs.entity_id, CHURN_N)
        defer delete(churn_eids)

        for i in 0..<CHURN_N {
            eid, err := ecs.create_entity(&churn_db)
            if err != nil do panic("create_entity failed")
            p, perr := ecs.add_component(&churn_pos, eid)
            if perr != nil do panic("add pos failed")
            p.x = 1
            churn_eids[i] = eid
        }
        rand.shuffle(churn_eids) // scattered order, see bench_churn_partial

        sw: time.Stopwatch
        best: i64 = max(i64)

        for _ in 0..<REPS {
            time.stopwatch_reset(&sw)
            time.stopwatch_start(&sw)

            for eid in churn_eids {
                v, err := ecs.add_component(&churn_vel, eid)
                if err != nil do panic("add failed")
                v.dx = 1
            }
            for eid in churn_eids {
                if ecs.remove_component(&churn_vel, eid) != nil do panic("remove failed")
            }

            time.stopwatch_stop(&sw)
            best = min(best, elapsed_ns(&sw))
        }
        if with_group && ecs.group_len(&churn_group) != 0 do panic("group should be empty")
        g_sink += f64(ecs.table_len(&churn_vel))

        report(name, best, CHURN_N * 2)

        if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
    }

    run("churn_vel (no group)", false)
    run("churn_vel (group)", true)
}

// Same shape as churn, but the churned table is a Compact_Table — measures the
// Rh_Map32 add/remove path (hash + probe + backward shift) under scattered ids.
bench_churn_compact :: proc() {
    churn_db: ecs.Database
    churn_pos: ecs.Compact_Table(Position)
    view_a: ecs.View
    view_b: ecs.View

    if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
    if ecs.compact_table__init(&churn_pos, &churn_db, CHURN_N) != nil do panic("churn compact init failed")
    if ecs.view_init(&view_a, &churn_db, {&churn_pos}) != nil do panic("view_a init failed")
    if ecs.view_init(&view_b, &churn_db, {&churn_pos}) != nil do panic("view_b init failed")

    churn_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(churn_eids)

    for i in 0..<CHURN_N {
        eid, err := ecs.create_entity(&churn_db)
        if err != nil do panic("create_entity failed")
        churn_eids[i] = eid
    }
    rand.shuffle(churn_eids) // scattered order, see bench_churn_partial

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for eid in churn_eids {
            p, err := ecs.add_component(&churn_pos, eid)
            if err != nil do panic("add failed")
            p.x = 1
        }
        for eid in churn_eids {
            if ecs.remove_component(&churn_pos, eid) != nil do panic("remove failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&churn_pos))

    report("churn_compact", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

// Tiny_Table structural churn. The table holds at most TINY_TABLE__ROW_CAP (8)
// rows, so the 8 slots are cycled CHURN_N/8 times per rep — measures the
// Tt_Map add/remove path including its backward-shift on remove.
bench_churn_tiny :: proc() {
    TINY :: 8 // ecs.TINY_TABLE__ROW_CAP

    churn_db: ecs.Database
    churn_pos: ecs.Tiny_Table(Position)
    view_a: ecs.View
    view_b: ecs.View

    if ecs.init(&churn_db, 16, context.allocator) != nil do panic("churn db init failed")
    if ecs.tiny_table__init(&churn_pos, &churn_db) != nil do panic("churn tiny init failed")
    if ecs.view_init(&view_a, &churn_db, {&churn_pos}) != nil do panic("view_a init failed")
    if ecs.view_init(&view_b, &churn_db, {&churn_pos}) != nil do panic("view_b init failed")

    churn_eids: [TINY]ecs.entity_id
    for i in 0..<TINY {
        eid, err := ecs.create_entity(&churn_db)
        if err != nil do panic("create_entity failed")
        churn_eids[i] = eid
    }
    rand.shuffle(churn_eids[:])

    rounds := max(1, CHURN_N / TINY)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for _ in 0..<rounds {
            for eid in churn_eids {
                p, err := ecs.add_component(&churn_pos, eid)
                if err != nil do panic("add failed")
                p.x = 1
            }
            for eid in churn_eids {
                if ecs.remove_component(&churn_pos, eid) != nil do panic("remove failed")
            }
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&churn_pos))

    report("churn_tiny", best, TINY * 2 * rounds)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

// Tag_Table structural churn — measures the tag map add/remove path (the sole
// production user of that map) under scattered ids, with 2 subscribed views.
bench_churn_tag :: proc() {
    churn_db: ecs.Database
    is_alive: ecs.Tag_Table
    view_a: ecs.View
    view_b: ecs.View

    if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
    if ecs.tag_table__init(&is_alive, &churn_db, CHURN_N) != nil do panic("churn tag init failed")
    if ecs.view_init(&view_a, &churn_db, {&is_alive}) != nil do panic("view_a init failed")
    if ecs.view_init(&view_b, &churn_db, {&is_alive}) != nil do panic("view_b init failed")

    churn_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(churn_eids)

    for i in 0..<CHURN_N {
        eid, err := ecs.create_entity(&churn_db)
        if err != nil do panic("create_entity failed")
        churn_eids[i] = eid
    }
    rand.shuffle(churn_eids) // scattered order, see bench_churn_partial

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for eid in churn_eids {
            if ecs.add_tag(&is_alive, eid) != nil do panic("add_tag failed")
        }
        for eid in churn_eids {
            if ecs.remove_tag(&is_alive, eid) != nil do panic("remove_tag failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&is_alive))

    report("churn_tag", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

// A small view (cap 512) inside a LARGE database (entities_cap N): the view's
// eid_to_rid bookkeeping is indexed by entity ix scattered across the whole
// 0..N range, so its per-entity representation (array of N vs small map) is
// what this scenario measures. Member eids are spread evenly over the ix range
// and shuffled.
bench_churn_small_view :: proc() {
    SMALL :: 512

    sv_db: ecs.Database
    sv_pos: ecs.Table(Position)
    sv_aux: ecs.Table(Velocity)
    sv_view: ecs.View

    if ecs.init(&sv_db, N, context.allocator) != nil do panic("sv db init failed")
    if ecs.table_init(&sv_pos, &sv_db, SMALL) != nil do panic("sv pos init failed")
    if ecs.table_init(&sv_aux, &sv_db, SMALL) != nil do panic("sv aux init failed")
    if ecs.view_init(&sv_view, &sv_db, {&sv_pos, &sv_aux}) != nil do panic("sv view init failed")

    all_eids := make([]ecs.entity_id, N)
    defer delete(all_eids)
    for i in 0..<N {
        eid, err := ecs.create_entity(&sv_db)
        if err != nil do panic("create_entity failed")
        all_eids[i] = eid
    }

    // members spread across the whole entity ix range
    member_eids := make([]ecs.entity_id, SMALL)
    defer delete(member_eids)
    stride := N / SMALL
    for i in 0..<SMALL {
        member_eids[i] = all_eids[i * stride]
        v, verr := ecs.add_component(&sv_aux, member_eids[i])
        if verr != nil do panic("add aux failed")
        v.dx = 1
    }
    rand.shuffle(member_eids)

    rounds := max(1, CHURN_N / SMALL)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for _ in 0..<rounds {
            for eid in member_eids {
                p, err := ecs.add_component(&sv_pos, eid)
                if err != nil do panic("add failed")
                p.x = 1
            }
            for eid in member_eids {
                if ecs.remove_component(&sv_pos, eid) != nil do panic("remove failed")
            }
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    if ecs.view_len(&sv_view) != 0 do panic("view should be empty")
    g_sink += f64(ecs.table_len(&sv_pos))

    report("churn_small_view", best, SMALL * 2 * rounds)

    if ecs.terminate(&sv_db) != nil do panic("sv db terminate failed")
}

//
// Entity creation
//

bench_create_entity :: proc() {
    ce_db: ecs.Database
    if ecs.init(&ce_db, CHURN_N, context.allocator) != nil do panic("create_entity db init failed")

    ce_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(ce_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for i in 0..<CHURN_N {
            eid, err := ecs.create_entity(&ce_db)
            if err != nil do panic("create_entity failed")
            ce_eids[i] = eid
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))

        // reset outside the timed section for the next rep
        for eid in ce_eids {
            if ecs.destroy_entity(&ce_db, eid) != nil do panic("destroy failed")
        }
    }
    g_sink += f64(ecs.entities_len(&ce_db))

    report("create_entity", best, CHURN_N)

    if ecs.terminate(&ce_db) != nil do panic("create_entity db terminate failed")
}

//
// Entity destruction with many tables attached
//

bench_destroy :: proc(table_count: int) {
    des_db: ecs.Database
    tables := make([]ecs.Table(Position), table_count)
    defer delete(tables)

    if ecs.init(&des_db, CHURN_N, context.allocator) != nil do panic("destroy db init failed")
    for &t in tables {
        if ecs.table_init(&t, &des_db, CHURN_N) != nil do panic("table init failed")
    }

    des_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(des_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        // setup outside the timed section: 3 components per entity
        for i in 0..<CHURN_N {
            eid, err := ecs.create_entity(&des_db)
            if err != nil do panic("create_entity failed")
            for j in 0..<3 {
                _, aerr := ecs.add_component(&tables[j], eid)
                if aerr != nil do panic("add failed")
            }
            des_eids[i] = eid
        }

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for eid in des_eids {
            if ecs.destroy_entity(&des_db, eid) != nil do panic("destroy failed")
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.entities_len(&des_db))

    report(fmt.tprintf("destroy (%v tables)", table_count), best, CHURN_N)

    if ecs.terminate(&des_db) != nil do panic("destroy db terminate failed")
}

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
        iter_dense_slice    slice sweep (dense/aligned fast path)
        iter_dense_it       Iterator over a dense-aligned 2-column view
        iter_mixed_it       Iterator over a misaligned 2-column view (pointer path)
        iter_mixed_1col_it  Iterator over the same view reading only the still-aligned
                            column (pointer path)
        iter_mixed_1col_sl  same single-column read via slice — possible
                            because alignment is tracked per column, not per view
        iter_group_slice    both columns of the same population via an owned group
                            (slice) — enforced alignment, raw SoA sweep
        iter_arch_slice     both columns of an Arch_Table (Position+Velocity) via
                            arch_table__column_slice — always aligned, no group needed
        iter_arch_slice_eids  same Arch_Table, but via slice(&arch) + slice(&arch, T) —
                            the entities_slice + column_slice idiom now recommended for
                            View, applied to Arch_Table for a direct, apples-to-apples
                            contrast against iter_arch_it below
        iter_arch_it        same Arch_Table via Arch_Iterator + ecs.next(&it, T1, T2)
        iter_view_arch_mixed  a View including both a Table and an Arch_Table, read
                            through one Iterator via manual iterator_next +
                            get_component(&table, &it) / get_component(&arch, &it, T)
                            (Phase 3: View/Iterator integration — measures the added
                            path's own cost; see the header notes below for proof
                            this integration added ZERO cost to the pre-existing
                            iter_* scenarios above, which never touch Arch_Table)
        churn_vel           add+remove a 2nd component, no group (baseline)
        churn_vel_group     same, with an owned group over both tables — every
                            add/remove pays the group's swap maintenance
        churn_arch          same 2-component set, but as a single Arch_Table row
                            (one add_entity/remove_entity call moves both columns
                            in one swap instead of Group's per-table swap pair)
        churn_group_mixed   a Group owning one Table (Position, always present) and
                            one Arch_Table (Velocity+AI, joins/leaves each cycle) —
                            Phase 4: Group ownership of Arch_Table. Compare against
                            churn_vel_group (Table-only group, same op count) to see
                            group maintenance cost when one owned "table" is an
                            Arch_Table; see the header notes for proof this
                            integration added ZERO cost to churn_vel_group itself
        get_random          shuffled random get_component by entity (Table)
        get_random_mut      same, via get_component_mut (pays table_base__mark_touched)
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
        walk_hierarchy      whole-forest breadth-first Relations_Table walk (100
                            root chains) — reports ns per entity visited
        roots               O(entities_cap) root scan over the same forest —
                            reports ns per live entity (cost is independent of
                            forest shape, only of how many entities exist)
        pair_first_target   O(1) point lookup, most-recently-added target of a
                            holder (PAIR_FANOUT=16 targets/holder)
        pair_targets_of     O(#pairs for that holder) full-list walk, reported
                            per holder (not per pair) for a direct, honest
                            contrast against pair_first_target's O(1) number
        churn_pair          steady-state pair_add (fan-out 16) + pair_remove_all
                            per holder — Pair_Table's structural churn cost
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
    Pair_Data :: struct { weight: f32 }

//
// Config
//
    N :: #config(BENCH_N, 100_000)
    CHURN_N :: #config(BENCH_CHURN_N, 10_000)
    REPS :: 9
    SEED :: 881982019898081

    g_sink: f64

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
// Globals
//
    db: ecs.Database
    positions: ecs.Table(Position)
    velocities: ecs.Table(Velocity)
    ais: ecs.Compact_Table(AI)
    ais_half: ecs.Compact_Table(AI)
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

    arch_db: ecs.Database
    arch_pv: ecs.Arch_Table

    mv_db: ecs.Database
    mv_positions: ecs.Table(Position)
    mv_arch: ecs.Arch_Table
    mv_view: ecs.View

main :: proc() {
    rand.reset(SEED)

    fmt.printfln("ODE_ECS benchmarks: N=%v, CHURN_N=%v, REPS=%v, ECS_VALIDATIONS=%v", N, CHURN_N, REPS, ecs.VALIDATIONS)
    fmt.println()

    setup_main_db()
    bench_iter_table()
    bench_iter_dense_it()

    setup_mixed_db()
    bench_iter_mixed_it()
    bench_iter_mixed_1col()

    setup_group_db()
    bench_iter_group_slice()

    setup_arch_db()
    bench_iter_arch_slice()
    bench_iter_arch_slice_eids()
    bench_iter_arch_it()

    setup_mixed_view_arch_db()
    bench_iter_view_arch_mixed()

    bench_get_random()
    bench_get_random_mut()
    bench_get_random_compact()
    bench_get_random_compact_miss()
    bench_rebuild()

    bench_churn()
    bench_churn_partial()
    bench_churn_group()
    bench_churn_arch()
    bench_churn_group_mixed()
    bench_churn_compact()
    bench_churn_tiny()
    bench_churn_tag()
    bench_churn_small_view()

    bench_create_entity()

    bench_destroy(8)
    bench_destroy(32)
    bench_destroy(128)

    bench_walk_hierarchy()
    bench_roots()

    bench_pair_first_target()
    bench_pair_targets_of()
    bench_pair_churn()

    bench_plain_view_iter()
    bench_iterator_manual_get_component()
    bench_exp_view_iter()

    fmt.println()
    fmt.println("checksum:", g_sink)
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

bench_iter_mixed_1col :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)
    it: ecs.Iterator
    ops := ecs.view_len(&m_both)

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
}

setup_group_db :: proc() {
    if ecs.init(&group_db, N, context.allocator) != nil do panic("group db init failed")
    if ecs.table_init(&g_positions, &group_db, N) != nil do panic("g_positions init failed")
    if ecs.table_init(&g_velocities, &group_db, N) != nil do panic("g_velocities init failed")
    if ecs.group_init(&g_group, &group_db, {&g_positions, &g_velocities}) != nil do panic("group init failed")

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

bench_iter_group_slice :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)
    ops := ecs.group_len(&g_group)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        ps := ecs.slice(&g_group, &g_positions)
        vs := ecs.slice(&g_group, &g_velocities)
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

setup_arch_db :: proc() {
    if ecs.init(&arch_db, N, context.allocator) != nil do panic("arch db init failed")
    if ecs.arch_table__init(&arch_pv, &arch_db, N, {Position, Velocity}) != nil do panic("arch_pv init failed")

    for i in 0..<N {
        eid, err := ecs.arch_table__create_entity(&arch_pv)
        if err != nil do panic("arch create_entity failed")

        p := ecs.arch_table__get_component(&arch_pv, eid, Position)
        p.x = f32(i)
        p.y = 1

        v := ecs.arch_table__get_component(&arch_pv, eid, Velocity)
        v.dx = 1
        v.dy = f32(i % 7)
    }
}

bench_iter_arch_slice :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        ps := ecs.arch_table__column_slice(&arch_pv, Position)
        vs := ecs.arch_table__column_slice(&arch_pv, Velocity)
        if ps == nil || vs == nil do panic("expected arch dense slices")
        for i in 0..<len(ps) {
            s += ps[i].x + vs[i].dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_arch_slice", best, N)
}

bench_iter_arch_slice_eids :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        eids := ecs.slice(&arch_pv)
        ps := ecs.slice(&arch_pv, Position)
        vs := ecs.slice(&arch_pv, Velocity)
        if ps == nil || vs == nil do panic("expected arch slices")
        for i in 0..<len(eids) {
            s += ps[i].x + vs[i].dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_arch_slice_eids", best, N)
}

bench_iter_arch_it :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)
    it: ecs.Arch_Iterator

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        if ecs.arch_iterator_init(&it, &arch_pv) != nil do panic("arch iterator init failed")
        for _, p, v in ecs.next(&it, Position, Velocity) {
            s += p.x + v.dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_arch_it", best, N)
}

setup_mixed_view_arch_db :: proc() {
    if ecs.init(&mv_db, N, context.allocator) != nil do panic("mv db init failed")
    if ecs.table_init(&mv_positions, &mv_db, N) != nil do panic("mv_positions init failed")
    if ecs.arch_table__init(&mv_arch, &mv_db, N, {Velocity, AI}) != nil do panic("mv_arch init failed")
    if ecs.view_init(&mv_view, &mv_db, {&mv_positions, &mv_arch}) != nil do panic("mv_view init failed")

    for i in 0..<N {
        eid, err := ecs.create_entity(&mv_db)
        if err != nil do panic("create_entity failed")

        p, perr := ecs.add_component(&mv_positions, eid)
        if perr != nil do panic("add position failed")
        p.x = f32(i)

        if ecs.arch_table__add_entity(&mv_arch, eid) != nil do panic("mv arch add failed")
        v := ecs.arch_table__get_component(&mv_arch, eid, Velocity)
        v.dx = 1
        a := ecs.arch_table__get_component(&mv_arch, eid, AI)
        a.neurons_count = i
    }
}

bench_iter_view_arch_mixed :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)
    it: ecs.Iterator

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        if ecs.iterator_init(&it, &mv_view) != nil do panic("iterator init failed")
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&mv_positions, &it)
            v := ecs.get_component(&mv_arch, &it, Velocity)
            s += p.x + v.dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_view_arch_mixed", best, N)
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

bench_get_random_mut :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for eid in shuffled {
            s += ecs.get_component_mut(&positions, eid).x
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("get_random_mut", best, N)
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
        rand.shuffle(churn_eids)

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

bench_churn_arch :: proc() {
    churn_db: ecs.Database
    churn_pv: ecs.Arch_Table

    if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
    if ecs.arch_table__init(&churn_pv, &churn_db, CHURN_N, {Position, Velocity}) != nil do panic("churn arch init failed")

    churn_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(churn_eids)

    for i in 0..<CHURN_N {
        eid, err := ecs.create_entity(&churn_db)
        if err != nil do panic("create_entity failed")
        churn_eids[i] = eid
    }
    rand.shuffle(churn_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for eid in churn_eids {
            if ecs.arch_table__add_entity(&churn_pv, eid) != nil do panic("arch add failed")
        }
        for eid in churn_eids {
            if ecs.arch_table__remove_entity(&churn_pv, eid) != nil do panic("arch remove failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&churn_pv))

    report("churn_arch (2 cols)", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

bench_churn_group_mixed :: proc() {
    churn_db: ecs.Database
    churn_pos: ecs.Table(Position)
    churn_arch: ecs.Arch_Table
    churn_group: ecs.Group

    if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
    if ecs.table_init(&churn_pos, &churn_db, CHURN_N) != nil do panic("churn pos init failed")
    if ecs.arch_table__init(&churn_arch, &churn_db, CHURN_N, {Velocity, AI}) != nil do panic("churn arch init failed")
    if ecs.group_init(&churn_group, &churn_db, {&churn_pos, &churn_arch}) != nil do panic("group init failed")

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
    rand.shuffle(churn_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for eid in churn_eids {
            if ecs.arch_table__add_entity(&churn_arch, eid) != nil do panic("arch add failed")
        }
        for eid in churn_eids {
            if ecs.arch_table__remove_entity(&churn_arch, eid) != nil do panic("arch remove failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    if ecs.group_len(&churn_group) != 0 do panic("group should be empty")
    g_sink += f64(ecs.table_len(&churn_arch))

    report("churn_group_mixed", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

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
    g_sink += f64(ecs.table_len(&churn_pos))

    report("churn_compact", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

bench_churn_tiny :: proc() {
    TINY :: 8

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
    rand.shuffle(churn_eids)

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

WH_ROOTS :: 100

bench_setup_forest :: proc(db: ^ecs.Database, rt: ^ecs.Relations_Table) {
    chain_len := CHURN_N / WH_ROOTS
    for r in 0..<WH_ROOTS {
        prev, err := ecs.create_entity(db)
        if err != nil do panic("create_entity failed")
        for i in 1..<chain_len {
            next, nerr := ecs.create_entity(db)
            if nerr != nil do panic("create_entity failed")
            if ecs.set_parent(db, next, prev) != nil do panic("set_parent failed")
            prev = next
        }
    }
}

bench_walk_hierarchy :: proc() {
    wh_db: ecs.Database
    wh_rt: ecs.Relations_Table

    if ecs.init(&wh_db, CHURN_N, context.allocator) != nil do panic("walk_hierarchy db init failed")
    if ecs.relations_init(&wh_rt, &wh_db, CHURN_N) != nil do panic("walk_hierarchy relations init failed")
    bench_setup_forest(&wh_db, &wh_rt)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        entities, _, err := ecs.walk_hierarchy(&wh_db)
        time.stopwatch_stop(&sw)
        if err != nil do panic("walk_hierarchy failed")
        g_sink += f64(len(entities))
        best = min(best, elapsed_ns(&sw))
    }

    report("walk_hierarchy", best, CHURN_N)

    if ecs.terminate(&wh_db) != nil do panic("walk_hierarchy db terminate failed")
}

bench_roots :: proc() {
    r_db: ecs.Database
    r_rt: ecs.Relations_Table

    if ecs.init(&r_db, CHURN_N, context.allocator) != nil do panic("roots db init failed")
    if ecs.relations_init(&r_rt, &r_db, CHURN_N) != nil do panic("roots relations init failed")
    bench_setup_forest(&r_db, &r_rt)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        roots, err := ecs.roots(&r_db)
        time.stopwatch_stop(&sw)
        if err != nil do panic("roots failed")
        g_sink += f64(len(roots))
        best = min(best, elapsed_ns(&sw))
    }

    report("roots", best, CHURN_N)

    if ecs.terminate(&r_db) != nil do panic("roots db terminate failed")
}

PAIR_FANOUT :: 16
PAIR_HOLDERS :: CHURN_N / PAIR_FANOUT

bench_setup_pairs :: proc(db: ^ecs.Database, pt: ^ecs.Pair_Table(Pair_Data)) -> (holders: []ecs.entity_id) {
    holders = make([]ecs.entity_id, PAIR_HOLDERS)
    for i in 0..<PAIR_HOLDERS {
        h, err := ecs.create_entity(db)
        if err != nil do panic("create_entity failed")
        holders[i] = h
        for j in 0..<PAIR_FANOUT {
            t, terr := ecs.create_entity(db)
            if terr != nil do panic("create_entity failed")
            _, aerr := ecs.pair_add(pt, h, t, Pair_Data{ weight = f32(j) })
            if aerr != nil do panic("pair_add failed")
        }
    }
    return
}

bench_pair_first_target :: proc() {
    p_db: ecs.Database
    p_pt: ecs.Pair_Table(Pair_Data)

    if ecs.init(&p_db, PAIR_HOLDERS * (PAIR_FANOUT + 1), context.allocator) != nil do panic("pair_first_target db init failed")
    if ecs.pair_init(&p_pt, &p_db, holders_cap = PAIR_HOLDERS, pairs_cap = PAIR_HOLDERS * PAIR_FANOUT) != nil do panic("pair_first_target pair_init failed")
    holders := bench_setup_pairs(&p_db, &p_pt)
    defer delete(holders)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for h in holders {
            target, ok := ecs.pair_first_target(&p_pt, h)
            if ok do g_sink += f64(target.ix)
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    report("pair_first_target", best, PAIR_HOLDERS)

    if ecs.terminate(&p_db) != nil do panic("pair_first_target db terminate failed")
}

bench_pair_targets_of :: proc() {
    p_db: ecs.Database
    p_pt: ecs.Pair_Table(Pair_Data)

    if ecs.init(&p_db, PAIR_HOLDERS * (PAIR_FANOUT + 1), context.allocator) != nil do panic("pair_targets_of db init failed")
    if ecs.pair_init(&p_pt, &p_db, holders_cap = PAIR_HOLDERS, pairs_cap = PAIR_HOLDERS * PAIR_FANOUT) != nil do panic("pair_targets_of pair_init failed")
    holders := bench_setup_pairs(&p_db, &p_pt)
    defer delete(holders)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for h in holders {
            targets, err := ecs.pair_targets_of(&p_pt, h)
            if err != nil do panic("pair_targets_of failed")
            g_sink += f64(len(targets))
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    report("pair_targets_of", best, PAIR_HOLDERS)

    if ecs.terminate(&p_db) != nil do panic("pair_targets_of db terminate failed")
}

bench_pair_churn :: proc() {
    c_db: ecs.Database
    c_pt: ecs.Pair_Table(Pair_Data)

    if ecs.init(&c_db, PAIR_HOLDERS * (PAIR_FANOUT + 1), context.allocator) != nil do panic("churn_pair db init failed")
    if ecs.pair_init(&c_pt, &c_db, holders_cap = PAIR_HOLDERS, pairs_cap = PAIR_HOLDERS * PAIR_FANOUT) != nil do panic("churn_pair pair_init failed")

    holders := make([]ecs.entity_id, PAIR_HOLDERS)
    defer delete(holders)
    targets := make([]ecs.entity_id, PAIR_HOLDERS * PAIR_FANOUT)
    defer delete(targets)

    for i in 0..<PAIR_HOLDERS {
        h, err := ecs.create_entity(&c_db)
        if err != nil do panic("create_entity failed")
        holders[i] = h
        for j in 0..<PAIR_FANOUT {
            t, terr := ecs.create_entity(&c_db)
            if terr != nil do panic("create_entity failed")
            targets[i * PAIR_FANOUT + j] = t
        }
    }

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for i in 0..<PAIR_HOLDERS {
            h := holders[i]
            for j in 0..<PAIR_FANOUT {
                _, aerr := ecs.pair_add(&c_pt, h, targets[i * PAIR_FANOUT + j], Pair_Data{ weight = f32(j) })
                if aerr != nil do panic("pair_add failed")
            }
        }
        for h in holders {
            if ecs.pair_remove_all(&c_pt, h) != nil do panic("pair_remove_all failed")
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    g_sink += f64(ecs.pair_table__len(&c_pt))
    report("churn_pair", best, PAIR_HOLDERS * PAIR_FANOUT * 2)

    if ecs.terminate(&c_db) != nil do panic("churn_pair db terminate failed")
}

bench_plain_view_iter :: proc() {
    p_db: ecs.Database
    p_positions: ecs.Table(Position)
    p_velocities: ecs.Table(Velocity)
    p_view: ecs.View

    if ecs.init(&p_db, N, context.allocator) != nil do panic("plain_view_iter db init failed")
    if ecs.table_init(&p_positions, &p_db, N) != nil do panic("plain_view_iter positions init failed")
    if ecs.table_init(&p_velocities, &p_db, N) != nil do panic("plain_view_iter velocities init failed")
    if ecs.view_init(&p_view, &p_db, {&p_positions, &p_velocities}) != nil do panic("plain_view_iter view init failed")

    for i in 0..<N {
        eid, err := ecs.create_entity(&p_db)
        if err != nil do panic("create_entity failed")
        if _, aerr := ecs.add_component(&p_positions, eid); aerr != nil do panic("add_component failed")
        if _, verr := ecs.add_component(&p_velocities, eid); verr != nil do panic("add_component failed")
    }

    it: ecs.Iterator
    if ecs.iterator_init(&it, &p_view) != nil do panic("iterator_init failed")

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        ecs.iterator_reset(&it)
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for eid, pos, vel in ecs.next(&it, &p_positions, &p_velocities) {
            pos.x += vel.dx
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    g_sink += f64(ecs.view_len(&p_view))
    report("plain_view_iter", best, N)

    if ecs.terminate(&p_db) != nil do panic("plain_view_iter db terminate failed")
}

bench_iterator_manual_get_component :: proc() {
    r_db: ecs.Database
    r_positions: ecs.Table(Position)
    r_velocities: ecs.Table(Velocity)
    r_view: ecs.View

    if ecs.init(&r_db, N, context.allocator) != nil do panic("iterator_manual_get_component db init failed")
    if ecs.table_init(&r_positions, &r_db, N) != nil do panic("iterator_manual_get_component positions init failed")
    if ecs.table_init(&r_velocities, &r_db, N) != nil do panic("iterator_manual_get_component velocities init failed")
    if ecs.view_init(&r_view, &r_db, {&r_positions, &r_velocities}) != nil do panic("iterator_manual_get_component view init failed")

    for i in 0..<N {
        eid, err := ecs.create_entity(&r_db)
        if err != nil do panic("create_entity failed")
        if _, aerr := ecs.add_component(&r_positions, eid); aerr != nil do panic("add_component failed")
        if _, verr := ecs.add_component(&r_velocities, eid); verr != nil do panic("add_component failed")
    }

    it: ecs.Iterator
    if ecs.iterator_init(&it, &r_view) != nil do panic("iterator_init failed")

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        ecs.iterator_reset(&it)
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for ecs.next(&it) {
            pos := ecs.get_component(&r_positions, &it)
            vel := ecs.get_component(&r_velocities, &it)
            pos.x += vel.dx
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    g_sink += f64(ecs.view_len(&r_view))
    report("iterator_manual_get_component", best, N)

    if ecs.terminate(&r_db) != nil do panic("iterator_manual_get_component db terminate failed")
}

bench_exp_view_iter :: proc() {
    x_db: ecs.Database
    x_positions: ecs.Table(Position)
    x_velocities: ecs.Table(Velocity)
    x_view: ecs.View

    if ecs.init(&x_db, N, context.allocator) != nil do panic("exp_view_iter db init failed")
    if ecs.table_init(&x_positions, &x_db, N) != nil do panic("exp_view_iter positions init failed")
    if ecs.table_init(&x_velocities, &x_db, N) != nil do panic("exp_view_iter velocities init failed")
    if ecs.view_init(&x_view, &x_db, {&x_positions, &x_velocities}) != nil do panic("exp_view_iter view init failed")

    for i in 0..<N {
        eid, err := ecs.create_entity(&x_db)
        if err != nil do panic("create_entity failed")
        if _, aerr := ecs.add_component(&x_positions, eid); aerr != nil do panic("add_component failed")
        if _, verr := ecs.add_component(&x_velocities, eid); verr != nil do panic("add_component failed")
    }

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        pos_col := ecs.view_column_slice(&x_view, Position)
        vel_col := ecs.view_column_slice(&x_view, Velocity)

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for i in 0..<ecs.view_len(&x_view) {
            pos_col[i].x += vel_col[i].dx
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    g_sink += f64(ecs.view_len(&x_view))
    report("exp_view_iter", best, N)

    if ecs.view_terminate(&x_view) != nil do panic("exp_view_iter view terminate failed")
    if ecs.terminate(&x_db) != nil do panic("exp_view_iter db terminate failed")
}


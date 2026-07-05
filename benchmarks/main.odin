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
        get_random          shuffled random get_component by entity (Table)
        get_random_compact  shuffled random get_component by entity (Compact_Table)
        churn               add+remove a component with 2 subscribed views
        destroy             create+destroy entities with 3 components, with
                            8 / 32 / 128 tables attached to the database
        rebuild             full view rebuild over N rows

    Future (measure-first) candidates: merging the id-factory entry with
    eid_to_bits into one per-entity record; rh_map probe distance early-exit;
    per-column dense flags for mixed views.

    Measured dead end (do not re-attempt without new evidence): an "unchecked"
    get_component that skips entity validation showed zero gain at N=100K and
    N=1M — the validation load and the component lookup are independent, so the
    CPU overlaps them (memory-level parallelism); validation is effectively free.
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
    CHURN_N :: 10_000   // entities for churn/destroy scenarios
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
    both: ecs.View
    eids: []ecs.entity_id
    shuffled: []ecs.entity_id

    mixed_db: ecs.Database
    m_positions: ecs.Table(Position)
    m_velocities: ecs.Table(Velocity)
    m_both: ecs.View

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

    bench_get_random()
    bench_get_random_compact()
    bench_rebuild()

    bench_churn()

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

/*
    2025 (c) Oleh, https://github.com/zm69

    Compares the speed of three ways to iterate the same entities doing the same per-row work:
    View (alignment detected at runtime), Group (same tables but owned — alignment enforced, no
    per-row check, see docs/group.md), and Arch_Table (true per-column SoA storage, see
    docs/arch_table.md). Expect Arch_Table and Group to be fastest or close to it, since neither
    pays a runtime alignment check; View can land close behind here because Group's packing of
    its owned tables happens to also satisfy View's own alignment condition on the same tables.

    Run this sample with speed optimizations to see results closer to real-world performance:

    odin run . -o:speed
*/

package ode_ecs_sample3

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:log"
    import "core:slice"
    import "core:mem"
    import "core:math/rand"
    import "core:time"

// ODE_ECS
    import ecs "../../"
    import oc "../../ode_core"

//
// Components
//
    PAYLOAD_SIZE :: 5

    Position :: struct {
        x, y: int,
        payload: [PAYLOAD_SIZE]int,
    }
    AI :: struct {
        neurons_count: int,
        payload: [PAYLOAD_SIZE]int,
    }
    Physical :: struct {
        velocity, mass: f32,
        payload: [PAYLOAD_SIZE]int,
    }
    Component :: struct {
        payload: [PAYLOAD_SIZE]int,
    }
    Component_2 :: struct {
        payload: [PAYLOAD_SIZE]int,
    }
    Component_3 :: struct {
        payload: [PAYLOAD_SIZE]int,
    }
    Component_4 :: struct {
        payload: [PAYLOAD_SIZE]int,
    }

//
// Globals
    db: ecs.Database

    positions : ecs.Table(Position)
    ais : ecs.Table(AI)
    physics: ecs.Table(Physical)
    comps_1: ecs.Table(Component)
    comps_2: ecs.Table(Component_2)
    comps_3: ecs.Table(Component_3)
    comps_4: ecs.Table(Component_4)

    physical: ecs.View

    // Owns the same 6 tables as `physical` — enforced alignment instead of detected. See docs/group.md.
    physical_group: ecs.Group

    // All possible components combinations for generating random entities
    g_combo_choice: [7][3]int = {{ 1, 2, 3 }, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}, {1, 2, 0}, {1, 3, 0}, {2, 3, 0}}

    // Real archetype table, for comparison against the View approach above
    arch: ecs.Arch_Table

//
// This example includes simple error handling.
//
main :: proc() {

    //
    // OPTIONAL: Setup memory tracking and logger.
    //
        mem_track: oc.Mem_Track

        context.allocator = oc.mem_track__init(&mem_track, context.allocator)
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track) // Defers run in reverse declaration order

        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        // Panic allocator ensures no allocations happen outside the provided allocator
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

    //
    // Actual ODE_ECS sample starts here.
        err: ecs.Error

    //
    // Init
        defer {
            err = ecs.terminate(&db)
            if err != nil do report_error(err)
        }
        err = ecs.init(&db, 100_000, allocator)
        if err != nil { report_error(err); return }

        // Init tables
        err = ecs.table_init(&positions, &db, 100_000)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&ais, &db, 100_000)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&physics, &db, 100_000)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&comps_1, &db, 100_000)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&comps_2, &db, 100_000)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&comps_3, &db, 100_000)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&comps_4, &db, 100_000)
        if err != nil { report_error(err); return }

        // Init views
        err = ecs.view_init(&physical, &db, {&positions, &comps_1, &comps_2, &comps_3, &comps_4, &physics})
        if err != nil { report_error(err); return }

        // Same 6 tables as `physical` — a table can be owned by a Group and included in a View at once (see Sample14)
        err = ecs.group_init(&physical_group, &db, {&positions, &comps_1, &comps_2, &comps_3, &comps_4, &physics})
        if err != nil { report_error(err); return }

        // Same 6 types as `physical`/`physical_group`; iteration below only reads Position/Physical,
        // and since Arch_Table stores columns SoA, the other 4 columns cost nothing extra to skip.
        err = ecs.arch_table__init(&arch, &db, cap = 100_000, component_types = {Position, Component, Component_2, Component_3, Component_4, Physical})
        if err != nil { report_error(err); return }

    //
    // Systems
        iterate_over_view :: proc(view: ^ecs.View, positions: ^ecs.Table(Position), physics: ^ecs.Table(Physical)) {
            err: ecs.Error
            it: ecs.Iterator

            err = ecs.iterator_init(&it, view)
            if err != nil { report_error(err); return }

            for _, pos, ph in ecs.next(&it, positions, physics) {
                pos.x += it.raw_index
                pos.y += it.raw_index

                ph.velocity += cast(f32) it.raw_index
                ph.mass += cast(f32) it.raw_index
            }
        }

        iterate_over_ai_table :: proc (table: ^ecs.Table(AI)) {
            for &ai, index in ecs.slice(table) {
                ai.neurons_count += index
            }
        }

        iterate_over_archetype :: proc(arch: ^ecs.Arch_Table) {
            err: ecs.Error
            it: ecs.Arch_Iterator

            err = ecs.arch_iterator_init(&it, arch)
            if err != nil { report_error(err); return }

            for _, pos, ph in ecs.next(&it, Position, Physical) {
                pos.x += it.index
                pos.y += it.index

                ph.velocity += cast(f32) it.index
                ph.mass += cast(f32) it.index
            }
        }

        iterate_over_group :: proc(group: ^ecs.Group, positions: ^ecs.Table(Position), physics: ^ecs.Table(Physical)) {
            // Alignment is enforced by the Group, not detected — no check, no unaligned fallback needed
            pos_slice := ecs.slice(group, positions)
            ph_slice := ecs.slice(group, physics)

            for i in 0..<len(pos_slice) {
                pos_slice[i].x += i
                pos_slice[i].y += i

                ph_slice[i].velocity += cast(f32) i
                ph_slice[i].mass += cast(f32) i
            }
        }

    //
    // Game load: create 100,000 entities with random components
    //
        create_entities_with_random_components_and_data(100_000, true)

    tt: Time_Track
    step_1_view_len: int
    for j:=0; j < EXECUTE_TIMES; j+=1 {
        //
        // Frame zero: iterate over table only
        //
        sw: time.Stopwatch
        time.stopwatch_start(&sw)

            iterate_over_ai_table(&ais)

        time.stopwatch_stop(&sw)

        _, _, _, tt.table[j] = time.precise_clock_from_stopwatch(sw)

        //
        // Frame one: iterate over view
        //
            step_1_view_len = ecs.view_len(&physical)
            time.stopwatch_reset(&sw)
            time.stopwatch_start(&sw)

                iterate_over_view(&physical, &positions, &physics)

            time.stopwatch_stop(&sw)

            _, _, _, tt.view[j] = time.precise_clock_from_stopwatch(sw)

        //
        // Frame two: iterate over Arch_Table
        //
            time.stopwatch_reset(&sw)
            time.stopwatch_start(&sw)

                iterate_over_archetype(&arch)

            time.stopwatch_stop(&sw)

            _, _, _, tt.arch[j] = time.precise_clock_from_stopwatch(sw)

        //
        // Frame three: iterate over Group
        //
            time.stopwatch_reset(&sw)
            time.stopwatch_start(&sw)

                iterate_over_group(&physical_group, &positions, &physics)

            time.stopwatch_stop(&sw)

            _, _, _, tt.group[j] = time.precise_clock_from_stopwatch(sw)
    }

    //
    // Print results
    //
        avg_table := tt__avg_table(&tt)
        avg_view := tt__avg_view(&tt)
        avg_arch := tt__avg_arch(&tt)
        avg_group := tt__avg_group(&tt)

        s:= oc.add_thousand_separator(ecs.database__entities_len(&db), sep=',', allocator=allocator)
        fmt.printfln("%-30s %s", "Entities count:", s)
        delete(s, allocator)

        fmt.printfln("%-30s %v bytes", "Position component size:", size_of(Position))
        fmt.printfln("%-30s %v bytes", "Physical component size:", size_of(Physical))
        fmt.printfln("%-30s %v bytes", "AI component size:", size_of(AI))
        fmt.printfln("%-30s %v bytes", "Component component size:", size_of(Component))

        fmt.printfln("%-30s %.2f MB", "Total memory usage:", f64(ecs.memory_usage(&db)) / f64(runtime.Megabyte))
        fmt.println("-----------------------------------------------------------")
        s = oc.add_thousand_separator(ecs.table_len(&ais), sep=',', allocator=allocator)
        fmt.printfln("%-30s %.4f ms (%v rows)", "Iterating over `ais` table:", f64(avg_table)/1_000_000.0, s)
        delete(s, allocator)

        s = oc.add_thousand_separator(step_1_view_len, sep=',', allocator=allocator)
        fmt.printfln("%-30s %.4f ms (%v rows)", "Iterating over view:", f64(avg_view)/1_000_000.0, s)
        delete(s, allocator)

        s = oc.add_thousand_separator(ecs.table_len(&arch), sep=',', allocator=allocator)
        fmt.printfln("%-30s %4f ms (%v rows)", "Iterating over Arch_Table:", f64(avg_arch)/1_000_000.0, s)
        delete(s, allocator)

        s = oc.add_thousand_separator(ecs.group_len(&physical_group), sep=',', allocator=allocator)
        fmt.printfln("%-30s %4f ms (%v rows)", "Iterating over Group:", f64(avg_group)/1_000_000.0, s)
        delete(s, allocator)

        fmt.println("-----------------------------------------------------------")
        fastest := min(avg_view, avg_arch, avg_group)
        fmt.printfln("%-30s x %.2f", "View vs fastest:", f64(avg_view) / f64(fastest))
        fmt.printfln("%-30s x %.2f", "Arch_Table vs fastest:", f64(avg_arch) / f64(fastest))
        fmt.printfln("%-30s x %.2f", "Group vs fastest:", f64(avg_group) / f64(fastest))
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

create_entities_with_random_components_and_data :: proc(number_of_components_to_create: int, create_arch:= false) {
    pos: ^Position
    ph: ^Physical
    ai: ^AI
    err: ecs.Error

    eid: ecs.entity_id
    eid_components_count: int
    for i:=0; i < number_of_components_to_create; i+=1 {
        eid, err = ecs.database__create_entity(&db)
        if err != nil { report_error(err); return }

        combo := rand.choice(g_combo_choice[:])

        for j:=0; j<3; j+=1 {
            switch combo[j] {
                case 0:
                    break
                case 1:
                    pos, err = ecs.add_component(&positions, eid)
                    if err != nil { report_error(err); fmt.println(eid); return }
                    // pos.x = int(rand.int63()) % 1920
                    // pos.y = int(rand.int63()) % 1080
                    pos.x = i * j
                    pos.y = i
                case 2:
                    ai, err = ecs.add_component(&ais, eid)
                    if err != nil { report_error(err); fmt.println(eid); return }
                    ai.neurons_count = j
                case 3:
                    ph, err = ecs.add_component(&physics, eid)
                    if err != nil { report_error(err); return }
                    ph.mass = (f32)(j + i * j)
            }
        }

        if slice.contains(combo[:], 1) && slice.contains(combo[:], 3) {

            _, err = ecs.add_component(&comps_1, eid)
            if err != nil { report_error(err); return }

            _, err = ecs.add_component(&comps_2, eid)
            if err != nil { report_error(err); return }

            _, err = ecs.add_component(&comps_3, eid)
            if err != nil { report_error(err); return }

            _, err = ecs.add_component(&comps_4, eid)
            if err != nil { report_error(err); return }

            if create_arch {
                aerr := ecs.arch_table__add_entity(&arch, eid)
                if aerr != nil { report_error(aerr); return }

                pos = ecs.get_component(&arch, eid, Position)
                pos.x = i
                pos.y = i

                ph = ecs.get_component(&arch, eid, Physical)
                ph.mass = (f32)(i)

                if ecs.view_len(&physical) != ecs.table_len(&arch) {
                    fmt.println(i, combo)
                }
            }
        } // if

    } // for
}

destroy_entities_in_range :: proc(start_ix, end_ix: int) {
    assert(end_ix > start_ix)
    assert(start_ix >= 0)

    for i:=start_ix; i < end_ix; i+=1 {
        eid := ecs.get_entity(&db, i)
        ecs.database__destroy_entity(&db, eid)
    }
}

//////////////////////////////////////////////////////////////////////////////////
// Time tracking
    EXECUTE_TIMES :: 10

    Time_Track :: struct {
        table: [EXECUTE_TIMES] int,
        view: [EXECUTE_TIMES] int,
        arch: [EXECUTE_TIMES] int,
        group: [EXECUTE_TIMES] int,
    }

    tt__avg_table :: proc(self: ^Time_Track) -> int {
        sum : int = 0
        for i:=0; i < EXECUTE_TIMES; i+=1 {
            sum += self.table[i]
        }

        return sum/EXECUTE_TIMES
    }

    tt__avg_view :: proc(self: ^Time_Track) -> int {
        sum : int = 0
        for i:=0; i < EXECUTE_TIMES; i+=1 {
            sum += self.view[i]
        }

        return sum/EXECUTE_TIMES
    }

    tt__avg_arch :: proc(self: ^Time_Track) -> int {
        sum : int = 0
        for i:=0; i < EXECUTE_TIMES; i+=1 {
            sum += self.arch[i]
        }

        return sum/EXECUTE_TIMES
    }

    tt__avg_group :: proc(self: ^Time_Track) -> int {
        sum : int = 0
        for i:=0; i < EXECUTE_TIMES; i+=1 {
            sum += self.group[i]
        }

        return sum/EXECUTE_TIMES
    }

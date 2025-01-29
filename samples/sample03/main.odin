/*
    2025 (c) Oleh, https://github.com/zm69

    I wasn't sure whether to develop an Archetype architecture for ODE_ECS or continue using the View approach.
    So, I created this sample to compare the speed of the View approach to a "realistic" Archetype approach.

    Result: The Archetype approach is not worth it. Views are about x2 times faster on my PC.
    Even if the Archetype approach were as fast as the View approach, the View approach has other advantages.

    Run this sample with speed optimization to see times closer to real-world performance:

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
    import "core:math"
    import "core:math/rand"
    import "core:time"
    import "core:testing"
     

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

    Component_2 :: Component
    Component_3 :: Component
    Component_4 :: Component

// 
// Globals
// 
    // ECS Database
    db: ecs.Database

    // Component tables
    positions : ecs.Table(Position)
    ais : ecs.Table(AI)
    physics: ecs.Table(Physical)
    comps_1: ecs.Table(Component)
    comps_2: ecs.Table(Component)
    comps_3: ecs.Table(Component)
    comps_4: ecs.Table(Component)
    
    // Views
    physical: ecs.View 

    // All possible components combinations for generating random entities
    g_combo_choice: [7][3]int = {{ 1, 2, 3 }, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}, {1, 2, 0}, {1, 3, 0}, {2, 3, 0}}

    // Experimental
    arch: Arch

//
// This example includes simple error handing.
//
main :: proc() {

    //
    // OPTIONAL: Setup memory tracking and logger. 
    //
        mem_track: oc.Mem_Track

        // Track memory leaks and bad frees
        context.allocator = oc.mem_track__init(&mem_track, context.allocator)  
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track) // Defer statements are executed in the reverse order that they were declared

        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        // Replace default allocator with panic allocator to make sure that  
        // no allocations happen outside of provided allocator
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

    //
    // Actual ODE_ECS sample starts here.
    //

        //
        // Simple error handling
        //
        err: ecs.Error

    //
    // Init 
    //
       
        // Init database
        defer { 
            err = ecs.terminate(&db) 
            if err != nil do report_error(err)
        }
        err = ecs.init(&db, 100_000, allocator) // Maximum 100K entities
        if err != nil { report_error(err); return }
        
        // Init tables
        err = ecs.table_init(&positions, &db, 100_000) // Maximum 100K position components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&ais, &db, 100_000) // Maximum 20K AI components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&physics, &db, 100_000) // Maximum 70K position components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&comps_1, &db, 100_000) // Maximum 70K position components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&comps_2, &db, 100_000) // Maximum 70K position components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&comps_3, &db, 100_000) // Maximum 70K position components
        if err != nil { report_error(err); return }

        err = ecs.table_init(&comps_4, &db, 100_000) // Maximum 70K position components
        if err != nil { report_error(err); return }

        // Init views
        err = ecs.view_init(&physical, &db, {&positions, &comps_1, &comps_2, &comps_3, &comps_4, &physics})
        if err != nil { report_error(err); return }

        defer arch__terminate(&arch, allocator)

        arch__init(&arch, 100_000, { Position, Component, Component_2, Component_3, Component_4, Physical }, allocator)

    //
    // Systems
    //

        iterate_over_view :: proc(view: ^ecs.View, positions: ^ecs.Table(Position), physics: ^ecs.Table(Physical)) {
            pos: ^Position
            ph: ^Physical
            err: ecs.Error
            it: ecs.Iterator

            err = ecs.iterator_init(&it, view)
            if err != nil { report_error(err); return }

            for ecs.iterator_next(&it) {

                // Doing some calculations on components

                pos = ecs.get_component(positions, &it)
                pos.x += it.raw_index
                pos.y += it.raw_index

                ph = ecs.get_component(physics, &it)
                ph.velocity += cast(f32) it.raw_index
                ph.mass += cast(f32) it.raw_index
            }
        }

        iterate_over_ai_table :: proc (table: ^ecs.Table(AI)) {
            for &ai, index in table.rows {
                // Doing some calculations on components
                ai.neurons_count += index
            }
        }     
        
        iterate_over_archetype :: proc(arch: ^Arch) {
            pos: ^Position
            ph: ^Physical
            for i := 0; i < arch__len(arch); i+=1 {

                pos = arch__get_component(arch, i, Position)
                pos.x += i
                pos.y += i

                ph = arch__get_component(arch, i, Physical)
                ph.velocity += cast(f32) i
                ph.mass += cast(f32) i
            }
        }

        iterate_over_archetype_with_iterator :: proc(arch: ^Arch) {
            pos: ^Position
            ph: ^Physical

            it: Arch_Iterator
            arch_iterator__init(&it, arch)
            for arch_iterator__next(&it) {
                pos = arch_iterator__get_component(&it, Position)
                pos.x += it.record_shift
                pos.y += it.record_shift

                ph = arch_iterator__get_component(&it, Physical)
                ph.velocity += cast(f32) it.record_shift
                ph.mass += cast(f32) it.record_shift
            }

        }

    //
    // Game load, create 100_000 entities with random components
    // 
        create_entities_with_random_components_and_data(100_000, true)

    tt: Time_Track
    step_1_view_len: int
    for j:=0; j < EXECUTE_TIMES; j+=1 {
        //
        //  Game loop, frame zero, iterating over table only
        // 
        sw: time.Stopwatch
        time.stopwatch_start(&sw)

            iterate_over_ai_table(&ais) 

        time.stopwatch_stop(&sw)

        _, _, _, tt.table[j] = time.precise_clock_from_stopwatch(sw)

        //
        //  Game loop, frame one, iterating over view 
        // 
        
            step_1_view_len = ecs.view_len(&physical)
            time.stopwatch_reset(&sw)
            time.stopwatch_start(&sw)

                iterate_over_view(&physical, &positions, &physics)

            time.stopwatch_stop(&sw)

            _, _, _, tt.view[j] = time.precise_clock_from_stopwatch(sw)
            
        //
        //  Game loop, frame two, iterating over archetype  
        // 
        
            time.stopwatch_reset(&sw)
            time.stopwatch_start(&sw)

                iterate_over_archetype_with_iterator(&arch)

            time.stopwatch_stop(&sw)

            _, _, _, tt.arch[j] = time.precise_clock_from_stopwatch(sw)
    }

    //
    // Print results
    //
        avg_table := tt__avg_table(&tt)
        avg_view := tt__avg_view(&tt)
        avg_arch := tt__avg_arch(&tt)

        s:= oc.add_thousand_separator(ecs.database__entities_len(&db), sep=',', allocator=allocator)
        fmt.printfln("%-30s %s", "Entities count:", s)
        delete(s, allocator)
        
        fmt.printfln("%-30s %v bytes", "Position component size:", size_of(Position))
        fmt.printfln("%-30s %v bytes", "Physical component size:", size_of(Physical))
        fmt.printfln("%-30s %v bytes", "AI component size:", size_of(AI))
        fmt.printfln("%-30s %v bytes", "Component component size:", size_of(Component))

        fmt.printfln("%-30s %v MB", "Total memory usage:", ecs.memory_usage(&db) / runtime.Megabyte)
        fmt.println("-----------------------------------------------------------")
        s = oc.add_thousand_separator(ecs.table_len(&ais), sep=',', allocator=allocator)
        fmt.printfln("%-30s %.2f ms (%v rows)", "Iterating over `ais` table:", f64(avg_table)/1_000_000.0, s)
        delete(s, allocator)

        s = oc.add_thousand_separator(step_1_view_len, sep=',', allocator=allocator)
        fmt.printfln("%-30s %.2f ms (%v rows)", "Iterating over view:", f64(avg_view)/1_000_000.0, s)
        delete(s, allocator)

        s = oc.add_thousand_separator(arch__len(&arch), sep=',', allocator=allocator)
        fmt.printfln("%-30s %.2f ms (%v rows)", "Iterating over archetype:", f64(avg_arch)/1_000_000.0, s)
        delete(s, allocator)

        d: f64
        if avg_view < avg_arch {
            d = f64(avg_arch) / f64(avg_view)
            fmt.printfln("%-30s x %.2f times faster than archetype", "View is:", d)
        } else {
            d = f64(avg_view) / f64(avg_arch)
            fmt.printfln("%-30s x %.2f times faster than view", "Archetype is:", d)
        }
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}

create_entities_with_random_components_and_data :: proc(number_of_components_to_create: int, create_arch:= false) {
    pos: ^Position
    ph: ^Physical
    co: ^Component
    ai: ^AI
    err: ecs.Error

    eid: ecs.entity_id
    eid_components_count: int
    for i:=0; i < number_of_components_to_create; i+=1 {
        eid, err = ecs.database__create_entity(&db)
        if err != nil { report_error(err); return }

        // Randomly chose what components combo we want for entity
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

            co, err = ecs.add_component(&comps_1, eid)
            if err != nil { report_error(err); return } 

            co, err = ecs.add_component(&comps_2, eid)
            if err != nil { report_error(err); return } 

            co, err = ecs.add_component(&comps_3, eid)
            if err != nil { report_error(err); return } 

            co, err = ecs.add_component(&comps_4, eid)
            if err != nil { report_error(err); return } 

            if create_arch {
                ii := arch__add_components(&arch)
                pos = arch__get_component(&arch, ii, Position)
                pos.x = i 
                pos.y = i

                ph = arch__get_component(&arch, ii, Physical)
                ph.mass = (f32)(i)
          
                if ecs.view_len(&physical) != arch__len(&arch) {
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
// Experimental "realistic" implementation of Archetype.
// By "realistic," I mean an implementation where component types are not known during development.

    Comp_Info :: struct {
        type_info: ^runtime.Type_Info,
        shift: int, 
    }

    Arch :: struct {
        rows: []byte,
        one_record_size: int, 
        records_size: int, 
        cap: int,
        id_to_info: map[typeid]Comp_Info,
        components: []typeid,
    }

    arch__init :: proc(self: ^Arch, cap: int, components: []typeid, allocator := context.allocator) -> mem.Allocator_Error {

        self.cap = cap
        self.id_to_info = make_map_cap(map[typeid]Comp_Info, 100, allocator)
        self.components = components

        shift:int = 0
        ci: Comp_Info
        for comp in components {
            if comp == nil do continue

            ci.type_info = type_info_of(comp)
            ci.shift = shift
            shift += ci.type_info.size

            self.id_to_info[comp] = ci
        }

        self.one_record_size = shift

        raw := (^runtime.Raw_Slice)(&self.rows)

        raw.data = mem.alloc(self.one_record_size * cap, allocator=allocator) or_return
        raw.len = 0

        return nil
    }

    arch__terminate :: proc(self: ^Arch,  allocator := context.allocator) {
        raw := (^runtime.Raw_Slice)(&self.rows)
        mem.free(raw.data, allocator)
        delete_map(self.id_to_info)
        raw.data = nil
        raw.len = 0
    }

    arch__add_components :: proc(self: ^Arch) -> int {
        raw := (^runtime.Raw_Slice)(&self.rows)
        i := raw.len 
        raw.len += 1
        return i
    }

    arch__get_component :: proc(self: ^Arch, index: int, $T: typeid) -> ^T {

        base := index * self.one_record_size
        ci := self.id_to_info[T]
         
        #no_bounds_check {
            return (^T)(&self.rows[base + ci.shift])
        }
    }

    arch__len :: proc (self: ^Arch) -> int {
        return len(self.rows)
    }

    // Arch_Iterator, to cache during iteration and hopefully speed things up
    Arch_Iterator :: struct {
        arch: ^Arch,
        record_shift: int,
        one_record_size: int, 
        records_len: int, 
    }

    arch_iterator__init :: proc (self: ^Arch_Iterator, arch: ^Arch) {
        self.arch = arch
        self.record_shift = -arch.one_record_size
        self.one_record_size = arch.one_record_size
        self.records_len = len(arch.rows) * self.one_record_size
    }   

    arch_iterator__next :: proc(self: ^Arch_Iterator) -> bool {
        self.record_shift += self.one_record_size
        if self.record_shift >= self.records_len do return false

        return true
    }

    arch_iterator__get_component :: proc(self: ^Arch_Iterator, $T: typeid) -> ^T {
        ci := self.arch.id_to_info[T]
         
        #no_bounds_check {
            return (^T)(&self.arch.rows[self.record_shift + ci.shift])
        }
    }


    @(test)
    archetype__test :: proc(t: ^testing.T) {
        a: Arch
        defer arch__terminate(&a)
        arch__init(&a, 10, {Position, Physical, AI})

        ci := a.id_to_info[Position]
        testing.expect(t, ci.type_info == type_info_of(Position))
        testing.expect(t, ci.shift == 0)

        ci = a.id_to_info[Physical]
        testing.expect(t, ci.type_info == type_info_of(Physical))
        testing.expect(t, ci.shift == size_of(Position))

        ci = a.id_to_info[AI]
        testing.expect(t, ci.type_info == type_info_of(AI))
        testing.expect(t, ci.shift == (size_of(Position) + size_of(Physical)))

        pos: ^Position
        ai: ^AI
        ph: ^Physical

        ii := arch__add_components(&a) 
            ph = arch__get_component(&a, ii , Physical)
            ph.mass = 2.0

            pos = arch__get_component(&a, ii, Position)
            pos.y = 66

            ai = arch__get_component(&a, ii, AI)
            ai.neurons_count = 55

           
        ii = arch__add_components(&a)
            ph = arch__get_component(&a, ii , Physical)
            ph.mass = 3.0

            pos = arch__get_component(&a, ii, Position)
            pos.y = 68

            ai = arch__get_component(&a, ii, AI)
            ai.neurons_count = 52

        ii = arch__add_components(&a)
            ph = arch__get_component(&a, ii , Physical)
            ph.mass = 35.0

            pos = arch__get_component(&a, ii, Position)
            pos.y = 665

            ai = arch__get_component(&a, ii, AI)
            ai.neurons_count = 552
        
        ai = arch__get_component(&a, 1, AI)
        testing.expect(t, ai.neurons_count == 52)

        ai = arch__get_component(&a, 2, AI)
        testing.expect(t, ai.neurons_count == 552)

        ai = arch__get_component(&a, 0, AI)
        testing.expect(t, ai.neurons_count == 55)

        pos = arch__get_component(&a, 2, Position)
        testing.expect(t, pos.y == 665)

        pos = arch__get_component(&a, 0, Position)
        testing.expect(t, pos.y == 66)

        ph = arch__get_component(&a, 2, Physical)
        testing.expect(t, math.abs(ph.mass - 35.0) < 0.1)
    }

//////////////////////////////////////////////////////////////////////////////////
// Time tracking

    EXECUTE_TIMES :: 10

    Time_Track :: struct {
        table: [EXECUTE_TIMES] int,
        view: [EXECUTE_TIMES] int,
        arch: [EXECUTE_TIMES] int,
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


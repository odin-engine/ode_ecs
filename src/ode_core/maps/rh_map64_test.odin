/*
    2026 (c) Oleh, https://github.com/zm69
*/
#+build !js
package maps

// Core
    import "core:log"
    import "core:mem"
    import "core:math"
    import "core:math/rand"
    import "core:testing"

// ODE_CORE
    import oc ".."

    @(test)
    rh_map64__test :: proc(t: ^testing.T) {
        when !MAPS_TESTING {
            log.warn("rh_map64__test skipped: slot-placement test needs -define:maps_testing=true")
            return
        }


        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        m: Rh_Map64
        testing.expect(t, rh_map64__init(&m, 3, allocator) == oc.Core_Error.Capacity_Is_Not_Power_Of_2)
        testing.expect(t, rh_map64__init(&m, 8, allocator) == nil)
        defer rh_map64__terminate(&m, allocator)

        // 16, 32, 64 hash to 0; 1, 17 to 1; 2 to 2
        testing.expect(t, rh_map64__add(&m, 16, 100) == nil)
        testing.expect(t, rh_map64__add(&m, 1, 101) == nil)
        testing.expect(t, rh_map64__add(&m, 17, 102) == nil)
        testing.expect(t, rh_map64__add(&m, 2, 103) == nil)
        testing.expect(t, rh_map64__add(&m, 32, 104) == nil)
        testing.expect(t, rh_map64__add(&m, 64, 105) == nil)

        testing.expect(t, m.items[0].value == 100)
        testing.expect(t, m.items[1].value == 104)
        testing.expect(t, m.items[2].value == 105)
        testing.expect(t, m.items[3].value == 101)
        testing.expect(t, m.items[4].value == 102)
        testing.expect(t, m.items[5].value == 103)

        testing.expect(t, rh_map64__get(&m, 8) == RH_MAP64_NOT_FOUND)
        testing.expect(t, rh_map64__get(&m, 24) == RH_MAP64_NOT_FOUND)

        testing.expect(t, rh_map64__remove(&m, 1) == nil)
        testing.expect(t, rh_map64__get(&m, 17) == 102)
        testing.expect(t, rh_map64__get(&m, 2) == 103)
        testing.expect(t, rh_map64__get(&m, 32) == 104)
        testing.expect(t, rh_map64__get(&m, 64) == 105)
        testing.expect(t, m.count == 5)
    }

    @(test)
    rh_map64__behavior__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        m: Rh_Map64
        testing.expect(t, rh_map64__init(&m, 64, allocator) == nil)
        defer rh_map64__terminate(&m, allocator)
        testing.expect(t, rh_map64__is_valid(&m))

        limit := m.max_count
        key_of :: proc(i: int) -> u64 { return u64(i) * 0x9E3779B97F4A7C15 + 13 }

        for i in 0..<limit do testing.expect(t, rh_map64__add(&m, key_of(i), u32(i)) == nil)
        testing.expect(t, m.count == limit)
        testing.expect(t, rh_map64__add(&m, key_of(limit), 0) == oc.Core_Error.Container_Is_Full)
        for i in 0..<limit do testing.expect(t, rh_map64__get(&m, key_of(i)) == u32(i))
        testing.expect(t, rh_map64__get(&m, key_of(limit)) == RH_MAP64_NOT_FOUND)

        for i := 0; i < limit; i += 3 do testing.expect(t, rh_map64__remove(&m, key_of(i)) == nil)
        for i in 0..<limit {
            expected := i % 3 == 0 ? RH_MAP64_NOT_FOUND : u32(i)
            testing.expect(t, rh_map64__get(&m, key_of(i)) == expected)
        }
        testing.expect(t, rh_map64__remove(&m, key_of(0)) == oc.Core_Error.Not_Found)

        rh_map64__clear(&m)
        testing.expect(t, m.count == 0)
        testing.expect(t, rh_map64__get(&m, key_of(1)) == RH_MAP64_NOT_FOUND)
    }

    @(test)
    rh_map64__random__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        state := rand.create(u64(1234))
        context.random_generator = rand.default_random_generator(&state)

        for cap in ([]int{8, 64, 1024}) {
            m: Rh_Map64
            testing.expect(t, rh_map64__init(&m, cap, allocator) == nil)
            ref := make(map[u64]u32, allocator = allocator)
            universe := u64(cap * 3)

            for step in 0..<50_000 {
                k := u64(rand.int_max(int(universe))) * 0x9E3779B97F4A7C15
                if rand.int_max(3) == 0 {
                    err := rh_map64__remove(&m, k)
                    _, had := ref[k]
                    testing.expect(t, (err == nil) == had)
                    delete_key(&ref, k)
                } else {
                    if rh_map64__add(&m, k, u32(step)) == nil do ref[k] = u32(step)
                }
                if step % 101 == 0 {
                    for q in 0..<universe {
                        key := q * 0x9E3779B97F4A7C15
                        v, had := ref[key]
                        testing.expect(t, rh_map64__get(&m, key) == (had ? v : RH_MAP64_NOT_FOUND))
                    }
                }
                testing.expect(t, m.count == len(ref))
            }

            delete(ref)
            rh_map64__terminate(&m, allocator)
        }
    }

/*
    2026 (c) Oleh, https://github.com/zm69
*/
package maps_tests

// Core
    import "core:log"
    import "core:mem"
    import "core:math"
    import "core:testing"

// ODE_CORE
    import oc "../.."
    import maps "../../maps"

    @(test)
    rh_map32__test :: proc(t: ^testing.T) {
        // Needs the predictable identity hash for exact slot placement; skip
        // in production-hash mode (behavioral coverage lives in rh_map32__behavior__test).
        when !maps.MAPS_TESTING {
            log.warn("rh_map32__test skipped: slot-placement test needs -define:maps_testing=true")
            return
        }


        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        //
        // make sure we are using the simplified hash function for testing
        //
        testing.expect(t, maps.rh_map32__hash(&maps.Rh_Map32{ capacity = 16, mask = 15 }, 0) == 0)
        testing.expect(t, maps.rh_map32__hash(&maps.Rh_Map32{ capacity = 16, mask = 15 }, 17) == 1)

        //
        // basic add/get/update/remove
        //

        map1: maps.Rh_Map32

        testing.expect(t, maps.rh_map32__init(&map1, 3, allocator) == oc.Core_Error.Capacity_Is_Not_Power_Of_2)
        testing.expect(t, maps.rh_map32__init(&map1, 8, allocator) == nil)

        testing.expect(t, map1.count == 0)
        testing.expect(t, map1.capacity == 8)
        testing.expect(t, map1.max_count == 8)
        testing.expect(t, map1.mask == 0b111)

        // collision cluster: 16, 32, 64 all hash to 0 (identity mod 8); 1, 17 to 1; 2 to 2
        testing.expect(t, maps.rh_map32__add(&map1, 16, 100) == nil)
        testing.expect(t, maps.rh_map32__add(&map1, 1, 101) == nil)
        testing.expect(t, maps.rh_map32__add(&map1, 17, 102) == nil)
        testing.expect(t, maps.rh_map32__add(&map1, 2, 103) == nil)
        testing.expect(t, maps.rh_map32__add(&map1, 32, 104) == nil)
        testing.expect(t, maps.rh_map32__add(&map1, 64, 105) == nil)

        // Robin Hood layout, the classic textbook example
        testing.expect(t, map1.items[0].value == 100)
        testing.expect(t, map1.items[1].value == 104)
        testing.expect(t, map1.items[2].value == 105)
        testing.expect(t, map1.items[3].value == 101)
        testing.expect(t, map1.items[4].value == 102)
        testing.expect(t, map1.items[5].value == 103)

        testing.expect(t, maps.rh_map32__get(&map1, 16) == 100)
        testing.expect(t, maps.rh_map32__get(&map1, 1) == 101)
        testing.expect(t, maps.rh_map32__get(&map1, 17) == 102)
        testing.expect(t, maps.rh_map32__get(&map1, 2) == 103)
        testing.expect(t, maps.rh_map32__get(&map1, 32) == 104)
        testing.expect(t, maps.rh_map32__get(&map1, 64) == 105)

        // misses inside the cluster and on empty slots
        testing.expect(t, maps.rh_map32__get(&map1, 8) == maps.RH_MAP32_DELETED)
        testing.expect(t, maps.rh_map32__get(&map1, 24) == maps.RH_MAP32_DELETED)
        testing.expect(t, maps.rh_map32__get(&map1, 7) == maps.RH_MAP32_DELETED)
        testing.expect(t, maps.rh_map32__remove(&map1, 8) == oc.Core_Error.Not_Found)

        // update existing keys (both via add and via update)
        testing.expect(t, maps.rh_map32__add(&map1, 16, 200) == nil)
        testing.expect(t, maps.rh_map32__get(&map1, 16) == 200)
        testing.expect(t, map1.count == 6)
        testing.expect(t, maps.rh_map32__update(&map1, 2, 203) == nil)
        testing.expect(t, maps.rh_map32__get(&map1, 2) == 203)
        testing.expect(t, maps.rh_map32__update(&map1, 9, 1) == oc.Core_Error.Not_Found)

        // fill to capacity, then overflow
        testing.expect(t, maps.rh_map32__add(&map1, 7, 106) == nil)
        testing.expect(t, maps.rh_map32__add(&map1, 15, 107) == nil)
        testing.expect(t, maps.rh_map32__add(&map1, 18, 108) == oc.Core_Error.Container_Is_Full)

        // remove with backward shift keeps the rest findable
        testing.expect(t, maps.rh_map32__remove(&map1, 1) == nil)
        testing.expect(t, maps.rh_map32__get(&map1, 1) == maps.RH_MAP32_DELETED)
        testing.expect(t, maps.rh_map32__get(&map1, 17) == 102)
        testing.expect(t, maps.rh_map32__get(&map1, 2) == 203)
        testing.expect(t, maps.rh_map32__get(&map1, 32) == 104)
        testing.expect(t, maps.rh_map32__get(&map1, 64) == 105)
        testing.expect(t, maps.rh_map32__get(&map1, 15) == 107)
        testing.expect(t, map1.count == 7)

        // reuse the freed slot
        testing.expect(t, maps.rh_map32__add(&map1, 40, 109) == nil)
        testing.expect(t, maps.rh_map32__get(&map1, 40) == 109)

        maps.rh_map32__clear(&map1)
        testing.expect(t, map1.count == 0)
        testing.expect(t, maps.rh_map32__get(&map1, 16) == maps.RH_MAP32_DELETED)
        testing.expect(t, maps.rh_map32__get(&map1, 40) == maps.RH_MAP32_DELETED)

        //
        // get_or_insert
        //

        // miss + can_insert=true -> inserts and reports found=false
        v, found, gerr := maps.rh_map32__get_or_insert(&map1, 16, 999, true)
        testing.expect(t, v == 999 && found == false && gerr == nil)
        testing.expect(t, map1.count == 1)
        testing.expect(t, maps.rh_map32__get(&map1, 16) == 999)

        // hit -> returns the existing value untouched, regardless of insert_value
        v, found, gerr = maps.rh_map32__get_or_insert(&map1, 16, 111, true)
        testing.expect(t, v == 999 && found == true && gerr == nil)
        testing.expect(t, map1.count == 1)
        testing.expect(t, maps.rh_map32__get(&map1, 16) == 999) // unmodified

        // miss + can_insert=false -> no mutation, no error (external cap gate, not a map failure)
        v, found, gerr = maps.rh_map32__get_or_insert(&map1, 1, 222, false)
        testing.expect(t, v == 0 && found == false && gerr == nil)
        testing.expect(t, map1.count == 1)
        testing.expect(t, maps.rh_map32__get(&map1, 1) == maps.RH_MAP32_DELETED)

        // miss + can_insert=true now succeeds for the same key
        v, found, gerr = maps.rh_map32__get_or_insert(&map1, 1, 222, true)
        testing.expect(t, v == 222 && found == false && gerr == nil)
        testing.expect(t, map1.count == 2)

        // fill to the load-factor limit (max_count == capacity == 8 in test mode)
        for i := 2; i <= 7; i += 1 {
            v, found, gerr = maps.rh_map32__get_or_insert(&map1, u32(i + 100), u32(i), true)
            testing.expect(t, found == false && gerr == nil)
        }
        testing.expect(t, map1.count == 8)

        // full map: a hit still succeeds (found=true), no Container_Is_Full
        v, found, gerr = maps.rh_map32__get_or_insert(&map1, 16, 0, true)
        testing.expect(t, v == 999 && found == true && gerr == nil)

        // full map: a genuine miss is rejected without corrupting state
        v, found, gerr = maps.rh_map32__get_or_insert(&map1, 999, 1, true)
        testing.expect(t, v == 0 && found == false && gerr == oc.Core_Error.Container_Is_Full)
        testing.expect(t, map1.count == 8)

        testing.expect(t, maps.rh_map32__terminate(&map1, allocator) == nil)
    }

    // Asserts observable behavior only (never slot placement), so it runs in
    // both modes; without -define:maps_testing=true it exercises the
    // production Fibonacci hash, the default load factor, and the min-capacity-8 bump.
    @(test)
    rh_map32__behavior__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        // non-power-of-2 capacity is rejected
        bad: maps.Rh_Map32
        testing.expect(t, maps.rh_map32__init(&bad, 6, allocator) == oc.Core_Error.Capacity_Is_Not_Power_Of_2)

        // tiny capacity: production mode bumps to the 8 minimum
        tiny: maps.Rh_Map32
        testing.expect(t, maps.rh_map32__init(&tiny, 2, allocator) == nil)
        when maps.MAPS_TESTING {
            testing.expect(t, tiny.capacity == 2 && tiny.max_count == 2)
        } else {
            testing.expect(t, tiny.capacity == 8 && tiny.max_count == 8 * maps.RH_MAP32_LOAD_PCT / 100)
        }
        testing.expect(t, tiny.mask == tiny.capacity - 1)
        testing.expect(t, maps.rh_map32__terminate(&tiny, allocator) == nil)

        m: maps.Rh_Map32
        testing.expect(t, maps.rh_map32__init(&m, 64, allocator) == nil)
        defer maps.rh_map32__terminate(&m, allocator)
        testing.expect(t, m.count == 0)
        testing.expect(t, maps.rh_map32__memory_usage(&m) > 0)

        // fill to the load-factor limit with scattered keys (forces collisions
        // and wrap-around under any hash)
        limit := m.max_count

        key_of :: proc(i: int) -> u32 { return u32(i * 97 + 13) }

        for i in 0..<limit-1 {
            testing.expect(t, maps.rh_map32__add(&m, key_of(i), u32(i * 1000)) == nil)
        }
        testing.expect(t, m.count == limit - 1)

        // add on an existing key updates the value in place (count unchanged)
        testing.expect(t, maps.rh_map32__add(&m, key_of(0), 42) == nil)
        testing.expect(t, maps.rh_map32__get(&m, key_of(0)) == 42)
        testing.expect(t, m.count == limit - 1)

        // update; update of a missing key fails
        testing.expect(t, maps.rh_map32__update(&m, key_of(0), 0) == nil)
        testing.expect(t, maps.rh_map32__get(&m, key_of(0)) == 0)
        testing.expect(t, maps.rh_map32__update(&m, key_of(limit), 0) == oc.Core_Error.Not_Found)

        // full at the load-factor limit (the load check runs before the update-in-place scan)
        testing.expect(t, maps.rh_map32__add(&m, key_of(limit-1), u32((limit - 1) * 1000)) == nil)
        testing.expect(t, m.count == limit)
        testing.expect(t, maps.rh_map32__add(&m, key_of(limit), 0) == oc.Core_Error.Container_Is_Full)
        testing.expect(t, maps.rh_map32__add(&m, key_of(0), 42) == oc.Core_Error.Container_Is_Full)

        // every inserted key is retrievable; absent keys return the sentinel
        for i in 0..<limit do testing.expect(t, maps.rh_map32__get(&m, key_of(i)) == u32(i * 1000))
        testing.expect(t, maps.rh_map32__get(&m, key_of(limit)) == maps.RH_MAP32_DELETED)

        // remove every third key; backward shift must keep all survivors reachable
        removed_count := 0
        for i := 0; i < limit; i += 3 {
            testing.expect(t, maps.rh_map32__remove(&m, key_of(i)) == nil)
            removed_count += 1
        }
        testing.expect(t, m.count == limit - removed_count)
        for i in 0..<limit {
            if i % 3 == 0 {
                testing.expect(t, maps.rh_map32__get(&m, key_of(i)) == maps.RH_MAP32_DELETED)
            } else {
                testing.expect(t, maps.rh_map32__get(&m, key_of(i)) == u32(i * 1000))
            }
        }

        // removing an absent key fails; re-inserting removed keys works
        testing.expect(t, maps.rh_map32__remove(&m, key_of(0)) == oc.Core_Error.Not_Found)
        for i := 0; i < limit; i += 3 {
            testing.expect(t, maps.rh_map32__add(&m, key_of(i), u32(i * 1000)) == nil)
        }
        testing.expect(t, m.count == limit)
        for i in 0..<limit do testing.expect(t, maps.rh_map32__get(&m, key_of(i)) == u32(i * 1000))

        // clear resets and the map stays usable
        maps.rh_map32__clear(&m)
        testing.expect(t, m.count == 0)
        testing.expect(t, maps.rh_map32__get(&m, key_of(1)) == maps.RH_MAP32_DELETED)
        testing.expect(t, maps.rh_map32__add(&m, key_of(1), 7) == nil)
        testing.expect(t, maps.rh_map32__get(&m, key_of(1)) == 7)
    }

    @(test)
    rh_map32__is_valid__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        zero_value: maps.Rh_Map32
        testing.expect(t, maps.rh_map32__is_valid(&zero_value) == false)
        testing.expect(t, maps.rh_map32__is_valid(nil) == false)

        m: maps.Rh_Map32
        testing.expect(t, maps.rh_map32__init(&m, 8, allocator) == nil)
        testing.expect(t, maps.rh_map32__is_valid(&m))

        testing.expect(t, maps.rh_map32__terminate(&m, allocator) == nil)
        testing.expect(t, maps.rh_map32__is_valid(&m) == false)
    }

    @(test)
    rh_map32__grow__test :: proc(t: ^testing.T) {
        m: maps.Rh_Map32
        testing.expect(t, maps.rh_map32__init(&m, 8) == nil)
        defer maps.rh_map32__terminate(&m)

        key_of :: proc(i: int) -> u32 { return u32(i * 97 + 13) }
        for i in 0..<4 do testing.expect(t, maps.rh_map32__add(&m, key_of(i), u32(i)) == .None)

        testing.expect(t, maps.rh_map32__grow(&m, 4) == nil) // smaller: no-op
        testing.expect_value(t, m.capacity, 8)

        testing.expect(t, maps.rh_map32__grow(&m, 64) == nil)
        testing.expect_value(t, m.capacity, 64)
        testing.expect_value(t, m.count, 4)
        for i in 0..<4 do testing.expect_value(t, maps.rh_map32__get(&m, key_of(i)), u32(i))

        for i in 4..<32 do testing.expect(t, maps.rh_map32__add(&m, key_of(i), u32(i)) == .None)
        for i in 0..<32 do testing.expect_value(t, maps.rh_map32__get(&m, key_of(i)), u32(i))
    }

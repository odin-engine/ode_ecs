/*
    2026 (c) Oleh, https://github.com/zm69
*/
package maps

// Core
    import "core:log"
    import "core:mem"
    import "core:math"
    import "core:testing"

// ODE_CORE
    import oc ".."

///////////////////////////////////////////////////////////////////////////////
// Rh_Map32 - Robin Hood map with 8-byte items (u32 key -> u32 value).
//
// Same algorithm as Rh_Map, but an item is 8 bytes instead of 16, so twice as
// many probes fit in a cache line and the map's memory footprint halves.
// Made for eid.ix -> row-id indexes (Compact_Table): keys and values are
// bounded by entities/table capacity, which must fit in u32.
// RH_MAP32_DELETED (max(u32)) is reserved — it is both the empty-slot key
// marker and the "not found" return value.

    RH_MAP32_DELETED :: max(u32)

    Rh_Map32_Item :: struct {
        key: u32,
        value: u32,
    }

    Rh_Map32 :: struct {
        items: []Rh_Map32_Item,
        capacity: int,
        count: int,

        half_capacity: int,
        mask: int,
    }

    rh_map32__is_valid ::  #force_inline proc "contextless"(self: ^Rh_Map32) -> bool {
        if self == nil do return false
        if self.items == nil do return false
        if self.capacity <= 0 do return false
        if self.half_capacity <= 0 do return false
        if self.mask == 0 do return false

        return true
    }

    rh_map32__init :: proc(self: ^Rh_Map32, #any_int capacity: int, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)
        assert(capacity > 1, loc = loc)
        assert(capacity < int(max(u32)), loc = loc) // keys/values must fit in u32

        if !math.is_power_of_two(capacity) do return oc.Core_Error.Capacity_Is_Not_Power_Of_2
        self.capacity = capacity

        when !MAPS_TESTING {
            if self.capacity < 8 do self.capacity = 8
        }

        self.items = make([]Rh_Map32_Item, self.capacity, allocator) or_return

        rh_map32__clear(self)  // requires self.capacity to be set

        // derive from self.capacity (may have been bumped to the 8 minimum above),
        // otherwise part of the allocated items would never be probed
        when MAPS_TESTING {
            self.half_capacity = self.capacity
        } else {
            self.half_capacity = self.capacity / 2  // this is for 0.5 load factor
        }

        self.mask = self.capacity - 1

        return nil
    }

    rh_map32__terminate :: proc(self: ^Rh_Map32, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)

        delete(self.items, allocator) or_return
        self.items = nil

        self.capacity = 0
        self.count = 0

        self.half_capacity = 0
        self.mask = 0

        return nil
    }

    // Low-bits Fibonacci hash for power-of-2 capacity. Deliberately the low bits:
    // entity indexes are dense consecutive ints and (k * odd_constant) mod 2^n is a
    // bijection on any aligned power-of-2 key range — zero collisions for the common
    // key distributions (see the measured dead ends in benchmarks/main.odin).
    @(private)
    rh_map32__hash :: #force_inline proc "contextless" (self: ^Rh_Map32, key: u32) -> int {
        when MAPS_TESTING {
            // For testing we need more predictable hash values
            return int(key) & self.mask
        } else {
            return cast(int)((u64(key) * 11400714819323198485) & u64(self.mask))
        }
    }

    // Insert; key must be < RH_MAP32_DELETED
    // #no_bounds_check: idx is always masked with capacity - 1, capacity == len(items)
    rh_map32__add :: proc(self: ^Rh_Map32, key: u32, value: u32) -> (err: oc.Error) #no_bounds_check {

        // if load factor >= 0.5
        if self.count >= self.half_capacity {
            return oc.Core_Error.Container_Is_Full
        }

        item := Rh_Map32_Item{ key = key, value = value }

        idx := rh_map32__hash(self, item.key)
        probe_distance := 0

        for {
            if self.items[idx].key == RH_MAP32_DELETED {
                self.items[idx] = item
                self.count += 1
                return nil
            }

            // Update existing key
            if self.items[idx].key == key {
                self.items[idx].value = item.value
                return nil
            }

            existing_key := self.items[idx].key
            existing_distance := (idx - rh_map32__hash(self, existing_key)) & self.mask

            if existing_distance < probe_distance {
                // Robin Hood swap
                temp_item := self.items[idx]

                self.items[idx] = item

                item = temp_item
                probe_distance = existing_distance
            }

            idx = (idx + 1) & self.mask
            probe_distance += 1

            // No mid-probe bail-out: count < half_capacity (checked on entry)
            // guarantees an empty slot exists, so the loop always terminates.
            // Returning here after a Robin Hood swap would drop the displaced
            // item and corrupt the map.
        }
    }

    // Single-probe get-or-insert: one Robin Hood walk that either finds an
    // existing key (found=true, map unmodified) or, when `can_insert` is true,
    // inserts `insert_value` at the walk's natural point (same placement as
    // rh_map32__add) and reports found=false. Saves the second full probe that
    // a separate get() then conditional add() pays on every miss — the walk to
    // the empty slot is identical in both, so add() was re-doing work get()
    // had already done. `can_insert` lets a caller gate insertion on its own
    // external capacity (e.g. Compact_Table's raw.len < cap) without a second
    // probe to re-check it; err is only ever Container_Is_Full, and only when
    // an insert was actually attempted (can_insert=true) but this map's own
    // load-factor limit blocked it — mirrors rh_map32__add's load check.
    rh_map32__get_or_insert :: #force_inline proc(self: ^Rh_Map32, key: u32, insert_value: u32, can_insert: bool) -> (value: u32, found: bool, err: oc.Error) #no_bounds_check {
        insertable := can_insert && self.count < self.half_capacity

        idx := rh_map32__hash(self, key)
        probe_distance := 0

        if !insertable {
            for probe_distance < self.half_capacity {
                if self.items[idx].key == RH_MAP32_DELETED {
                    if can_insert do err = oc.Core_Error.Container_Is_Full
                    return 0, false, err
                }
                if self.items[idx].key == key do return self.items[idx].value, true, nil
                idx = (idx + 1) & self.mask
                probe_distance += 1
            }
            if can_insert do err = oc.Core_Error.Container_Is_Full
            return 0, false, err
        }

        item := Rh_Map32_Item{ key = key, value = insert_value }

        for {
            if self.items[idx].key == RH_MAP32_DELETED {
                self.items[idx] = item
                self.count += 1
                return insert_value, false, nil
            }

            if self.items[idx].key == key {
                return self.items[idx].value, true, nil
            }

            existing_key := self.items[idx].key
            existing_distance := (idx - rh_map32__hash(self, existing_key)) & self.mask

            if existing_distance < probe_distance {
                temp_item := self.items[idx]
                self.items[idx] = item
                item = temp_item
                probe_distance = existing_distance
            }

            idx = (idx + 1) & self.mask
            probe_distance += 1
        }
    }

    @(private)
    // #no_bounds_check: idx is always masked with capacity - 1, capacity == len(items)
    rh_map32__get_from_hash :: #force_inline proc "contextless" (self: ^Rh_Map32, key: u32, ix: int) -> (u32, int) #no_bounds_check {
        probe_distance := 0
        idx := ix

        for probe_distance < self.half_capacity {
            if self.items[idx].key == RH_MAP32_DELETED {
                return RH_MAP32_DELETED, oc.DELETED_INDEX
            }

            if self.items[idx].key == key {
                return self.items[idx].value, idx
            }

            idx = (idx + 1) & self.mask
            probe_distance += 1
        }

        return RH_MAP32_DELETED, oc.DELETED_INDEX
    }

    // Lookup returning (value, slot index); slot index is oc.DELETED_INDEX when
    // the key is absent. The slot index feeds rh_map32__remove_at so callers
    // that already looked a key up don't pay a second hash + probe to remove it.
    rh_map32__get_with_index :: #force_inline proc "contextless" (self: ^Rh_Map32, key: u32) -> (u32, int) {
        ix := rh_map32__hash(self, key)

        return rh_map32__get_from_hash(self, key, ix)
    }

    // Lookup; returns RH_MAP32_DELETED when key is absent
    rh_map32__get :: #force_inline proc "contextless" (self: ^Rh_Map32, key: u32) -> u32 {
        idx := rh_map32__hash(self, key)

        val, _ := rh_map32__get_from_hash(self, key, idx)

        return val
    }

    rh_map32__update :: proc(self: ^Rh_Map32, key: u32, new_value: u32) -> (err: oc.Error) {
        _, ix := rh_map32__get_with_index(self, key)

        if ix == oc.DELETED_INDEX {
            return oc.Core_Error.Not_Found
        }

        self.items[ix].value = new_value

        return nil
    }

    // Remove the item at a slot index previously returned by
    // rh_map32__get_with_index for a present key — runs the backward shift
    // without re-hashing or re-probing. The index is only valid until the next
    // structural map change (add/remove); value-only updates don't move slots.
    // #no_bounds_check: indexes are always masked with capacity - 1, capacity == len(items)
    rh_map32__remove_at :: proc(self: ^Rh_Map32, #any_int idx: int) #no_bounds_check {
        idx := idx

        // Backward shift
        next_idx := (idx + 1) & self.mask
        for self.items[next_idx].key != RH_MAP32_DELETED {
            home := rh_map32__hash(self, self.items[next_idx].key)
            if ((next_idx - home) & self.mask) == 0 {
                break
            }
            self.items[idx] = self.items[next_idx]
            idx = next_idx
            next_idx = (next_idx + 1) & self.mask
        }

        self.items[idx].key = RH_MAP32_DELETED
        self.items[idx].value = RH_MAP32_DELETED
        self.count -= 1
    }

    // Delete
    rh_map32__remove :: proc(self: ^Rh_Map32, key: u32) -> oc.Error {
        _, idx := rh_map32__get_with_index(self, key)
        if idx == oc.DELETED_INDEX do return oc.Core_Error.Not_Found

        rh_map32__remove_at(self, idx)
        return nil
    }

    rh_map32__clear ::  #force_inline proc "contextless" (self: ^Rh_Map32) {
        for i:=0; i<self.capacity; i+=1 {
            self.items[i].key = RH_MAP32_DELETED
        }
        self.count = 0
    }

    rh_map32__len ::  #force_inline proc "contextless" (self: ^Rh_Map32) -> int {
        return self.count
    }

    rh_map32__memory_usage :: proc(self: ^Rh_Map32) -> int {
        return size_of(Rh_Map32) + size_of(Rh_Map32_Item) * self.capacity
    }

///////////////////////////////////////////////////////////////////////////////
// Tests
//

    @(test)
    rh_map32__test :: proc(t: ^testing.T) {
        // This test asserts exact slot placement, which needs the predictable
        // identity hash. Skip (don't fail) in production-hash mode; behavioral
        // coverage for that mode lives in rh_map32__behavior__test.
        when !MAPS_TESTING {
            log.warn("rh_map32__test skipped: slot-placement test needs -define:maps_testing=true")
            return
        }

        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        //
        // Make sure we are using the simplified hash function for testing
        //

        testing.expect(t, rh_map32__hash(&Rh_Map32{ capacity = 16, mask = 15 }, 0) == 0)
        testing.expect(t, rh_map32__hash(&Rh_Map32{ capacity = 16, mask = 15 }, 17) == 1)

        //
        // basic add/get/update/remove
        //

        map1: Rh_Map32

        testing.expect(t, rh_map32__init(&map1, 3, allocator) == oc.Core_Error.Capacity_Is_Not_Power_Of_2)
        testing.expect(t, rh_map32__init(&map1, 8, allocator) == nil)

        testing.expect(t, map1.count == 0)
        testing.expect(t, map1.capacity == 8)
        testing.expect(t, map1.half_capacity == 8)
        testing.expect(t, map1.mask == 0b111)

        // collision cluster: 16, 32, 64 all hash to 0 (identity mod 8); 1, 17 to 1; 2 to 2
        testing.expect(t, rh_map32__add(&map1, 16, 100) == nil)
        testing.expect(t, rh_map32__add(&map1, 1, 101) == nil)
        testing.expect(t, rh_map32__add(&map1, 17, 102) == nil)
        testing.expect(t, rh_map32__add(&map1, 2, 103) == nil)
        testing.expect(t, rh_map32__add(&map1, 32, 104) == nil)
        testing.expect(t, rh_map32__add(&map1, 64, 105) == nil)

        // Robin Hood layout, mirrors rh_map__test's classic example
        testing.expect(t, map1.items[0].value == 100)
        testing.expect(t, map1.items[1].value == 104)
        testing.expect(t, map1.items[2].value == 105)
        testing.expect(t, map1.items[3].value == 101)
        testing.expect(t, map1.items[4].value == 102)
        testing.expect(t, map1.items[5].value == 103)

        testing.expect(t, rh_map32__get(&map1, 16) == 100)
        testing.expect(t, rh_map32__get(&map1, 1) == 101)
        testing.expect(t, rh_map32__get(&map1, 17) == 102)
        testing.expect(t, rh_map32__get(&map1, 2) == 103)
        testing.expect(t, rh_map32__get(&map1, 32) == 104)
        testing.expect(t, rh_map32__get(&map1, 64) == 105)

        // misses inside the cluster and on empty slots
        testing.expect(t, rh_map32__get(&map1, 8) == RH_MAP32_DELETED)
        testing.expect(t, rh_map32__get(&map1, 24) == RH_MAP32_DELETED)
        testing.expect(t, rh_map32__get(&map1, 7) == RH_MAP32_DELETED)
        testing.expect(t, rh_map32__remove(&map1, 8) == oc.Core_Error.Not_Found)

        // update existing keys (both via add and via update)
        testing.expect(t, rh_map32__add(&map1, 16, 200) == nil)
        testing.expect(t, rh_map32__get(&map1, 16) == 200)
        testing.expect(t, map1.count == 6)
        testing.expect(t, rh_map32__update(&map1, 2, 203) == nil)
        testing.expect(t, rh_map32__get(&map1, 2) == 203)
        testing.expect(t, rh_map32__update(&map1, 9, 1) == oc.Core_Error.Not_Found)

        // fill to capacity, then overflow
        testing.expect(t, rh_map32__add(&map1, 7, 106) == nil)
        testing.expect(t, rh_map32__add(&map1, 15, 107) == nil)
        testing.expect(t, rh_map32__add(&map1, 18, 108) == oc.Core_Error.Container_Is_Full)

        // remove with backward shift keeps the rest findable
        testing.expect(t, rh_map32__remove(&map1, 1) == nil)
        testing.expect(t, rh_map32__get(&map1, 1) == RH_MAP32_DELETED)
        testing.expect(t, rh_map32__get(&map1, 17) == 102)
        testing.expect(t, rh_map32__get(&map1, 2) == 203)
        testing.expect(t, rh_map32__get(&map1, 32) == 104)
        testing.expect(t, rh_map32__get(&map1, 64) == 105)
        testing.expect(t, rh_map32__get(&map1, 15) == 107)
        testing.expect(t, map1.count == 7)

        // reuse the freed slot
        testing.expect(t, rh_map32__add(&map1, 40, 109) == nil)
        testing.expect(t, rh_map32__get(&map1, 40) == 109)

        rh_map32__clear(&map1)
        testing.expect(t, map1.count == 0)
        testing.expect(t, rh_map32__get(&map1, 16) == RH_MAP32_DELETED)
        testing.expect(t, rh_map32__get(&map1, 40) == RH_MAP32_DELETED)

        //
        // get_or_insert
        //

        // miss + can_insert=true -> inserts and reports found=false
        v, found, gerr := rh_map32__get_or_insert(&map1, 16, 999, true)
        testing.expect(t, v == 999 && found == false && gerr == nil)
        testing.expect(t, map1.count == 1)
        testing.expect(t, rh_map32__get(&map1, 16) == 999)

        // hit -> returns the existing value untouched, regardless of insert_value
        v, found, gerr = rh_map32__get_or_insert(&map1, 16, 111, true)
        testing.expect(t, v == 999 && found == true && gerr == nil)
        testing.expect(t, map1.count == 1)
        testing.expect(t, rh_map32__get(&map1, 16) == 999) // unmodified

        // miss + can_insert=false -> no mutation, no error (external cap gate, not a map failure)
        v, found, gerr = rh_map32__get_or_insert(&map1, 1, 222, false)
        testing.expect(t, v == 0 && found == false && gerr == nil)
        testing.expect(t, map1.count == 1)
        testing.expect(t, rh_map32__get(&map1, 1) == RH_MAP32_DELETED)

        // miss + can_insert=true now succeeds for the same key
        v, found, gerr = rh_map32__get_or_insert(&map1, 1, 222, true)
        testing.expect(t, v == 222 && found == false && gerr == nil)
        testing.expect(t, map1.count == 2)

        // fill to the load-factor limit (half_capacity == capacity == 8 in test mode)
        for i := 2; i <= 7; i += 1 {
            v, found, gerr = rh_map32__get_or_insert(&map1, u32(i + 100), u32(i), true)
            testing.expect(t, found == false && gerr == nil)
        }
        testing.expect(t, map1.count == 8)

        // full map: a hit still succeeds (found=true), no Container_Is_Full
        v, found, gerr = rh_map32__get_or_insert(&map1, 16, 0, true)
        testing.expect(t, v == 999 && found == true && gerr == nil)

        // full map: a genuine miss is rejected without corrupting state
        v, found, gerr = rh_map32__get_or_insert(&map1, 999, 1, true)
        testing.expect(t, v == 0 && found == false && gerr == oc.Core_Error.Container_Is_Full)
        testing.expect(t, map1.count == 8)

        testing.expect(t, rh_map32__terminate(&map1, allocator) == nil)
    }

    // Behavioral test: asserts observable behavior only (never slot placement),
    // so it runs in BOTH modes. Without -define:maps_testing=true this is what
    // exercises the production Fibonacci hash, the 0.5 load factor and the
    // min-capacity-8 bump.
    @(test)
    rh_map32__behavior__test :: proc(t: ^testing.T) {
        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        // non-power-of-2 capacity is rejected
        bad: Rh_Map32
        testing.expect(t, rh_map32__init(&bad, 6, allocator) == oc.Core_Error.Capacity_Is_Not_Power_Of_2)

        // tiny capacity: production mode bumps to the 8 minimum with half_capacity 4
        tiny: Rh_Map32
        testing.expect(t, rh_map32__init(&tiny, 2, allocator) == nil)
        when MAPS_TESTING {
            testing.expect(t, tiny.capacity == 2 && tiny.half_capacity == 2)
        } else {
            testing.expect(t, tiny.capacity == 8 && tiny.half_capacity == 4)
        }
        testing.expect(t, tiny.mask == tiny.capacity - 1)
        testing.expect(t, rh_map32__terminate(&tiny, allocator) == nil)

        m: Rh_Map32
        testing.expect(t, rh_map32__init(&m, 64, allocator) == nil)
        defer rh_map32__terminate(&m, allocator)
        testing.expect(t, m.count == 0)
        testing.expect(t, rh_map32__memory_usage(&m) > 0)

        // fill to the load-factor limit with scattered keys (forces collisions
        // and wrap-around under any hash)
        limit := m.half_capacity

        key_of :: proc(i: int) -> u32 { return u32(i * 97 + 13) }

        for i in 0..<limit-1 {
            testing.expect(t, rh_map32__add(&m, key_of(i), u32(i * 1000)) == nil)
        }
        testing.expect(t, m.count == limit - 1)

        // add on an existing key updates the value in place (count unchanged)
        testing.expect(t, rh_map32__add(&m, key_of(0), 42) == nil)
        testing.expect(t, rh_map32__get(&m, key_of(0)) == 42)
        testing.expect(t, m.count == limit - 1)

        // update; update of a missing key fails
        testing.expect(t, rh_map32__update(&m, key_of(0), 0) == nil)
        testing.expect(t, rh_map32__get(&m, key_of(0)) == 0)
        testing.expect(t, rh_map32__update(&m, key_of(limit), 0) == oc.Core_Error.Not_Found)

        // full at the load-factor limit (the load check runs before the update-in-place scan)
        testing.expect(t, rh_map32__add(&m, key_of(limit-1), u32((limit - 1) * 1000)) == nil)
        testing.expect(t, m.count == limit)
        testing.expect(t, rh_map32__add(&m, key_of(limit), 0) == oc.Core_Error.Container_Is_Full)
        testing.expect(t, rh_map32__add(&m, key_of(0), 42) == oc.Core_Error.Container_Is_Full)

        // every inserted key is retrievable; absent keys return the sentinel
        for i in 0..<limit do testing.expect(t, rh_map32__get(&m, key_of(i)) == u32(i * 1000))
        testing.expect(t, rh_map32__get(&m, key_of(limit)) == RH_MAP32_DELETED)

        // remove every third key; backward shift must keep all survivors reachable
        removed_count := 0
        for i := 0; i < limit; i += 3 {
            testing.expect(t, rh_map32__remove(&m, key_of(i)) == nil)
            removed_count += 1
        }
        testing.expect(t, m.count == limit - removed_count)
        for i in 0..<limit {
            if i % 3 == 0 {
                testing.expect(t, rh_map32__get(&m, key_of(i)) == RH_MAP32_DELETED)
            } else {
                testing.expect(t, rh_map32__get(&m, key_of(i)) == u32(i * 1000))
            }
        }

        // removing an absent key fails; re-inserting removed keys works
        testing.expect(t, rh_map32__remove(&m, key_of(0)) == oc.Core_Error.Not_Found)
        for i := 0; i < limit; i += 3 {
            testing.expect(t, rh_map32__add(&m, key_of(i), u32(i * 1000)) == nil)
        }
        testing.expect(t, m.count == limit)
        for i in 0..<limit do testing.expect(t, rh_map32__get(&m, key_of(i)) == u32(i * 1000))

        // clear resets and the map stays usable
        rh_map32__clear(&m)
        testing.expect(t, m.count == 0)
        testing.expect(t, rh_map32__get(&m, key_of(1)) == RH_MAP32_DELETED)
        testing.expect(t, rh_map32__add(&m, key_of(1), 7) == nil)
        testing.expect(t, rh_map32__get(&m, key_of(1)) == 7)
    }

    @(test)
    rh_map32__is_valid__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        zero_value: Rh_Map32
        testing.expect(t, rh_map32__is_valid(&zero_value) == false)
        testing.expect(t, rh_map32__is_valid(nil) == false)

        m: Rh_Map32
        testing.expect(t, rh_map32__init(&m, 8, allocator) == nil)
        testing.expect(t, rh_map32__is_valid(&m))

        testing.expect(t, rh_map32__terminate(&m, allocator) == nil)
        testing.expect(t, rh_map32__is_valid(&m) == false)
    }

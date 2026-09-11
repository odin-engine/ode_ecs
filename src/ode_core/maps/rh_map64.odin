/*
    2026 (c) Oleh, https://github.com/zm69
*/
package maps

// Core
    import "core:log"
    import "core:mem"
    import "core:math"
    import "core:math/rand"
    import "core:testing"

// ODE_CORE
    import oc ".."

///////////////////////////////////////////////////////////////////////////////
// Rh_Map64 - Robin Hood map with 16-byte items (u64 key -> u32 value).
//
// Made for 64-bit name hashes -> entity index; RH_MAP64_DELETED (max(u64)) marks empty slots.

    RH_MAP64_DELETED :: max(u64)
    RH_MAP64_NOT_FOUND :: max(u32)

    Rh_Map64_Item :: struct {
        key: u64,
        value: u32,
    }

    Rh_Map64 :: struct {
        items: []Rh_Map64_Item,
        capacity: int,
        count: int,

        max_count: int,
        mask: int,
    }

    rh_map64__is_valid :: #force_inline proc "contextless" (self: ^Rh_Map64) -> bool {
        if self == nil do return false
        if self.items == nil do return false
        if self.capacity <= 0 do return false
        if self.max_count <= 0 do return false
        if self.mask == 0 do return false

        return true
    }

    // Smallest power-of-2 capacity holding count items under RH_MAP32_LOAD_PCT.
    rh_map64__capacity_for :: proc(#any_int count: int) -> int {
        return math.next_power_of_two((count * 100 + RH_MAP32_LOAD_PCT - 1) / RH_MAP32_LOAD_PCT)
    }

    rh_map64__init :: proc(self: ^Rh_Map64, #any_int capacity: int, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)
        assert(capacity > 1, loc = loc)

        if !math.is_power_of_two(capacity) do return oc.Core_Error.Capacity_Is_Not_Power_Of_2
        self.capacity = capacity

        when !MAPS_TESTING {
            if self.capacity < 8 do self.capacity = 8
        }

        self.items = make([]Rh_Map64_Item, self.capacity, allocator) or_return

        rh_map64__clear(self)

        when MAPS_TESTING {
            self.max_count = self.capacity
        } else {
            self.max_count = self.capacity * RH_MAP32_LOAD_PCT / 100
        }

        self.mask = self.capacity - 1

        return nil
    }

    rh_map64__terminate :: proc(self: ^Rh_Map64, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)

        delete(self.items, allocator) or_return
        self^ = {}

        return nil
    }

    @(private)
    rh_map64__hash :: #force_inline proc "contextless" (self: ^Rh_Map64, key: u64) -> int {
        when MAPS_TESTING {
            return int(key & u64(self.mask)) // predictable hash for tests
        } else {
            return int(((key * 11400714819323198485) >> 32) & u64(self.mask))
        }
    }

    // Insert or update; key must be < RH_MAP64_DELETED.
    rh_map64__add :: proc(self: ^Rh_Map64, key: u64, value: u32) -> (err: oc.Core_Error) #no_bounds_check {
        if self.count >= self.max_count do return oc.Core_Error.Container_Is_Full

        item := Rh_Map64_Item{ key = key, value = value }

        idx := rh_map64__hash(self, item.key)
        probe_distance := 0

        for {
            if self.items[idx].key == RH_MAP64_DELETED {
                self.items[idx] = item
                self.count += 1
                return oc.Core_Error.None
            }

            if self.items[idx].key == key {
                self.items[idx].value = item.value
                return oc.Core_Error.None
            }

            existing_distance := (idx - rh_map64__hash(self, self.items[idx].key)) & self.mask

            if existing_distance < probe_distance { // Robin Hood swap
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
    rh_map64__find :: #force_inline proc "contextless" (self: ^Rh_Map64, key: u64) -> int #no_bounds_check {
        idx := rh_map64__hash(self, key)
        probe_distance := 0

        for probe_distance < self.max_count {
            k := self.items[idx].key
            if k == key do return idx
            if k == RH_MAP64_DELETED do break
            if ((idx - rh_map64__hash(self, k)) & self.mask) < probe_distance do break

            idx = (idx + 1) & self.mask
            probe_distance += 1
        }

        return oc.DELETED_INDEX
    }

    // Lookup; returns RH_MAP64_NOT_FOUND when key is absent.
    rh_map64__get :: #force_inline proc "contextless" (self: ^Rh_Map64, key: u64) -> u32 #no_bounds_check {
        idx := rh_map64__find(self, key)
        if idx == oc.DELETED_INDEX do return RH_MAP64_NOT_FOUND
        return self.items[idx].value
    }

    rh_map64__remove :: proc(self: ^Rh_Map64, key: u64) -> oc.Core_Error #no_bounds_check {
        idx := rh_map64__find(self, key)
        if idx == oc.DELETED_INDEX do return oc.Core_Error.Not_Found

        next_idx := (idx + 1) & self.mask // backward shift
        for self.items[next_idx].key != RH_MAP64_DELETED {
            home := rh_map64__hash(self, self.items[next_idx].key)
            if ((next_idx - home) & self.mask) == 0 do break
            self.items[idx] = self.items[next_idx]
            idx = next_idx
            next_idx = (next_idx + 1) & self.mask
        }

        self.items[idx].key = RH_MAP64_DELETED
        self.count -= 1
        return oc.Core_Error.None
    }

    rh_map64__clear :: #force_inline proc "contextless" (self: ^Rh_Map64) {
        for i in 0..<self.capacity do self.items[i].key = RH_MAP64_DELETED
        self.count = 0
    }

    rh_map64__len :: #force_inline proc "contextless" (self: ^Rh_Map64) -> int {
        return self.count
    }

    rh_map64__memory_usage :: proc(self: ^Rh_Map64) -> int {
        return size_of(Rh_Map64) + size_of(Rh_Map64_Item) * self.capacity
    }

///////////////////////////////////////////////////////////////////////////////
// Tests
//

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

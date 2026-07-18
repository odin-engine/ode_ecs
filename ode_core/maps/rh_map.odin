/*
    2025 (c) Oleh, https://github.com/zm69
*/
package maps

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:slice"
    import "core:mem"
    import "core:math"
    import "core:testing"
    import "core:fmt"

// ODE_CORE
    import oc ".."

///////////////////////////////////////////////////////////////////////////////
// Rh_Map - Robin Hood Map
// key expected to be non-negative int
// $V expected to be a pointer type 

    Rh_Map_Item :: struct($V: typeid) {
        key: int,
        value: V,
        //dist: int, // can try this later to speed up
    }

    Rh_Map :: struct($V: typeid) {
        items: []Rh_Map_Item(V),
        capacity: int,
        count: int,

        half_capacity: int,
        mask: int,
    }

    rh_map__is_valid ::  #force_inline proc "contextless"(self: ^Rh_Map($V)) -> bool {
        if self == nil do return false
        if self.items == nil do return false 
        if self.capacity <= 0 do return false 
        if self.half_capacity <= 0 do return false 
        if self.mask == 0 do return false

        return true
    }

    rh_map__init :: proc(self: ^Rh_Map($V),  #any_int capacity: int, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)
        assert(capacity > 1, loc = loc)

        if !math.is_power_of_two(capacity) do return oc.Core_Error.Capacity_Is_Not_Power_Of_2
        self.capacity = capacity

        when !MAPS_TESTING {
            if self.capacity < 8 do self.capacity = 8 
        }
        
        self.items = make([]Rh_Map_Item(V), self.capacity, allocator) or_return

        rh_map__clear(self)  // requires self.capacity to be set

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

    rh_map__terminate :: proc(self: ^Rh_Map($V), allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)

        delete(self.items, allocator) or_return

        self.capacity = 0
        self.count = 0

        self.half_capacity = 0
        self.mask = 0

        return nil
    }

    // Fibonacci rh_map__hash for power-of-2 capacity
    @(private)
    rh_map__hash :: #force_inline proc "contextless" (self: ^Rh_Map($T), key: int) -> int {
        when MAPS_TESTING {
            // For testing we need more predictable hash values
            return key & self.mask
        } else {
            return cast(int)((u64(key) * 11400714819323198485) & u64(self.mask))
        }
    }

    // Insert, key is expected to be non-negative
    // #no_bounds_check: idx is always masked with capacity - 1, capacity == len(items)
    rh_map__add :: proc(self: ^Rh_Map($T), key: int, value: T) -> (err: oc.Error) #no_bounds_check {

        // if load factor >= 0.5 
        if self.count >= self.half_capacity {
            return oc.Core_Error.Container_Is_Full
        }

        item := Rh_Map_Item(T){ key = key, value = value }

        idx := rh_map__hash(self, item.key)
        probe_distance := 0

        for {

            // fmt.println("Inserting key:", item.key, "at idx:", idx, "probe_distance:", probe_distance, "self.items[idx].key:", self.items[idx].key, "self.items", self.items) 

            if self.items[idx].key == oc.DELETED_INDEX {
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
            existing_distance := (idx - rh_map__hash(self, existing_key)) & self.mask

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


    @(private)
    // #no_bounds_check: idx is always masked with capacity - 1, capacity == len(items)
    rh_map__get_from_hash :: proc(self: ^Rh_Map($V), key: int, ix: int) -> (V, int) #no_bounds_check {
        probe_distance := 0
        idx := ix

        for probe_distance < self.half_capacity {
            if self.items[idx].key == oc.DELETED_INDEX {
                return nil, oc.DELETED_INDEX
            }

            if self.items[idx].key == key {
                return self.items[idx].value, idx
            }

            idx = (idx + 1) & self.mask
            probe_distance += 1
        }

        return nil, oc.DELETED_INDEX // $V is expected to be a pointer type
    }

    @(private)
    rh_map__get_with_index :: proc(self: ^Rh_Map($V), key: int) -> (V, int) {
        ix := rh_map__hash(self, key)

        return rh_map__get_from_hash(self, key, ix)
    }

    // Lookup, $V is expected to be a pointer type
    rh_map__get :: proc(self: ^Rh_Map($V), key: int) -> V {
        idx := rh_map__hash(self, key)

        val, _ := rh_map__get_from_hash(self, key, idx)

        return val
    }

    rh_map__update :: proc(self: ^Rh_Map($T), key: int, new_value: T) -> (err: oc.Error) {
        _, ix := rh_map__get_with_index(self, key)

        if ix == oc.DELETED_INDEX {
            return oc.Core_Error.Not_Found
        }

        self.items[ix].value = new_value

        return nil
    }

    // Delete
    // #no_bounds_check: indexes are always masked with capacity - 1, capacity == len(items)
    rh_map__remove :: proc(self: ^Rh_Map($T), key: int) -> oc.Error #no_bounds_check {
        idx := rh_map__hash(self, key)
        probe_distance := 0

        for probe_distance < self.half_capacity {
            if self.items[idx].key == oc.DELETED_INDEX {
                return oc.Core_Error.Not_Found
            }

            if self.items[idx].key == key {
                // Remove and backward shift
                next_idx := (idx + 1) & self.mask
                for self.items[next_idx].key != oc.DELETED_INDEX {
                    home := rh_map__hash(self, self.items[next_idx].key)
                    if ((next_idx - home) & self.mask) == 0 {
                        break
                    }
                    self.items[idx] = self.items[next_idx]
                    idx = next_idx
                    next_idx = (next_idx + 1) & self.mask
                }

                self.items[idx].key = oc.DELETED_INDEX
                self.items[idx].value = nil
                self.count -= 1
                return nil
            }

            idx = (idx + 1) & self.mask
            probe_distance += 1
        }

        return oc.Core_Error.Not_Found
    }

    rh_map__clear ::  #force_inline proc "contextless" (self: ^Rh_Map($V)) {
        for i:=0; i<self.capacity; i+=1 {
            self.items[i].key = oc.DELETED_INDEX
        }
        self.count = 0
    }

    rh_map__len ::  #force_inline proc "contextless" (self: ^Rh_Map($V)) -> int {
        return self.count
    }

    rh_map__memory_usage :: proc(self: ^Rh_Map($V)) -> int {
        return size_of(Rh_Map(V)) + size_of(Rh_Map_Item(V)) * self.capacity
    }

    rh_map__debug_print :: proc(self: ^Rh_Map($V)) {
        fmt.println("\nRh_Map debug print (key, hash, value):")

        for i:=0; i<self.capacity; i+=1 {
            item := self.items[i]

            fmt.printf("% 4d, ", item.key)
        }

        fmt.println()

        for i:=0; i<self.capacity; i+=1 {
            item := self.items[i]

            if (item.key == oc.DELETED_INDEX) {
                fmt.printf("%4s, ", " ")
            } else {
                s := fmt.tprintf("%v", rh_map__hash(self, item.key))
                fmt.printf("%4s, ", s)
            }
        }

        fmt.println()

        for i:=0; i<self.capacity; i+=1 {
            item := self.items[i]

            if item.value == nil {
                fmt.printf("%4s, ", " ")
            } else {
                s := fmt.tprintf("%v", item.value^)
                fmt.printf("%4s, ", s)
            }
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Tests
// 
    
    @(test)
    rh_map__test :: proc(t: ^testing.T) {
        // This test asserts exact slot placement, which needs the predictable
        // identity hash. Skip (don't fail) in production-hash mode; behavioral
        // coverage for that mode lives in rh_map__behavior__test.
        when !MAPS_TESTING {
            log.warn("rh_map__test skipped: slot-placement test needs -define:maps_testing=true")
            return
        }

        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        v1: int = 33
        v2: int = 55
        v3: int = 66
        v4: int = 77

        //
        // Make sure we using simplified hash function for testing
        //

        testing.expect(t, rh_map__hash(&Rh_Map(^int){ capacity = 16, mask = 15 }, 0) == 0)
        testing.expect(t, rh_map__hash(&Rh_Map(^int){ capacity = 16, mask = 15 }, 1) == 1)
        testing.expect(t, rh_map__hash(&Rh_Map(^int){ capacity = 16, mask = 15 }, 2) == 2)

        //
        // map1
        //

        map1: Rh_Map(^int) 

        testing.expect(t, rh_map__init(&map1, 3, allocator) == oc.Core_Error.Capacity_Is_Not_Power_Of_2)

        testing.expect(t, rh_map__init(&map1, 2, allocator) == nil)
         
        testing.expect(t, map1.count == 0)
        testing.expect(t, map1.capacity == 2)
        testing.expect(t, map1.half_capacity == 2)
        testing.expect(t, map1.mask == 1)

        testing.expect(t, rh_map__add(&map1, 33, &v1) == nil)
        testing.expect(t, rh_map__get(&map1, 33) == &v1)
        testing.expect(t, map1.count == 1)

        testing.expect(t, rh_map__add(&map1, 66, &v3) == nil)
        testing.expect(t, rh_map__get(&map1, 66) == &v3)
        testing.expect(t, map1.count == 2)

        testing.expect(t, rh_map__add(&map1, 55, &v2) == oc.Core_Error.Container_Is_Full)
        testing.expect(t, rh_map__get(&map1, 55) == nil)
        testing.expect(t, map1.count == 2)

        testing.expect(t, rh_map__get(&map1, 33) == &v1)
        testing.expect(t, map1.count == 2)
        testing.expect(t, rh_map__remove(&map1, 55) == oc.Core_Error.Not_Found) 
        testing.expect(t, rh_map__remove(&map1, 33) == nil) 
        testing.expect(t, rh_map__get(&map1, 33) == nil)
        testing.expect(t, map1.count == 1)

        testing.expect(t, rh_map__terminate(&map1, allocator) == nil)

        //
        // map2, classic robin hood example
        // a, e, f hash to 0; b, c to 1; d to 2. inserting values in alphabetical order
        //

        a := 'a'
        b := 'b'
        c := 'c'
        d := 'd'
        e := 'e'
        f := 'f'
        g := 'g'
        h := 'h'
        ii := 'i'

        map2: Rh_Map(^rune) 
        testing.expect(t, rh_map__init(&map2, 8, allocator) == nil)
        testing.expect(t, map2.count == 0)
        testing.expect(t, map2.capacity == 8)
        testing.expect(t, map2.half_capacity == 8)
        testing.expect(t, map2.mask == 0b111)

        // adding 

        testing.expect(t, rh_map__hash(&map2, 0) == 0)

        // insert in an alphabetical order to create collisions
        testing.expect(t, rh_map__add(&map2, 16, &a) == nil)
        testing.expect(t, rh_map__add(&map2, 1, &b) == nil)
        testing.expect(t, rh_map__add(&map2, 17, &c) == nil)
        testing.expect(t, rh_map__add(&map2, 2, &d) == nil)
        testing.expect(t, rh_map__add(&map2, 32, &e) == nil)
        testing.expect(t, rh_map__add(&map2, 64, &f) == nil)

        // testing locations

        testing.expect(t, map2.items[0].value == &a) 
        testing.expect(t, map2.items[1].value == &e) 
        testing.expect(t, map2.items[2].value == &f) 
        testing.expect(t, map2.items[3].value == &b) 
        testing.expect(t, map2.items[4].value == &c) 
        testing.expect(t, map2.items[5].value == &d)  

        //testing.expect(t, rh_map__remove(&map2, 1) == nil) // remove b

        testing.expect(t, rh_map__add(&map2, 7, &g) == nil)
        testing.expect(t, rh_map__add(&map2, 15, &h) == nil)
        testing.expect(t, rh_map__add(&map2, 18, &ii) == oc.Core_Error.Container_Is_Full) // should fail, map full

        // misses inside a dense collision cluster (and on a full map) must
        // still terminate and report absence
        testing.expect(t, rh_map__get(&map2, 8) == nil)
        testing.expect(t, rh_map__get(&map2, 24) == nil)
        testing.expect(t, rh_map__get(&map2, 33) == nil)
        testing.expect(t, rh_map__get(&map2, 65) == nil)
        testing.expect(t, rh_map__remove(&map2, 8) == oc.Core_Error.Not_Found)
        testing.expect(t, rh_map__remove(&map2, 33) == oc.Core_Error.Not_Found)

        //rh_map__debug_print(&map2)

        rh_map__clear(&map2)

        testing.expect(t, rh_map__get(&map2, 16) == nil)
        testing.expect(t, rh_map__get(&map2, 1) == nil)
        testing.expect(t, rh_map__get(&map2, 17) == nil)
        testing.expect(t, rh_map__get(&map2, 15) == nil)

        testing.expect(t, rh_map__terminate(&map2, allocator) == nil)

        //
        // map3
        // 

        map3: Rh_Map(^int) 
        testing.expect(t, rh_map__init(&map3, 4, allocator) == nil)

        testing.expect(t, rh_map__add(&map3, 4, &v1) == nil)
        testing.expect(t, rh_map__add(&map3, 8, &v2) == nil)
        testing.expect(t, rh_map__add(&map3, 12, &v3) == nil)
        testing.expect(t, rh_map__add(&map3, 2, &v4) == nil)

        //rh_map__debug_print(&map3)

        v,i := rh_map__get_with_index(&map3, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 2)

        testing.expect(t, rh_map__get(&map3, 8) == &v2)
        testing.expect(t, rh_map__get(&map3, 4) == &v1)
         
        v,i = rh_map__get_with_index(&map3, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 3)

        testing.expect(t, rh_map__remove(&map3, 8) == nil) // remove
        testing.expect(t, rh_map__get(&map3, 8) == nil)

        v,i = rh_map__get_with_index(&map3, 4)
        testing.expect(t, v == &v1)

        v,i = rh_map__get_with_index(&map3, 12)
        testing.expect(t, v == &v3)

        v,i = rh_map__get_with_index(&map3, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 2)

        testing.expect(t, rh_map__remove(&map3, 4) == nil) // remove
        testing.expect(t, rh_map__get(&map3, 4) == nil)

        v,i = rh_map__get_with_index(&map3, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 0)

        //rh_map__debug_print(&map3)

        testing.expect(t, map3.items[1].key == oc.DELETED_INDEX)
        testing.expect(t, map3.items[1].value == nil)

        v,i = rh_map__get_with_index(&map3, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 2)

        testing.expect(t, map3.items[3].key == oc.DELETED_INDEX)
        testing.expect(t, map3.items[3].value == nil)

        testing.expect(t, rh_map__add(&map3, 8, &v2) == nil)
        testing.expect(t, rh_map__add(&map3, 4, &v1) == nil)

        //rh_map__debug_print(&map3)

        v,i = rh_map__get_with_index(&map3, 4)
        testing.expect(t, v == &v1)
        testing.expect(t, i < 3 )

        testing.expect(t, rh_map__remove(&map3, 8) == nil) // remove
        testing.expect(t, rh_map__remove(&map3, 12) == nil) // remove

        //rh_map__debug_print(&map3)

        v,i = rh_map__get_with_index(&map3, 4)
        testing.expect(t, v == &v1)

        testing.expect(t, rh_map__add(&map3, 8, &v2) == nil)
        testing.expect(t, rh_map__add(&map3, 12, &v3) == nil)

        v,i = rh_map__get_with_index(&map3, 8)
        testing.expect(t, v == &v2)
        testing.expect(t, i < 3)

        v,i = rh_map__get_with_index(&map3, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i < 3)

        testing.expect(t, rh_map__remove(&map3, 8) == nil) // remove
        
        testing.expect(t, map3.items[3].key == oc.DELETED_INDEX)
        testing.expect(t, map3.items[3].value == nil)

        testing.expect(t, rh_map__add(&map3, 8, &v2) == nil)
        testing.expect(t, rh_map__add(&map3, 3, &v2) == oc.Core_Error.Container_Is_Full)
        testing.expect(t, rh_map__remove(&map3, 4) == nil) // remove

        testing.expect(t, rh_map__add(&map3, 3, &v2) == nil)
        testing.expect(t, rh_map__remove(&map3, 12) == nil) // remove
        testing.expect(t, rh_map__add(&map3, 7, &v3) == nil)
          
        v,i = rh_map__get_with_index(&map3, 7)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 0)

        v,i = rh_map__get_with_index(&map3, 8)
        testing.expect(t, v == &v2)
        testing.expect(t, i == 1)

        testing.expect(t, rh_map__remove(&map3, 3) == nil) // remove

        // before update
        v,i = rh_map__get_with_index(&map3, 7)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 3)

        rh_map__update(&map3, 7, &v4)

        // after update
        v,i = rh_map__get_with_index(&map3, 7)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 3)

        testing.expect(t, rh_map__add(&map3, 7, &v2) == nil)

        v,i = rh_map__get_with_index(&map3, 7)
        testing.expect(t, v == &v2)
        testing.expect(t, i == 3)

        //rh_map__debug_print(&map3)

        testing.expect(t, rh_map__add(&map3, 4, &v1) == nil)
        testing.expect(t, rh_map__update(&map3, 4, &v4) == nil)

        v,i = rh_map__get_with_index(&map3, 4)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 1) 

        //rh_map__debug_print(&map3)

        testing.expect(t, rh_map__add(&map3, 4, &v1) == oc.Core_Error.Container_Is_Full)

        testing.expect(t, rh_map__remove(&map3, 7) == nil) // remove

        testing.expect(t, rh_map__add(&map3, 4, &v1) == nil)

        v,i = rh_map__get_with_index(&map3, 4)
        testing.expect(t, v == &v1)
        testing.expect(t, i == 1) 

        //rh_map__debug_print(&map3)

        testing.expect(t, rh_map__terminate(&map3, allocator) == nil)
    }

    // Behavioral test: asserts observable behavior only (never slot placement),
    // so it runs in BOTH modes. Without -define:maps_testing=true this is what
    // exercises the production Fibonacci hash, the 0.5 load factor and the
    // min-capacity-8 bump.
    @(test)
    rh_map__behavior__test :: proc(t: ^testing.T) {
        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        // non-power-of-2 capacity is rejected
        bad: Rh_Map(^int)
        testing.expect(t, rh_map__init(&bad, 6, allocator) == oc.Core_Error.Capacity_Is_Not_Power_Of_2)

        // tiny capacity: production mode bumps to the 8 minimum with half_capacity 4
        tiny: Rh_Map(^int)
        testing.expect(t, rh_map__init(&tiny, 2, allocator) == nil)
        when MAPS_TESTING {
            testing.expect(t, tiny.capacity == 2 && tiny.half_capacity == 2)
        } else {
            testing.expect(t, tiny.capacity == 8 && tiny.half_capacity == 4)
        }
        testing.expect(t, tiny.mask == tiny.capacity - 1)
        testing.expect(t, rh_map__terminate(&tiny, allocator) == nil)

        m: Rh_Map(^int)
        testing.expect(t, rh_map__init(&m, 64, allocator) == nil)
        defer rh_map__terminate(&m, allocator)
        testing.expect(t, rh_map__len(&m) == 0)
        testing.expect(t, rh_map__memory_usage(&m) > 0)

        // fill to the load-factor limit with scattered keys (forces collisions
        // and wrap-around under any hash)
        limit := m.half_capacity
        values := make([]int, limit + 1, allocator)
        defer delete(values, allocator)

        key_of :: proc(i: int) -> int { return i * 97 + 13 }

        for i in 0..<limit-1 {
            values[i] = i * 1000
            testing.expect(t, rh_map__add(&m, key_of(i), &values[i]) == nil)
        }
        testing.expect(t, rh_map__len(&m) == limit - 1)

        // add on an existing key updates the value in place (len unchanged)
        testing.expect(t, rh_map__add(&m, key_of(0), &values[1]) == nil)
        testing.expect(t, rh_map__get(&m, key_of(0)) == &values[1])
        testing.expect(t, rh_map__len(&m) == limit - 1)

        // update; update of a missing key fails
        testing.expect(t, rh_map__update(&m, key_of(0), &values[0]) == nil)
        testing.expect(t, rh_map__get(&m, key_of(0)) == &values[0])
        testing.expect(t, rh_map__update(&m, key_of(limit), &values[0]) == oc.Core_Error.Not_Found)

        // full at the load-factor limit (the load check runs before the update-in-place scan)
        values[limit-1] = (limit - 1) * 1000
        testing.expect(t, rh_map__add(&m, key_of(limit-1), &values[limit-1]) == nil)
        testing.expect(t, rh_map__len(&m) == limit)
        testing.expect(t, rh_map__add(&m, key_of(limit), &values[limit]) == oc.Core_Error.Container_Is_Full)
        testing.expect(t, rh_map__add(&m, key_of(0), &values[1]) == oc.Core_Error.Container_Is_Full)

        // every inserted key is retrievable; absent keys return nil
        for i in 0..<limit do testing.expect(t, rh_map__get(&m, key_of(i)) == &values[i])
        testing.expect(t, rh_map__get(&m, key_of(limit)) == nil)

        // remove every third key; backward shift must keep all survivors reachable
        removed_count := 0
        for i := 0; i < limit; i += 3 {
            testing.expect(t, rh_map__remove(&m, key_of(i)) == nil)
            removed_count += 1
        }
        testing.expect(t, rh_map__len(&m) == limit - removed_count)
        for i in 0..<limit {
            if i % 3 == 0 {
                testing.expect(t, rh_map__get(&m, key_of(i)) == nil)
            } else {
                testing.expect(t, rh_map__get(&m, key_of(i)) == &values[i])
            }
        }

        // removing an absent key fails; re-inserting removed keys works
        testing.expect(t, rh_map__remove(&m, key_of(0)) == oc.Core_Error.Not_Found)
        for i := 0; i < limit; i += 3 {
            testing.expect(t, rh_map__add(&m, key_of(i), &values[i]) == nil)
        }
        testing.expect(t, rh_map__len(&m) == limit)
        for i in 0..<limit do testing.expect(t, rh_map__get(&m, key_of(i)) == &values[i])

        // clear resets and the map stays usable
        rh_map__clear(&m)
        testing.expect(t, rh_map__len(&m) == 0)
        testing.expect(t, rh_map__get(&m, key_of(1)) == nil)
        testing.expect(t, rh_map__add(&m, key_of(1), &values[1]) == nil)
        testing.expect(t, rh_map__get(&m, key_of(1)) == &values[1])
    }
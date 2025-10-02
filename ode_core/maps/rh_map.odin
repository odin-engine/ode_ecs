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

        when MAPS_TESTING {
            self.half_capacity = capacity
        } else {
            self.half_capacity = capacity / 2  // this is for 0.5 load factor
        }
       
        self.mask = capacity - 1

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

    // Resize map
    // rh_map__resize :: proc(self: ^Rh_Map($T)) {
    //     // We dont need resize for ECS
    // }

    // Insert, key is expected to be non-negative
    rh_map__add :: proc(self: ^Rh_Map($T), key: int, value: T) -> (err: oc.Error) {

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

            if probe_distance > self.half_capacity {
                return oc.Core_Error.Container_Is_Full
            }
        }
    }


    @(private)
    rh_map__get_from_hash :: proc(self: ^Rh_Map($V), key: int, ix: int) -> (V, int) {
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
    rh_map__remove :: proc(self: ^Rh_Map($T), key: int) -> oc.Error{
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

    // Iterator
    // iter :: proc(self: ^Rh_Map($T), f: proc(key: int, value: ^T)) {
    //     for i in 0..<self.capacity {
    //         if self.keys[i] != 0 {
    //             f(self.keys[i], &self.values[i])
    //         }
    //     }
    // }

    // }
    
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

        testing.expect(t, MAPS_TESTING == true)
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
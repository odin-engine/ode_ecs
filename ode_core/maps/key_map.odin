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
// Key_Map - Robin Hood only keys map
// Expected key to be a positive integer

    // Key_Map_Item in the table
    Key_Map_Item :: struct {
        key:  int,
        dist: int, // probe distance
    }

    // Key_Map type
    Key_Map :: struct {
        items:          []Key_Map_Item,
        count:          int,
        mask:           int, 
        capacity:       int,
        half_capacity:  int, 
    }

    key_map__is_valid :: proc (self: ^Key_Map) -> bool {
        if self == nil do return false 
        if self.items == nil do return false 
        if self.mask == 0 do return false 
        if self.capacity <= 0 do return false 
        if self.half_capacity <= 0 do return false 

        return true
    }

    // mix bits (simple but fast hash for ints)
    key_map__hash :: #force_inline proc "contextless" (self: ^Key_Map, key: int) -> (v: int) {
        when MAPS_TESTING {
            // For testing we need more predictable hash values
            return key & self.mask
        } else {
            //return (key * 11400714819323198485) & self.mask
            return key & self.mask // could suffice 
        }
    }

    key_map__next_key :: proc(self: ^Key_Map, start_ix: int) -> (key: int, ix: int) {
        i := start_ix
        k : int

        for {
            if i < 0 || i >= self.capacity do return oc.DELETED_INDEX, oc.DELETED_INDEX

            k = self.items[i].key

            if k != oc.DELETED_INDEX do return k, i

            i += 1
        }
    }

    // Initialize with given capacity (will round to power of two)
    key_map__init :: proc(self: ^Key_Map,  #any_int capacity: int, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)
        assert(capacity > 1, loc = loc)

        if !math.is_power_of_two(capacity) do return oc.Core_Error.Capacity_Is_Not_Power_Of_2

        self.capacity = capacity
        when !MAPS_TESTING {
            if self.capacity < 8 do self.capacity = 8
        }

        self.items = make([]Key_Map_Item, self.capacity, allocator) or_return

        self.mask = capacity - 1

        when MAPS_TESTING {
            self.half_capacity = capacity
        } else {
            self.half_capacity = capacity / 2  // this is for 0.5 load factor
        }

        // fmt.println("YAYAY", self)
        key_map__clear(self)

        return nil
    }

    key_map__terminate :: proc(self: ^Key_Map, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
                assert(self != nil, loc = loc)

        delete(self.items, allocator) or_return

        self.capacity = 0
        self.count = 0

        self.half_capacity = 0
        self.mask = 0

        return nil
    }

    key_map__clear :: #force_inline proc "contextless" (self: ^Key_Map) {
        for i:=0; i < self.capacity; i+=1 {
            self.items[i].key = oc.DELETED_INDEX
        }
        self.count = 0
    }

    // Internal resize
        // key_map__resize :: proc(set: ^Key_Map, new_cap: int) {
        //     old := set.items;
        //     set.items = make([]Key_Map_Item, new_cap);
        //     set.mask = u64(new_cap - 1);
        //     set.count = 0;

        //     for e in old {
        //         if e.used {
        //             hashset_insert(set, e.key);
        //         }
        //     }
        // }

    // Insert key
    key_map__add :: #force_inline proc "contextless" (self: ^Key_Map, key: int) -> (err: oc.Error) {
        
        // if load factor >= 0.5 
        if self.count >= self.half_capacity {
            return oc.Core_Error.Container_Is_Full
        }

        idx := key_map__hash(self, key)
        dist: int = 0
        new_item := Key_Map_Item{key=key, dist=dist}

        for {
            e := &self.items[idx]
            if e.key == oc.DELETED_INDEX {
                e^ = new_item
                self.count += 1
                return nil
            }

            if e.key == key {
                return oc.Core_Error.Already_Exists // already exists
            }

            if e.dist < new_item.dist {
                // swap (Robin Hood)
                tmp := e^
                e^ = new_item
                new_item = tmp
            }

            idx = (idx + 1) & self.mask;
            new_item.dist += 1;

            if new_item.dist > self.half_capacity {
                return oc.Core_Error.Container_Is_Full
            }
        }
    }

    key_map__exists_with_index :: #force_inline proc "contextless" (self: ^Key_Map, key: int) -> (bool, int) {
        idx := key_map__hash(self, key)
        dist: int = 0

        for {
            e := &self.items[idx]
            if e.key == oc.DELETED_INDEX {
                return false, oc.DELETED_INDEX
            }
            if e.key == key {
                return true, idx
            }
            if e.dist < dist {
                return false, oc.DELETED_INDEX // would have been placed earlier
            }
            idx = (idx + 1) & self.mask;
            dist += 1;
        }
    }

    // Contains check
    key_map__exists :: #force_inline proc "contextless" (self: ^Key_Map, key: int) -> bool {
        r, _ := key_map__exists_with_index(self, key)

        return r 
    }
    
    key_map__memory_usage :: #force_inline proc "contextless" (self: ^Key_Map) -> int {
        return size_of(Key_Map) + size_of(Key_Map_Item) * self.capacity
    }

    key_map__len :: #force_inline proc "contextless" (self: ^Key_Map) -> int {
        return self.count
    }

    key_map__cap :: #force_inline proc "contextless" (self: ^Key_Map) -> int {
        return self.capacity
    }

    // Remove key with backshift deletion
    key_map__remove :: #force_inline proc "contextless" (self: ^Key_Map, key: int) -> oc.Error {
        idx := key_map__hash(self, key)
        dist: int = 0

        for {
            e := &self.items[idx]
            if e.key == oc.DELETED_INDEX {
                return oc.Core_Error.Not_Found
            }
            if e.key == key {
                // remove + backshift
                for {
                    next_idx := (idx + 1) & self.mask
                    next := &self.items[next_idx]
                    if next.key == oc.DELETED_INDEX || next.dist == 0 {
                        e^ = Key_Map_Item{ key = oc.DELETED_INDEX, dist = 0 }
                        self.count -= 1
                        return nil
                    }
                    e^ = next^
                    e.dist -= 1
                    idx = next_idx
                    e = &self.items[idx]
                }
            }
            if e.dist < dist {
                return  oc.Core_Error.Not_Found
            }
            idx = (idx + 1) & self.mask
            dist += 1
        }
    }

    key_map__debug_print :: proc(self: ^Key_Map) {
        fmt.println("\nKey_Map debug print (key, dist):")

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
                s := fmt.tprintf("%v", item.dist)
                fmt.printf("%4s, ", s)
            }
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Tests
// 
    
    @(test)
    key_map__test :: proc(t: ^testing.T) {
        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        //
        // Make sure we using simplified hash function for testing
        //

        testing.expect(t, MAPS_TESTING == true)
        testing.expect(t, key_map__hash(&Key_Map{ capacity = 16, mask = 15 }, 0) == 0)
        testing.expect(t, key_map__hash(&Key_Map{ capacity = 16, mask = 15 }, 1) == 1)
        testing.expect(t, key_map__hash(&Key_Map{ capacity = 16, mask = 15 }, 2) == 2)

        //
        // map1
        //

        map1: Key_Map 

        testing.expect(t, key_map__init(&map1, 3, allocator) == oc.Core_Error.Capacity_Is_Not_Power_Of_2)

        testing.expect(t, key_map__init(&map1, 2, allocator) == nil)
         
        testing.expect(t, map1.count == 0)
        testing.expect(t, map1.capacity == 2)
        testing.expect(t, map1.half_capacity == 2)
        testing.expect(t, map1.mask == 1)

        testing.expect(t, key_map__add(&map1, 33) == nil)
        testing.expect(t, key_map__exists(&map1, 33) == true)
        testing.expect(t, map1.count == 1)

        testing.expect(t, key_map__add(&map1, 66) == nil)
        testing.expect(t, key_map__exists(&map1, 66))
        testing.expect(t, map1.count == 2)

        testing.expect(t, key_map__add(&map1, 55) == oc.Core_Error.Container_Is_Full)
        testing.expect(t, !key_map__exists(&map1, 55))
        testing.expect(t, map1.count == 2)

        testing.expect(t, key_map__exists(&map1, 33))
        testing.expect(t, map1.count == 2)
        testing.expect(t, key_map__remove(&map1, 55) == oc.Core_Error.Not_Found) 
        testing.expect(t, key_map__remove(&map1, 33) == nil) 
        testing.expect(t, !key_map__exists(&map1, 33))
        testing.expect(t, map1.count == 1)

        testing.expect(t, key_map__terminate(&map1, allocator) == nil)

        //
        // map2, classic robin hood example
        // a, e, f hash to 0; b, c to 1; d to 2. inserting values in alphabetical order
        //

        map2: Key_Map 
        testing.expect(t, key_map__init(&map2, 8, allocator) == nil)
        testing.expect(t, map2.count == 0)
        testing.expect(t, map2.capacity == 8)
        testing.expect(t, map2.half_capacity == 8)
        testing.expect(t, map2.mask == 0b111)

        a:= 16
        b:= 1
        c:= 17
        d:= 2
        e:= 32
        f:= 64
        g:= 7
        h:= 15
        ii:= 18

        // adding 

        testing.expect(t, key_map__hash(&map2, 0) == 0)

        // insert in an alphabetical order to create collisions
        testing.expect(t, key_map__add(&map2, a) == nil)
        testing.expect(t, key_map__add(&map2, b) == nil)
        testing.expect(t, key_map__add(&map2, c) == nil)
        testing.expect(t, key_map__add(&map2, d) == nil)
        testing.expect(t, key_map__add(&map2, e) == nil)
        testing.expect(t, key_map__add(&map2, f) == nil)

        // // testing locations

        testing.expect(t, map2.items[0].key == a) 
        testing.expect(t, map2.items[1].key == e) 
        testing.expect(t, map2.items[2].key == f) 
        testing.expect(t, map2.items[3].key == b) 
        testing.expect(t, map2.items[4].key == c) 
        testing.expect(t, map2.items[5].key == d)  

        testing.expect(t, key_map__add(&map2, g) == nil)
        testing.expect(t, key_map__add(&map2, h) == nil)
        testing.expect(t, key_map__add(&map2, ii) == oc.Core_Error.Container_Is_Full) // should fail, map full

        //key_map__debug_print(&map2)

        key_map__clear(&map2)

        testing.expect(t, !key_map__exists(&map2, a))
        testing.expect(t, !key_map__exists(&map2, b))
        testing.expect(t, !key_map__exists(&map2, c))
        testing.expect(t, !key_map__exists(&map2, d))

        testing.expect(t, key_map__terminate(&map2, allocator) == nil)

        //
        // map3
        // 

        v1 := 4
        v2 := 8
        v3 := 12
        v4 := 2

        map3: Key_Map 
        testing.expect(t, key_map__init(&map3, 4, allocator) == nil)

        testing.expect(t, key_map__add(&map3, v1) == nil)
        testing.expect(t, key_map__add(&map3, v2) == nil)
        testing.expect(t, key_map__add(&map3, v3) == nil)
        testing.expect(t, key_map__add(&map3, v4) == nil)

        // key_map__debug_print(&map3)

        testing.expect(t, map3.items[2].key == v3) 

        testing.expect(t, key_map__exists(&map3, v2))
        testing.expect(t, key_map__exists(&map3, v1))
         
        testing.expect(t, map3.items[3].key == v4) 

        testing.expect(t, key_map__remove(&map3, v2) == nil) // remove
        testing.expect(t, !key_map__exists(&map3, v2))

        testing.expect(t, key_map__exists(&map3, v1))
        testing.expect(t, key_map__exists(&map3, v3))

        testing.expect(t, map3.items[2].key == v4) 

        testing.expect(t, key_map__remove(&map3, v1) == nil) // remove
        testing.expect(t, !key_map__exists(&map3, v1))

        testing.expect(t, map3.items[0].key == v3) 

        //key_map__debug_print(&map3)

        testing.expect(t, map3.items[1].key == oc.DELETED_INDEX)

        testing.expect(t, map3.items[2].key == v4)

        testing.expect(t, map3.items[3].key == oc.DELETED_INDEX)

        testing.expect(t, key_map__add(&map3, v2) == nil)
        testing.expect(t, key_map__add(&map3, v1) == nil)

        // key_map__debug_print(&map3)

        v, i := key_map__exists_with_index(&map3, v1)
        testing.expect(t, v)
        testing.expect(t, i < 3 )

        testing.expect(t, key_map__remove(&map3, v2) == nil) // remove
        testing.expect(t, key_map__remove(&map3, v3) == nil) // remove

        // key_map__debug_print(&map3)

        v, i = key_map__exists_with_index(&map3, v1)
        testing.expect(t, v)
        testing.expect(t, i < 3 )

        testing.expect(t, key_map__add(&map3, v2) == nil)
        testing.expect(t, key_map__add(&map3, v3) == nil)

        v, i = key_map__exists_with_index(&map3, v2)
        testing.expect(t, v)
        testing.expect(t, i < 3 )

        v, i = key_map__exists_with_index(&map3, v3)
        testing.expect(t, v)
        testing.expect(t, i < 3 )

        testing.expect(t, key_map__remove(&map3, v2) == nil) // remove
        
        testing.expect(t, map3.items[3].key == oc.DELETED_INDEX)

        testing.expect(t, key_map__add(&map3, v2) == nil)
        testing.expect(t, key_map__add(&map3, v2) == oc.Core_Error.Container_Is_Full)
        testing.expect(t, key_map__remove(&map3, v1) == nil) // remove

        testing.expect(t, key_map__add(&map3, 3) == nil)
        testing.expect(t, key_map__remove(&map3, v3) == nil) // remove
        testing.expect(t, key_map__add(&map3, 7) == nil)
          
        v, i = key_map__exists_with_index(&map3, 7)
        testing.expect(t, v)
        testing.expect(t, i == 0)

        v, i = key_map__exists_with_index(&map3, 8)
        testing.expect(t, v)
        testing.expect(t, i == 1)

        testing.expect(t, key_map__remove(&map3, 3) == nil) // remove
        
        testing.expect(t, key_map__terminate(&map3, allocator) == nil)
    }
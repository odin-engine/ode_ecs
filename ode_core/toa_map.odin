/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_core

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"
    import "core:testing"
    import "core:slice"

///////////////////////////////////////////////////////////////////////////////
// Tiny Open Addressing Map (tiny one array map, int to $V). V expected to be a pointer.

    Toa_Map_Item :: struct($V: typeid) {
        key: int,
        value: V,
    }

    Toa_Map :: struct($CAP: int, $V: typeid) {
        items: [CAP]Toa_Map_Item(V),
    }

    // Returns pointer to item with key or pointer to next empty item
    toa_map__find_item :: proc(self: ^Toa_Map($CAP, $V), key: int) -> ^Toa_Map_Item(V) {
        ix := key % CAP
        p := &self.items[ix]
  
        if p.key == key || p.value == nil do return p

        pi: int
        for i:=1; i<CAP; i+=1 { 
            pi = ix + i
            if pi >= CAP {
                pi = 0
                ix = 0
                i = 0
            }
            
            p = &self.items[pi]
            if p.key == key || p.value == nil do return p
        }

        return nil
    }

    toa_map__get :: proc(self: ^Toa_Map($CAP, $V), key: int) -> V {
        p := toa_map__find_item(self, key)

        if p == nil do return nil

        return p.value
    } 

    toa_map__add :: proc(self: ^Toa_Map($CAP, $V), key: int, value: V) -> Core_Error {
        p := toa_map__find_item(self, key)

        if p == nil do return Core_Error.Container_Is_Full

        p.key = key
        p.value = value

        return nil
    }

    toa_map__remove :: proc(self: ^Toa_Map($CAP, $V), key: int) -> Core_Error {
        p := toa_map__find_item(self, key)

        if p == nil do return Core_Error.Not_Found

        p.key = 0
        p.value = nil

        return nil
    }
    
    toa_map__clear :: proc(self: ^Toa_Map($CAP, $V)) {
        slice.zero(self.items[:CAP])
    }

///////////////////////////////////////////////////////////////////////////////
// Tests
// 
    
    @(test)
    toa_map__test :: proc(t: ^testing.T) {
        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        v1: int = 33
        v2: int = 55
        v3: int = 66

        map1: Toa_Map(2, ^int) 

        item := toa_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 0)
        testing.expect(t, item.value == nil)

        testing.expect(t, toa_map__add(&map1, 33, &v1) == nil)

        item = toa_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 33)
        testing.expect(t, item.value == &v1)

        testing.expect(t, toa_map__add(&map1, 66, &v3) == nil)

        item = toa_map__find_item(&map1, 66)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 66)
        testing.expect(t, item.value == &v3)

        testing.expect(t, toa_map__add(&map1, 55, &v2) == Core_Error.Container_Is_Full)

        testing.expect(t, toa_map__remove(&map1, 22) == Core_Error.Not_Found)
        testing.expect(t, toa_map__remove(&map1, 33) == nil)

        item = toa_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 0)
        testing.expect(t, item.value == nil)

        testing.expect(t, toa_map__add(&map1, 55, &v2) == nil)

        item = toa_map__find_item(&map1, 55)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 55)
        testing.expect(t, item.value == &v2)

        testing.expect(t, toa_map__remove(&map1, 66) == nil)
        testing.expect(t, toa_map__add(&map1, 1, &v2) == nil)

        item = toa_map__find_item(&map1, 1)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 1)
        testing.expect(t, item.value == &v2)

        testing.expect(t, toa_map__add(&map1, 44, &v2) == Core_Error.Container_Is_Full)

        testing.expect(t, toa_map__get(&map1, 44) == nil)
        testing.expect(t, toa_map__get(&map1, 66) == nil)
        testing.expect(t, toa_map__get(&map1, 55) == &v2)
        testing.expect(t, toa_map__get(&map1, 1) == &v2)

        toa_map__clear(&map1)

        testing.expect(t, toa_map__get(&map1, 44) == nil)
        testing.expect(t, toa_map__get(&map1, 66) == nil)
        testing.expect(t, toa_map__get(&map1, 55) == nil)
        testing.expect(t, toa_map__get(&map1, 1) == nil)
    }
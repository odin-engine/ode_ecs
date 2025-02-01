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
// Tiny Open Addressing Map (tiny one array map, index to $V). 
// index expected to be POSITIVE int
// V expected to be a pointer.

    Toa_Map_Item :: struct($V: typeid) {
        key: int,
        value: V,
    }

    Toa_Map :: struct($CAP: int, $V: typeid) {
        items: [CAP]Toa_Map_Item(V),
    }

    @(private)
    toa_map__find_item_from_hash :: proc(self: ^Toa_Map($CAP, $V), key: int, ix: int) -> (^Toa_Map_Item(V), int) {
        pi: int = ix
        p: ^Toa_Map_Item(V)
        for i:=0; i<CAP; i+=1 { 
            p = &self.items[pi]
            if p.key == key || p.value == nil do return p, pi

            pi += 1
            if pi >= CAP {
                pi = 0
            }
        }

        return nil, DELETED_INDEX
    }

    @(private)
    toa_map__hash :: #force_inline proc "contextless" (self: ^Toa_Map($CAP, $V), key: int) -> int {
        return key % CAP
    }

    // Returns pointer to item with key or pointer to next empty item
    toa_map__find_item :: proc(self: ^Toa_Map($CAP, $V), key: int) -> ^Toa_Map_Item(V) {
        ix := toa_map__hash(self, key)
        p, _ := toa_map__find_item_from_hash(self, key, ix)

        return p
    }

    toa_map__get :: proc(self: ^Toa_Map($CAP, $V), key: int) -> V {
        p := toa_map__find_item(self, key)

        if p == nil do return nil

        return p.value
    } 

    toa_map__find_item_with_index :: proc(self: ^Toa_Map($CAP, $V), key: int) -> (^Toa_Map_Item(V), int) {
        ix := toa_map__hash(self, key)
        return toa_map__find_item_from_hash(self, key, ix)
    }

    toa_map__get_with_index :: proc(self: ^Toa_Map($CAP, $V), key: int) -> (V, int) {
        p, i := toa_map__find_item_with_index(self, key)

        if p == nil do return nil, DELETED_INDEX

        return p.value, i
    } 

    toa_map__add :: proc(self: ^Toa_Map($CAP, $V), key: int, value: V) -> Core_Error {
        assert(value != nil)

        p := toa_map__find_item(self, key)

        if p == nil do return Core_Error.Container_Is_Full

        p.key = key
        p.value = value

        return nil
    }

    toa_map__remove :: proc(self: ^Toa_Map($CAP, $V), key: int) -> Core_Error {

        hash := toa_map__hash(self, key)

        p, f_ix := toa_map__find_item_from_hash(self, key, hash)

        if p == nil do return Core_Error.Not_Found

        p.key = 0
        p.value = nil

        n_ix: int = f_ix
        prev_ix: int 
        n_hash: int = hash

        temp: [CAP]Toa_Map_Item(V)
        temp_len: int = 0

        // Shift to left same hash items
        for i:=0; i<CAP; i+=1 { 
            prev_ix = n_ix
            n_ix += 1
            if n_ix >= CAP {
                n_ix = 0
            }
            
            p = &self.items[n_ix]
            if p.value == nil do break

            n_hash = toa_map__hash(self, p.key)
            //if n_hash == hash { // same hash items
                //self.items[prev_ix] = p^
                temp[temp_len] = p^
                temp_len += 1

                p.key = 0
                p.value = nil
            // }
            // else {
            //     break
            // }
        }

        // Shift to left items with hash < current array index, it means they were suppoused to be on left
        // for i:=0; i<CAP; i+=1 { 
        //     p = &self.items[n_ix]
        //     if p.value == nil do break

        //     n_hash = toa_map__hash(self, p.key)
        //     if n_hash < n_ix { // hash < current array index
        //         /// self.items[prev_ix] = p^
        //         temp[temp_len] = p^
        //         temp_len += 1
                
        //         p.key = 0
        //         p.value = nil
        //     }
        //     else {
        //         break
        //     }

        //     prev_ix = n_ix
        //     n_ix += 1
        //     if n_ix >= CAP {
        //         n_ix = 0
        //     }
        // }

        // readd 
        for i:=0; i < temp_len; i+=1 {
            toa_map__add(self, temp[i].key, temp[i].value)
        }

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
        v4: int = 77

        //
        // map1
        //

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

        //
        // map2 
        // 

        map2: Toa_Map(4, ^int) 
        testing.expect(t, toa_map__add(&map2, 4, &v1) == nil)
        testing.expect(t, toa_map__add(&map2, 8, &v2) == nil)
        testing.expect(t, toa_map__add(&map2, 12, &v3) == nil)
        testing.expect(t, toa_map__add(&map2, 2, &v4) == nil)

        v,i := toa_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 2)

        testing.expect(t, toa_map__get(&map2, 8) == &v2)
        testing.expect(t, toa_map__get(&map2, 4) == &v1)
         
        v,i = toa_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 3)

        testing.expect(t, toa_map__remove(&map2, 8) == nil) // remove
        testing.expect(t, toa_map__get(&map2, 8) == nil)

        v,i = toa_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)

        v,i = toa_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)

        v,i = toa_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 2)

        testing.expect(t, toa_map__remove(&map2, 4) == nil) // remove
        testing.expect(t, toa_map__get(&map2, 4) == nil)

        v,i = toa_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 0)

        testing.expect(t, map2.items[1].key == 0)
        testing.expect(t, map2.items[1].value == nil)

        v,i = toa_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 2)

        testing.expect(t, map2.items[3].key == 0)
        testing.expect(t, map2.items[3].value == nil)

        testing.expect(t, toa_map__add(&map2, 8, &v2) == nil)
        testing.expect(t, toa_map__add(&map2, 4, &v1) == nil)

        v,i = toa_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)
        testing.expect(t, i == 3)

        testing.expect(t, toa_map__remove(&map2, 8) == nil) // remove
        testing.expect(t, toa_map__remove(&map2, 12) == nil) // remove

        v,i = toa_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)
    }
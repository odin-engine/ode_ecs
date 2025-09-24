/*
    2025 (c) Oleh, https://github.com/zm69
*/
package maps

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"
    import "core:testing"
    import "core:slice"
    import "core:math"

// ODE_CORE
    import oc ".."

///////////////////////////////////////////////////////////////////////////////
// Tt_Map - Tiny Table Map (tiny one array map, index to $V). 
// index expected to be POSITIVE int
// V expected to be a pointer.

    Tt_Map_Item :: struct($V: typeid) {
        key: int,
        value: V,
    }
 
    // CAP should be number which is power of 2
    Tt_Map :: struct($CAP: int, $V: typeid) {
        items: [CAP]Tt_Map_Item(V),
    }

    @(private)
    tt_map__find_item_from_hash :: proc(self: ^Tt_Map($CAP, $V), key: int, ix: int) -> (^Tt_Map_Item(V), int) {
        pi: int = ix
        p: ^Tt_Map_Item(V)
        for i:=0; i<CAP; i+=1 { 
            p = &self.items[pi]
            if p.key == key || p.value == nil do return p, pi

            pi += 1
            if pi >= CAP {
                pi = 0
            }
        }

        return nil, oc.DELETED_INDEX
    }

    @(private)
    tt_map__hash :: #force_inline proc "contextless" (self: ^Tt_Map($CAP, $V), key: int) -> int {
        // & is much faster than %
        return key & (CAP - 1)
    }

    // Returns pointer to item with key or pointer to next empty item
    tt_map__find_item :: proc(self: ^Tt_Map($CAP, $V), key: int) -> ^Tt_Map_Item(V) {
        ix := tt_map__hash(self, key)
        p, _ := tt_map__find_item_from_hash(self, key, ix)

        return p
    }

    tt_map__get :: proc(self: ^Tt_Map($CAP, $V), key: int) -> V {
        p := tt_map__find_item(self, key)

        if p == nil do return nil

        return p.value
    } 

    tt_map__find_item_with_index :: proc(self: ^Tt_Map($CAP, $V), key: int) -> (^Tt_Map_Item(V), int) {
        ix := tt_map__hash(self, key)
        return tt_map__find_item_from_hash(self, key, ix)
    }

    tt_map__get_with_index :: proc(self: ^Tt_Map($CAP, $V), key: int) -> (V, int) {
        p, i := tt_map__find_item_with_index(self, key)

        if p == nil do return nil, oc.DELETED_INDEX

        return p.value, i
    } 

    tt_map__add :: proc(self: ^Tt_Map($CAP, $V), key: int, value: V) -> oc.Core_Error {
        assert(value != nil)

        p := tt_map__find_item(self, key)

        if p == nil do return oc.Core_Error.Container_Is_Full

        p.key = key
        p.value = value

        return nil
    }

    tt_map__remove :: proc(self: ^Tt_Map($CAP, $V), key: int) -> oc.Core_Error {

        hash := tt_map__hash(self, key)

        p, f_ix := tt_map__find_item_from_hash(self, key, hash)

        if p == nil do return oc.Core_Error.Not_Found

        p.key = 0
        p.value = nil

        n_ix: int = f_ix

        temp: [CAP]Tt_Map_Item(V)
        temp_len: int = 0

        // Temporarily remove bucket items on right
        for i:=0; i<CAP; i+=1 { 
            n_ix += 1
            if n_ix >= CAP {
                n_ix = 0
            }
            
            p = &self.items[n_ix]
            if p.value == nil do break

            temp[temp_len] = p^
            temp_len += 1

            p.key = 0
            p.value = nil
        }

        // Readd 
        for i:=0; i < temp_len; i+=1 {
            tt_map__add(self, temp[i].key, temp[i].value)
        }

        return nil
    }
    
    tt_map__clear :: proc(self: ^Tt_Map($CAP, $V)) {
        //slice.zero(self.items[:CAP])
        for i:=0; i<CAP; i+=1 { 
            self.items[i].key = oc.DELETED_INDEX
            self.items[i].value = nil
        }
    }

    tt_map__memory_usage :: proc(self: ^Tt_Map($CAP, $V)) -> int {
        return sizeof(Tt_Map($CAP, $V))
    }   

///////////////////////////////////////////////////////////////////////////////
// Tests
// 
    
    @(test)
    tt_map__test :: proc(t: ^testing.T) {
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

        map1: Tt_Map(2, ^int) 

        item := tt_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 0)
        testing.expect(t, item.value == nil)

        testing.expect(t, tt_map__add(&map1, 33, &v1) == nil)

        item = tt_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 33)
        testing.expect(t, item.value == &v1)

        testing.expect(t, tt_map__add(&map1, 66, &v3) == nil)

        item = tt_map__find_item(&map1, 66)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 66)
        testing.expect(t, item.value == &v3)

        testing.expect(t, tt_map__add(&map1, 55, &v2) == oc.Core_Error.Container_Is_Full)

        testing.expect(t, tt_map__remove(&map1, 22) == oc.Core_Error.Not_Found)
        testing.expect(t, tt_map__remove(&map1, 33) == nil)

        item = tt_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 0)
        testing.expect(t, item.value == nil)

        testing.expect(t, tt_map__add(&map1, 55, &v2) == nil)

        item = tt_map__find_item(&map1, 55)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 55)
        testing.expect(t, item.value == &v2)

        testing.expect(t, tt_map__remove(&map1, 66) == nil)
        testing.expect(t, tt_map__add(&map1, 1, &v2) == nil)

        item = tt_map__find_item(&map1, 1)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 1)
        testing.expect(t, item.value == &v2)

        testing.expect(t, tt_map__add(&map1, 44, &v2) == oc.Core_Error.Container_Is_Full)

        testing.expect(t, tt_map__get(&map1, 44) == nil)
        testing.expect(t, tt_map__get(&map1, 66) == nil)
        testing.expect(t, tt_map__get(&map1, 55) == &v2)
        testing.expect(t, tt_map__get(&map1, 1) == &v2)

        tt_map__clear(&map1)

        testing.expect(t, tt_map__get(&map1, 44) == nil)
        testing.expect(t, tt_map__get(&map1, 66) == nil)
        testing.expect(t, tt_map__get(&map1, 55) == nil)
        testing.expect(t, tt_map__get(&map1, 1) == nil)

        //
        // map2 
        // 

        map2: Tt_Map(4, ^int) 
        testing.expect(t, tt_map__add(&map2, 4, &v1) == nil)
        testing.expect(t, tt_map__add(&map2, 8, &v2) == nil)
        testing.expect(t, tt_map__add(&map2, 12, &v3) == nil)
        testing.expect(t, tt_map__add(&map2, 2, &v4) == nil)

        v,i := tt_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 2)

        testing.expect(t, tt_map__get(&map2, 8) == &v2)
        testing.expect(t, tt_map__get(&map2, 4) == &v1)
         
        v,i = tt_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 3)

        testing.expect(t, tt_map__remove(&map2, 8) == nil) // remove
        testing.expect(t, tt_map__get(&map2, 8) == nil)

        v,i = tt_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)

        v,i = tt_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)

        v,i = tt_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 2)

        testing.expect(t, tt_map__remove(&map2, 4) == nil) // remove
        testing.expect(t, tt_map__get(&map2, 4) == nil)

        v,i = tt_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 0)

        testing.expect(t, map2.items[1].key == 0)
        testing.expect(t, map2.items[1].value == nil)

        v,i = tt_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 2)

        testing.expect(t, map2.items[3].key == 0)
        testing.expect(t, map2.items[3].value == nil)

        testing.expect(t, tt_map__add(&map2, 8, &v2) == nil)
        testing.expect(t, tt_map__add(&map2, 4, &v1) == nil)

        v,i = tt_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)
        testing.expect(t, i == 3)

        testing.expect(t, tt_map__remove(&map2, 8) == nil) // remove
        testing.expect(t, tt_map__remove(&map2, 12) == nil) // remove

        v,i = tt_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)
    }



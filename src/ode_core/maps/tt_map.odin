/*
    2025 (c) Oleh, https://github.com/zm69
*/
package maps

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"
    import "core:slice"
    import "core:math"

// ODE_CORE
    import oc ".."

///////////////////////////////////////////////////////////////////////////////
// Tt_Map - Tiny Table Map (tiny one-array map, index to $V).
// index expected to be a positive int; V expected to be a pointer.

    Tt_Map_Item :: struct($V: typeid) {
        key: int,
        value: V,
    }
 
    // CAP should be number which is power of 2
    Tt_Map :: struct($CAP: int, $V: typeid) {
        items: [CAP]Tt_Map_Item(V),
    }

    @(private)
    // #no_bounds_check: pi wraps manually and stays < CAP
    tt_map__find_item_from_hash :: proc(self: ^Tt_Map($CAP, $V), key: int, ix: int) -> (^Tt_Map_Item(V), int) #no_bounds_check {
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
        return key & (CAP - 1) // & is much faster than %
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
        when VALIDATIONS do assert(value != nil) // hot path: runs on every Tiny_Table add/remove/pack

        p := tt_map__find_item(self, key)

        if p == nil do return oc.Core_Error.Container_Is_Full

        p.key = key
        p.value = value

        return nil
    }

    // Removes an item already located by tt_map__find_item_with_index, skipping re-hashing/re-probing.
    tt_map__remove_found :: proc(self: ^Tt_Map($CAP, $V), p: ^Tt_Map_Item(V), f_ix: int) {
        p := p

        p.key = oc.DELETED_INDEX
        p.value = nil

        n_ix: int = f_ix

        temp: [CAP]Tt_Map_Item(V) = --- // written before read below
        temp_len: int = 0

        // temporarily remove bucket items to the right
        for i:=0; i<CAP; i+=1 {
            n_ix += 1
            if n_ix >= CAP {
                n_ix = 0
            }

            p = &self.items[n_ix]
            if p.value == nil do break

            temp[temp_len] = p^
            temp_len += 1

            p.key = oc.DELETED_INDEX
            p.value = nil
        }

        // re-add
        for i:=0; i < temp_len; i+=1 {
            tt_map__add(self, temp[i].key, temp[i].value)
        }
    }

    tt_map__remove :: proc(self: ^Tt_Map($CAP, $V), key: int) -> oc.Core_Error {
        p, f_ix := tt_map__find_item_with_index(self, key)

        // find returns the first empty slot when the key is absent, not a match
        if p == nil || p.value == nil do return oc.Core_Error.Not_Found

        tt_map__remove_found(self, p, f_ix)

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
        return size_of(self^)
    }

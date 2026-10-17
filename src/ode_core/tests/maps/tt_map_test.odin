/*
    2025 (c) Oleh, https://github.com/zm69
*/
package maps_tests

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"
    import "core:testing"
    import "core:slice"
    import "core:math"

// ODE_CORE
    import oc "../.."
    import maps "../../maps"

    @(test)
    tt_map__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        v1: int = 33
        v2: int = 55
        v3: int = 66
        v4: int = 77

        //
        // map1
        //

        map1: maps.Tt_Map(2, ^int)

        item := maps.tt_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 0)
        testing.expect(t, item.value == nil)

        testing.expect(t, maps.tt_map__add(&map1, 33, &v1) == nil)

        item = maps.tt_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 33)
        testing.expect(t, item.value == &v1)

        testing.expect(t, maps.tt_map__add(&map1, 66, &v3) == nil)

        item = maps.tt_map__find_item(&map1, 66)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 66)
        testing.expect(t, item.value == &v3)

        testing.expect(t, maps.tt_map__add(&map1, 55, &v2) == oc.Core_Error.Container_Is_Full)

        testing.expect(t, maps.tt_map__remove(&map1, 22) == oc.Core_Error.Not_Found)
        testing.expect(t, maps.tt_map__remove(&map1, 33) == nil)

        // removing an already-removed (absent) key must not "succeed"
        testing.expect(t, maps.tt_map__remove(&map1, 33) == oc.Core_Error.Not_Found)

        item = maps.tt_map__find_item(&map1, 33)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == oc.DELETED_INDEX)
        testing.expect(t, item.value == nil)

        testing.expect(t, maps.tt_map__add(&map1, 55, &v2) == nil)

        item = maps.tt_map__find_item(&map1, 55)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 55)
        testing.expect(t, item.value == &v2)

        testing.expect(t, maps.tt_map__remove(&map1, 66) == nil)
        testing.expect(t, maps.tt_map__add(&map1, 1, &v2) == nil)

        item = maps.tt_map__find_item(&map1, 1)

        testing.expect(t, item != nil)
        testing.expect(t, item.key == 1)
        testing.expect(t, item.value == &v2)

        testing.expect(t, maps.tt_map__add(&map1, 44, &v2) == oc.Core_Error.Container_Is_Full)

        testing.expect(t, maps.tt_map__get(&map1, 44) == nil)
        testing.expect(t, maps.tt_map__get(&map1, 66) == nil)
        testing.expect(t, maps.tt_map__get(&map1, 55) == &v2)
        testing.expect(t, maps.tt_map__get(&map1, 1) == &v2)

        maps.tt_map__clear(&map1)

        testing.expect(t, maps.tt_map__get(&map1, 44) == nil)
        testing.expect(t, maps.tt_map__get(&map1, 66) == nil)
        testing.expect(t, maps.tt_map__get(&map1, 55) == nil)
        testing.expect(t, maps.tt_map__get(&map1, 1) == nil)

        //
        // map2
        // 

        map2: maps.Tt_Map(4, ^int)
        testing.expect(t, maps.tt_map__add(&map2, 4, &v1) == nil)
        testing.expect(t, maps.tt_map__add(&map2, 8, &v2) == nil)
        testing.expect(t, maps.tt_map__add(&map2, 12, &v3) == nil)
        testing.expect(t, maps.tt_map__add(&map2, 2, &v4) == nil)

        v,i := maps.tt_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 2)

        testing.expect(t, maps.tt_map__get(&map2, 8) == &v2)
        testing.expect(t, maps.tt_map__get(&map2, 4) == &v1)
         
        v,i = maps.tt_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 3)

        testing.expect(t, maps.tt_map__remove(&map2, 8) == nil)
        testing.expect(t, maps.tt_map__get(&map2, 8) == nil)

        v,i = maps.tt_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)

        v,i = maps.tt_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)

        v,i = maps.tt_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 2)

        testing.expect(t, maps.tt_map__remove(&map2, 4) == nil)
        testing.expect(t, maps.tt_map__get(&map2, 4) == nil)

        v,i = maps.tt_map__get_with_index(&map2, 12)
        testing.expect(t, v == &v3)
        testing.expect(t, i == 0)

        testing.expect(t, map2.items[1].key == oc.DELETED_INDEX)
        testing.expect(t, map2.items[1].value == nil)

        v,i = maps.tt_map__get_with_index(&map2, 2)
        testing.expect(t, v == &v4)
        testing.expect(t, i == 2)

        testing.expect(t, map2.items[3].key == oc.DELETED_INDEX)
        testing.expect(t, map2.items[3].value == nil)

        // absent key with empty slots present in the probe chain: still Not_Found
        testing.expect(t, maps.tt_map__remove(&map2, 99) == oc.Core_Error.Not_Found)

        testing.expect(t, maps.tt_map__add(&map2, 8, &v2) == nil)
        testing.expect(t, maps.tt_map__add(&map2, 4, &v1) == nil)

        v,i = maps.tt_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)
        testing.expect(t, i == 3)

        testing.expect(t, maps.tt_map__remove(&map2, 8) == nil)
        testing.expect(t, maps.tt_map__remove(&map2, 12) == nil)

        v,i = maps.tt_map__get_with_index(&map2, 4)
        testing.expect(t, v == &v1)

        // instantiate memory_usage so a broken body can't hide behind genericity
        testing.expect(t, maps.tt_map__memory_usage(&map1) == size_of(map1))
        testing.expect(t, maps.tt_map__memory_usage(&map2) == size_of(map2))
    }

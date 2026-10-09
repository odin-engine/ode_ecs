/*
    2025 (c) Oleh, https://github.com/zm69
*/
#+build !js
package ode_core

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"
    import "core:testing"

    @(test)
    dense_arr__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        arr: Dense_Arr(int)

        a : int = 66
        b : int = 99
        c : int = 88

        alloc_err: runtime.Allocator_Error
        err: Error
        ix: int

        defer dense_arr__terminate(&arr, allocator)
        alloc_err = dense_arr__init(&arr, 2, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)

        ix, err = dense_arr__add(&arr, a)
        testing.expect(t, ix == 0)
        testing.expect(t, err == Core_Error.None)

        ix, err = dense_arr__add(&arr, b)
        testing.expect(t, ix == 1)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, dense_arr__len(&arr) == 2)
        testing.expect(t, arr.items[0] == 66)
        testing.expect(t, arr.items[1] == 99)

        ix, err = dense_arr__add(&arr, c)
        testing.expect(t, ix == DELETED_INDEX)
        testing.expect(t, err == Core_Error.Container_Is_Full)
        testing.expect(t, dense_arr__len(&arr) == 2)

        // dense_arr__remove_by_index(arr, 999)
        //testing.expect(t, err == Core_Error.Out_Of_Bounds)

        dense_arr__remove_by_index(&arr, 0)

        testing.expect(t, dense_arr__len(&arr) == 1)
        testing.expect(t, arr.items[0] == 99)

        err = dense_arr__remove_by_value(&arr, b)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, dense_arr__len(&arr) == 0)

        err = dense_arr__remove_by_value(&arr, c)
        testing.expect(t, err == Core_Error.Not_Found)

        ix, err = dense_arr__add(&arr, a)
        testing.expect(t, ix == 0)
        testing.expect(t, err == Core_Error.None)

        ix, err = dense_arr__add(&arr, b)
        testing.expect(t, ix == 1)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, dense_arr__len(&arr) == 2)

        dense_arr__remove_by_index(&arr, 1)
        testing.expect(t, dense_arr__len(&arr) == 1)
        testing.expect(t, arr.items[0] == 66)

        // clear zeroes the memory AND resets len, and the array stays usable
        dense_arr__clear(&arr)
        testing.expect(t, dense_arr__len(&arr) == 0)

        ix, err = dense_arr__add(&arr, b)
        testing.expect(t, ix == 0)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, dense_arr__len(&arr) == 1)
        testing.expect(t, arr.items[0] == 99)

        testing.expect(t, dense_arr__memory_usage(&arr) > 0)
    }

    @(test)
    dense_arr__is_valid__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        zero_value: Dense_Arr(int)
        testing.expect(t, dense_arr__is_valid(&zero_value) == false)
        nil_da: ^Dense_Arr(int)
        testing.expect(t, dense_arr__is_valid(nil_da) == false)

        da: Dense_Arr(int)
        alloc_err := dense_arr__init(&da, 2, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)
        testing.expect(t, dense_arr__is_valid(&da))

        alloc_err = dense_arr__terminate(&da, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)
        testing.expect(t, dense_arr__is_valid(&da) == false)
    }

    @(test)
    dense_arr__is_valid_or_empty__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        // never allocated -- legitimately empty, should read as valid
        zero_value: Dense_Arr(int)
        testing.expect(t, dense_arr__is_valid_or_empty(&zero_value))

        nil_da: ^Dense_Arr(int)
        testing.expect(t, dense_arr__is_valid_or_empty(nil_da) == false)

        da: Dense_Arr(int)
        alloc_err := dense_arr__init(&da, 2, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)
        testing.expect(t, dense_arr__is_valid_or_empty(&da))

        // terminated -- items collapses back to nil, should read as valid (empty) again
        alloc_err = dense_arr__terminate(&da, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)
        testing.expect(t, dense_arr__is_valid_or_empty(&da))
    }

    @(test)
    dense_arr__resize__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        // resize-up from a zero-value array behaves like init
        arr: Dense_Arr(int)
        defer dense_arr__terminate(&arr, allocator)
        err := dense_arr__resize(&arr, 2, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, arr.cap == 2)
        testing.expect(t, dense_arr__len(&arr) == 0)

        // resize-up preserves existing items
        _, aerr := dense_arr__add(&arr, 11)
        testing.expect(t, aerr == Core_Error.None)
        _, aerr = dense_arr__add(&arr, 22)
        testing.expect(t, aerr == Core_Error.None)

        err = dense_arr__resize(&arr, 4, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, arr.cap == 4)
        testing.expect(t, dense_arr__len(&arr) == 2)
        testing.expect(t, arr.items[0] == 11)
        testing.expect(t, arr.items[1] == 22)

        // resize-down to exactly the live length is allowed
        err = dense_arr__resize(&arr, 2, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, arr.cap == 2)
        testing.expect(t, dense_arr__len(&arr) == 2)
        testing.expect(t, arr.items[0] == 11)
        testing.expect(t, arr.items[1] == 22)

        // resize-down below the live length is rejected, array untouched
        err = dense_arr__resize(&arr, 1, allocator)
        testing.expect(t, err == Core_Error.Cannot_Shrink_Below_Length)
        testing.expect(t, arr.cap == 2)
        testing.expect(t, dense_arr__len(&arr) == 2)

        // resize to the same cap is a no-op
        err = dense_arr__resize(&arr, 2, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, arr.cap == 2)
        testing.expect(t, dense_arr__len(&arr) == 2)
    }

    @(test)
    dense_arr__add_growing__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        arr: Dense_Arr(int)
        defer dense_arr__terminate(&arr, allocator)
        alloc_err := dense_arr__init(&arr, 2, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)

        // fills the initial cap without growing
        _, err := dense_arr__add_growing(&arr, 1, allocator)
        testing.expect(t, err == nil)
        _, err = dense_arr__add_growing(&arr, 2, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, arr.cap == 2)

        // third add overflows -- doubles to 4 and succeeds, keeping prior items
        _, err = dense_arr__add_growing(&arr, 3, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, arr.cap == 4)
        testing.expect(t, dense_arr__len(&arr) == 3)
        testing.expect(t, arr.items[0] == 1)
        testing.expect(t, arr.items[1] == 2)
        testing.expect(t, arr.items[2] == 3)

        // fill to the new cap, then overflow again -- doubles 4 -> 8
        _, err = dense_arr__add_growing(&arr, 4, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, arr.cap == 4)
        _, err = dense_arr__add_growing(&arr, 5, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, arr.cap == 8)
        testing.expect(t, dense_arr__len(&arr) == 5)
        testing.expect(t, arr.items[4] == 5)
    }

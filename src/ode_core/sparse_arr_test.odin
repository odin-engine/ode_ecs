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
    sparse_arr__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        ua_1: Sparse_Arr(int)
        a : int = 66
        b : int = 99
        c : int = 88

        alloc_err: runtime.Allocator_Error
        err: Core_Error
        ix: int

        defer sparse_arr__terminate(&ua_1, allocator)
        alloc_err = sparse_arr__init(&ua_1, 2, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)

        testing.expect(t, ua_1.has_nil_item == false)
        testing.expect(t, sparse_arr__len(&ua_1) == 0) 
        testing.expect(t, ua_1.cap == 2)

        ix, err = sparse_arr__add(&ua_1, &a)
        testing.expect(t, ix == 0)
        testing.expect(t, err == Core_Error.None)

        ix, err = sparse_arr__add(&ua_1, &b)
        testing.expect(t, ix == 1)
        testing.expect(t, err == Core_Error.None)

        ix, err = sparse_arr__add(&ua_1, &c)
        testing.expect(t, ix == DELETED_INDEX)
        testing.expect(t, err == Core_Error.Container_Is_Full)
        testing.expect(t, ua_1.has_nil_item == false)
        testing.expect(t, sparse_arr__len(&ua_1) == 2)

        // sparse_arr__remove_by_index(&ua_1, 999)
        //testing.expect(t, err == Core_Error.Out_Of_Bounds)

        sparse_arr__remove_by_index(&ua_1, 0)

        testing.expect(t, ua_1.has_nil_item == true)
        testing.expect(t, sparse_arr__len(&ua_1) == 2)
        testing.expect(t, ua_1.items[0] == nil)

        err = sparse_arr__remove_by_value(&ua_1, &b)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, ua_1.has_nil_item == true)
        testing.expect(t, sparse_arr__len(&ua_1) == 1)

        #no_bounds_check {
            testing.expect(t, ua_1.items[1] == nil)
            testing.expect(t, ua_1.items[0] == nil)
        }

        err = sparse_arr__remove_by_value(&ua_1, &c)
        testing.expect(t, err == Core_Error.Not_Found)
        testing.expect(t, ua_1.has_nil_item == true)
        testing.expect(t, sparse_arr__len(&ua_1) == 1)

        #no_bounds_check {
            testing.expect(t, ua_1.items[1] == nil)
            testing.expect(t, ua_1.items[0] == nil)
        }

        ix, err = sparse_arr__add(&ua_1, &a)
        testing.expect(t, ix == 0)
        testing.expect(t, err == Core_Error.None)

        ix, err = sparse_arr__add(&ua_1, &b)
        testing.expect(t, ix == 1)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, sparse_arr__len(&ua_1) == 2)
        testing.expect(t, ua_1.has_nil_item == false)

        // removing tail item, so it should just decrease ua_1.count
        sparse_arr__remove_by_index(&ua_1, 1)
        testing.expect(t, sparse_arr__len(&ua_1) == 1)
        testing.expect(t, ua_1.has_nil_item == false)

        // clear zeroes the memory AND resets len/has_nil_item, and the array stays usable
        ix, err = sparse_arr__add(&ua_1, &b)
        testing.expect(t, err == Core_Error.None)
        sparse_arr__remove_by_index(&ua_1, 0) // leave a nil hole so has_nil_item is set

        sparse_arr__clear(&ua_1)
        testing.expect(t, sparse_arr__len(&ua_1) == 0)
        testing.expect(t, ua_1.has_nil_item == false)

        ix, err = sparse_arr__add(&ua_1, &c)
        testing.expect(t, ix == 0)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, sparse_arr__len(&ua_1) == 1)
        testing.expect(t, ua_1.items[0] == &c)

        testing.expect(t, sparse_arr__memory_usage(&ua_1) > 0)
    }

    @(test)
    sparse_arr__is_valid__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        zero_value: Sparse_Arr(int)
        testing.expect(t, sparse_arr__is_valid(&zero_value) == false)
        nil_sa: ^Sparse_Arr(int)
        testing.expect(t, sparse_arr__is_valid(nil_sa) == false)

        sa: Sparse_Arr(int)
        alloc_err := sparse_arr__init(&sa, 2, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)
        testing.expect(t, sparse_arr__is_valid(&sa))

        alloc_err = sparse_arr__terminate(&sa, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)
        testing.expect(t, sparse_arr__is_valid(&sa) == false)
    }

    @(test)
    sparse_arr__is_valid_or_empty__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        // never allocated -- legitimately empty, should read as valid
        zero_value: Sparse_Arr(int)
        testing.expect(t, sparse_arr__is_valid_or_empty(&zero_value))

        nil_sa: ^Sparse_Arr(int)
        testing.expect(t, sparse_arr__is_valid_or_empty(nil_sa) == false)

        sa: Sparse_Arr(int)
        alloc_err := sparse_arr__init(&sa, 2, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)
        testing.expect(t, sparse_arr__is_valid_or_empty(&sa))

        // terminated -- items collapses back to nil, should read as valid (empty) again
        alloc_err = sparse_arr__terminate(&sa, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)
        testing.expect(t, sparse_arr__is_valid_or_empty(&sa))
    }

    @(test)
    sparse_arr__multiple_nil_holes__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        a, b, c, d, e, f: int = 1, 2, 3, 4, 5, 6

        sa: Sparse_Arr(int)
        defer sparse_arr__terminate(&sa, allocator)
        alloc_err := sparse_arr__init(&sa, 4, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)

        // Fill to capacity so removing index 0 or 2 leaves a real hole instead of just shrinking len.
        _, err := sparse_arr__add(&sa, &a)
        testing.expect(t, err == Core_Error.None)
        _, err = sparse_arr__add(&sa, &b)
        testing.expect(t, err == Core_Error.None)
        _, err = sparse_arr__add(&sa, &c)
        testing.expect(t, err == Core_Error.None)
        _, err = sparse_arr__add(&sa, &d)
        testing.expect(t, err == Core_Error.None)

        // Two non-adjacent holes: index 0 and index 2 (index 3 is the tail).
        sparse_arr__remove_by_index(&sa, 0)
        sparse_arr__remove_by_index(&sa, 2)
        testing.expect(t, sa.has_nil_item == true)

        // Adding once must fill the FIRST hole (index 0) and remember that a second hole (index 2) is still there.
        ix, aerr := sparse_arr__add(&sa, &e)
        testing.expect(t, aerr == Core_Error.None)
        testing.expect(t, ix == 0)
        testing.expect(t, sa.items[0] == &e)
        testing.expect(t, sa.items[2] == nil)
        testing.expect(t, sa.has_nil_item == true)

        // And the remaining hole is still usable.
        ix2, aerr2 := sparse_arr__add(&sa, &f)
        testing.expect(t, aerr2 == Core_Error.None)
        testing.expect(t, ix2 == 2)
        testing.expect(t, sa.has_nil_item == false)
    }

    @(test)
    sparse_arr__resize__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        a, b: int = 1, 2

        // resize-up from a zero-value array behaves like init
        sa: Sparse_Arr(int)
        defer sparse_arr__terminate(&sa, allocator)
        err := sparse_arr__resize(&sa, 2, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, sa.cap == 2)
        testing.expect(t, sparse_arr__len(&sa) == 0)

        // resize-up preserves items AND holes in place
        _, aerr := sparse_arr__add(&sa, &a)
        testing.expect(t, aerr == Core_Error.None)
        _, aerr = sparse_arr__add(&sa, &b)
        testing.expect(t, aerr == Core_Error.None)
        sparse_arr__remove_by_index(&sa, 0) // leaves a hole at index 0, b stays at index 1
        testing.expect(t, sa.has_nil_item == true)

        err = sparse_arr__resize(&sa, 4, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, sa.cap == 4)
        testing.expect(t, sparse_arr__len(&sa) == 2)
        testing.expect(t, sa.items[0] == nil)
        testing.expect(t, sa.items[1] == &b)
        testing.expect(t, sa.has_nil_item == true)

        // resize-down to exactly the live span is allowed
        err = sparse_arr__resize(&sa, 2, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, sa.cap == 2)
        testing.expect(t, sparse_arr__len(&sa) == 2)
        testing.expect(t, sa.items[0] == nil)
        testing.expect(t, sa.items[1] == &b)
        testing.expect(t, sa.has_nil_item == true)

        // resize-down below the live span is rejected, array untouched
        err = sparse_arr__resize(&sa, 1, allocator)
        testing.expect(t, err == Core_Error.Cannot_Shrink_Below_Length)
        testing.expect(t, sa.cap == 2)
        testing.expect(t, sparse_arr__len(&sa) == 2)

        // resize to the same cap is a no-op
        err = sparse_arr__resize(&sa, 2, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, sa.cap == 2)
    }

    @(test)
    sparse_arr__add_growing__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        a, b, c, d, e, f: int = 1, 2, 3, 4, 5, 6

        sa: Sparse_Arr(int)
        defer sparse_arr__terminate(&sa, allocator)
        alloc_err := sparse_arr__init(&sa, 2, allocator)
        testing.expect(t, alloc_err == runtime.Allocator_Error.None)

        // fills the initial cap without growing
        _, err := sparse_arr__add_growing(&sa, &a, allocator)
        testing.expect(t, err == nil)
        _, err = sparse_arr__add_growing(&sa, &b, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, sa.cap == 2)

        // a hole must be filled first, without growing, even though the live span looks full
        sparse_arr__remove_by_index(&sa, 0)
        testing.expect(t, sa.has_nil_item == true)
        ix, herr := sparse_arr__add_growing(&sa, &c, allocator)
        testing.expect(t, herr == nil)
        testing.expect(t, ix == 0)
        testing.expect(t, sa.cap == 2)

        // now genuinely full -- overflow doubles cap 2 -> 4 and succeeds
        _, err = sparse_arr__add_growing(&sa, &d, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, sa.cap == 4)
        testing.expect(t, sparse_arr__len(&sa) == 3)

        // fill the remaining free slot (no growth needed yet)
        _, err = sparse_arr__add_growing(&sa, &e, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, sa.cap == 4)
        testing.expect(t, sparse_arr__len(&sa) == 4)

        // now full again -- overflow doubles cap 4 -> 8
        _, err = sparse_arr__add_growing(&sa, &f, allocator)
        testing.expect(t, err == nil)
        testing.expect(t, sa.cap == 8)
        testing.expect(t, sparse_arr__len(&sa) == 5)
        testing.expect(t, sa.items[4] == &f)
    }

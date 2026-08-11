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

///////////////////////////////////////////////////////////////////////////////
// Dense_Arr -- tail swap unordered dense preallocated array. 
// 
// Use it when order doesn't matter but iteration speed does. 
// When item is removed it is replaced with tail item and count decresed by one.
// Has no empty (nil) items.
// Why not use [dynamic] array? Because we want full control over 
// memory allocations and what operations are allowed.

    Dense_Arr :: struct($T: typeid) {
        cap: int, 
        items: []T,
    }

    dense_arr__is_valid :: proc(self: ^Dense_Arr($T)) -> bool {
        if self == nil do return false
        if self.cap <= 0 do return false
        if self.items == nil do return false

        return true
    }

    // True if valid OR legitimately not-yet-allocated (a lazy field with no first `add` yet).
    dense_arr__is_valid_or_empty :: proc(self: ^Dense_Arr($T)) -> bool {
        if self == nil do return false
        if self.cap == 0 do return self.items == nil
        return self.items != nil
    }

    dense_arr__init :: proc(self: ^Dense_Arr($T), cap: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        err: runtime.Allocator_Error = runtime.Allocator_Error.None
        self.items, err = make([]T, cap, allocator)
        ((^runtime.Raw_Slice)(&self.items)).len = 0
        self.cap = cap
        return err
    }

    dense_arr__terminate :: proc(self: ^Dense_Arr($T), allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.cap = 0
        err := delete(self.items, allocator)
        self.items = nil
        return err
    }

    // Resizes the backing allocation to new_cap, preserving existing items. Rejects
    // shrinking below the current live length instead of dropping items.
    dense_arr__resize :: proc(self: ^Dense_Arr($T), new_cap: int, allocator: runtime.Allocator) -> Error {
        live_len := dense_arr__len(self)
        if new_cap < live_len do return Core_Error.Cannot_Shrink_Below_Length
        if new_cap == self.cap do return nil

        new_items := make([]T, new_cap, allocator) or_return
        if live_len > 0 do copy(new_items, self.items[:live_len])
        ((^runtime.Raw_Slice)(&new_items)).len = live_len

        old_items := self.items
        self.items = new_items
        self.cap = new_cap

        if old_items != nil do delete(old_items, allocator) or_return

        return nil
    }

    // `dense_arr__remove_by_index` removes the element at the specified `index`.
    // 
    // Note: Similar to unordered_remove() for dynamic arrays but this is not a dynamic array.
    dense_arr__remove_by_index :: proc(self: ^Dense_Arr($T), #any_int index: int, loc := #caller_location) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.items)
        runtime.bounds_check_error_loc(loc, index, raw.len)

        n := raw.len - 1
        if index != n {
            // COPY
            self.items[index] = self.items[n]
        }
        raw.len -= 1
    }

    dense_arr__remove_by_value :: proc(self: ^Dense_Arr($T), value: T, loc := #caller_location) -> Core_Error {
        raw := (^runtime.Raw_Slice)(&self.items)
        for index:= 0; index < raw.len; index += 1 {
            if self.items[index] == value {
                dense_arr__remove_by_index(self, index, loc)
                return Core_Error.None
            }
        }

        return Core_Error.Not_Found
    }

    // Core_Error, not the wider Error — see dense_arr__remove_by_value's doc
    // comment (same reasoning, this proc never allocates either).
    dense_arr__add :: proc(self: ^Dense_Arr($T), value: T) -> (int, Core_Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.items)
        if raw.len >= self.cap do return DELETED_INDEX, Core_Error.Container_Is_Full

        index := raw.len
        self.items[index] = value
        raw.len += 1

        return index, Core_Error.None
    }

    // Adds value, doubling the backing allocation first if full instead of
    // returning Container_Is_Full. Requires self already allocated (cap > 0).
    dense_arr__add_growing :: proc(self: ^Dense_Arr($T), value: T, allocator: runtime.Allocator) -> (ix: int, err: Error) {
        when VALIDATIONS do assert(self.cap > 0)

        ix, err = dense_arr__add(self, value)
        if err == Core_Error.Container_Is_Full {
            dense_arr__resize(self, self.cap * 2, allocator) or_return
            ix, err = dense_arr__add(self, value)
        }
        return
    }

    dense_arr__len :: #force_inline proc(self: ^Dense_Arr($T)) -> int {
        return ((^runtime.Raw_Slice)(&self.items)).len
    }

    dense_arr__memory_usage :: proc (self: ^Dense_Arr($T)) -> int {
        total := size_of(self^)

        if self.items != nil {
            total += size_of(self.items[0]) * self.cap
        }

        return total
    }

    dense_arr__zero :: proc (self: ^Dense_Arr($T)) {
        assert(self.items != nil)

        mem.zero(raw_data(self.items), size_of(T) * self.cap)
        ((^runtime.Raw_Slice)(&self.items)).len = 0
    }

    dense_arr__clear :: dense_arr__zero

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    dense_arr__test :: proc(t: ^testing.T) {
        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
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

    dense_arr__init :: proc(self: ^Dense_Arr($T), cap: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        err: runtime.Allocator_Error = runtime.Allocator_Error.None
        self.items, err = make([]T, cap, allocator)
        ((^runtime.Raw_Slice)(&self.items)).len = 0
        self.cap = cap
        return err
    }

    dense_arr__terminate :: proc(self: ^Dense_Arr($T), allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.cap = 0
        ((^runtime.Raw_Slice)(&self.items)).len = 0
        return delete(self.items, allocator)
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

    dense_arr__remove_by_value :: proc(self: ^Dense_Arr($T), value: T, loc := #caller_location) -> Error {
        raw := (^runtime.Raw_Slice)(&self.items)
        for index:= 0; index < raw.len; index += 1 {
            if self.items[index] == value {
                dense_arr__remove_by_index(self, index, loc)
                return nil
            }
        }

        return Core_Error.Not_Found
    }

    dense_arr__add :: proc(self: ^Dense_Arr($T), value: T) -> (int, Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.items)
        if raw.len >= self.cap do return DELETED_INDEX, Core_Error.Container_Is_Full

        index := raw.len
        self.items[index] = value
        raw.len += 1

        return index, nil
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
    }
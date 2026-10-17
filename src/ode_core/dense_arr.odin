/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_core

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"

///////////////////////////////////////////////////////////////////////////////
// Dense_Arr -- tail-swap unordered dense preallocated array.
//
// Use when order doesn't matter but iteration speed does; removed items are replaced by the tail item.

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

    // Resizes the backing allocation to new_cap, preserving existing items, rejecting shrinking below the current live length.
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

    // Similar to unordered_remove() for dynamic arrays, but this isn't one.
    // 
    dense_arr__remove_by_index :: proc(self: ^Dense_Arr($T), #any_int index: int, loc := #caller_location) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.items)
        runtime.bounds_check_error_loc(loc, index, raw.len)

        n := raw.len - 1
        if index != n {
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

    // Core_Error, not the wider Error — this proc never allocates.
    dense_arr__add :: proc(self: ^Dense_Arr($T), value: T) -> (int, Core_Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.items)
        if raw.len >= self.cap do return DELETED_INDEX, Core_Error.Container_Is_Full

        index := raw.len
        self.items[index] = value
        raw.len += 1

        return index, Core_Error.None
    }

    // Adds value, doubling the backing allocation first if full instead of returning Container_Is_Full.
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

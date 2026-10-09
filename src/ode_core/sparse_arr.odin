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
// Sparse_Arr -- unmovable ordered sparse array of pointers; items never move (order matters), so removal leaves nil holes that later adds scan to refill.

    Sparse_Arr :: struct($T: typeid) {
        items: []^T,   
        cap: int,             
        has_nil_item: bool
    }

    sparse_arr__is_valid :: proc(self: ^Sparse_Arr($T)) -> bool {
        if self == nil do return false
        if self.items == nil do return false
        if self.cap <= 0 do return false

        return true
    }

    // True if valid OR legitimately not-yet-allocated (a lazy field with no first `add` yet).
    sparse_arr__is_valid_or_empty :: proc(self: ^Sparse_Arr($T)) -> bool {
        if self == nil do return false
        if self.cap == 0 do return self.items == nil
        return self.items != nil
    }

    sparse_arr__init :: proc(self: ^Sparse_Arr($T), cap: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        err: runtime.Allocator_Error = runtime.Allocator_Error.None
        self.items, err = make([]^T, cap, allocator)
        ((^runtime.Raw_Slice)(&self.items)).len = 0
        self.cap = cap
        return err
    }

    sparse_arr__terminate :: proc(self: ^Sparse_Arr($T), allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.cap = 0
        self.has_nil_item = false
        err := delete(self.items, allocator)
        self.items = nil
        return err
    }
 
    sparse_arr__remove_by_index :: proc(self: ^Sparse_Arr($T), #any_int index: int, loc := #caller_location) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.items)
        runtime.bounds_check_error_loc(loc, index, self.cap)

        self.items[index] = nil

        // removing the tail item just shrinks len, no hole left behind
        if index == (raw.len - 1) {
            raw.len -= 1
        } else {
            self.has_nil_item = true
        }

    }

    sparse_arr__remove_by_value:: proc(self: ^Sparse_Arr($T), value: ^T, loc := #caller_location) -> Core_Error {
        raw := (^runtime.Raw_Slice)(&self.items)
        for index:= 0; index < raw.len; index += 1 {
            if self.items[index] == value {
                sparse_arr__remove_by_index(self, index, loc)
                return Core_Error.None
            }
        }

        return Core_Error.Not_Found
    }

    sparse_arr__add :: proc(self: ^Sparse_Arr($T), value: ^T) -> (int, Core_Error) #no_bounds_check {
        id : int
        raw := (^runtime.Raw_Slice)(&self.items)

        if self.has_nil_item {
            t: ^T
            found := false 
            self.has_nil_item = false 

            for i := 0; i < raw.len; i += 1 {
                t = self.items[i]
                if t == nil && found == false {
                    id = i
                    self.items[i] = value 
                    found = true
                } else if t == nil && found {
                    self.has_nil_item = true
                    break
                }
            }

            assert(found) // expected to find a slot with nil value

        } else {    
            id = raw.len

            if id >= self.cap do return DELETED_INDEX, Core_Error.Container_Is_Full
    
            self.items[id] = value
            raw.len += 1
        }

        return id, nil
    }

    // Adds value, doubling the backing allocation first if full instead of returning Container_Is_Full.
    sparse_arr__add_growing :: proc(self: ^Sparse_Arr($T), value: ^T, allocator: runtime.Allocator) -> (ix: int, err: Error) {
        when VALIDATIONS do assert(self.cap > 0)

        ix, err = sparse_arr__add(self, value)
        if err == Core_Error.Container_Is_Full {
            sparse_arr__resize(self, self.cap * 2, allocator) or_return
            ix, err = sparse_arr__add(self, value)
        }
        return
    }

    // Preserves items (and nil holes) in place; rejects shrinking below the live span since Sparse_Arr is unmovable and never compacts.
    sparse_arr__resize :: proc(self: ^Sparse_Arr($T), new_cap: int, allocator: runtime.Allocator) -> Error {
        live_len := sparse_arr__len(self)
        if new_cap < live_len do return Core_Error.Cannot_Shrink_Below_Length
        if new_cap == self.cap do return nil

        new_items := make([]^T, new_cap, allocator) or_return
        if live_len > 0 do copy(new_items, self.items[:live_len])
        ((^runtime.Raw_Slice)(&new_items)).len = live_len

        old_items := self.items
        self.items = new_items
        self.cap = new_cap

        if old_items != nil do delete(old_items, allocator) or_return

        return nil
    }

    sparse_arr__len :: #force_inline proc(self: ^Sparse_Arr($T)) -> int {
        return ((^runtime.Raw_Slice)(&self.items)).len
    }

    sparse_arr__memory_usage :: proc (self: ^Sparse_Arr($T)) -> int {
        total := size_of(self^)

        if self.items != nil {
            total += size_of(self.items[0]) * self.cap
        }

        return total
    }

    sparse_arr__zero :: proc (self: ^Sparse_Arr($T)) {
        assert(self.items != nil)

        self.has_nil_item = false
        mem.zero(raw_data(self.items), size_of(^T) * self.cap)
        ((^runtime.Raw_Slice)(&self.items)).len = 0
    }

    sparse_arr__clear :: sparse_arr__zero


///////////////////////////////////////////////////////////////////////////////
// Tests
// 




    // sparse_arr__add's "more than one nil hole" branch: only the first hole fills, and has_nil_item stays true.


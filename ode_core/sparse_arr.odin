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
// Sparce_Arr -- unmovable ordered sparse array of pointers 
// To save memory uses iteration over array to find free slots to refill.
// Good when order/position in array is important because we do not move items (hence unmovable).
// Good for relatively small arrays or when we know that removing and adding items happens not often.
// Can contain slots with nil value (hence sparse).

    Sparce_Arr :: struct($T: typeid) {
        items: []^T,   
        cap: int,             
        has_nil_item: bool
    }

    sparce_arr__is_valid :: proc(self: ^Sparce_Arr($T)) -> bool {
        if self == nil do return false
        if self.items == nil do return false
        if self.cap <= 0 do return false 
        
        return true
    }

    sparse_arr__init :: proc(self: ^Sparce_Arr($T), cap: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        err: runtime.Allocator_Error = runtime.Allocator_Error.None
        self.items, err = make([]^T, cap, allocator)
        ((^runtime.Raw_Slice)(&self.items)).len = 0
        self.cap = cap
        return err
    }

    sparse_arr__terminate :: proc(self: ^Sparce_Arr($T), allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.cap = 0
        self.has_nil_item = false
        return delete(self.items, allocator)
    }
 
    sparse_arr__remove_by_index :: proc(self: ^Sparce_Arr($T), #any_int index: int, loc := #caller_location) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.items)
        runtime.bounds_check_error_loc(loc, index, self.cap)

        self.items[index] = nil
        
        // If we removed tail item, we can decrease count by 1 so we dont iterate over tail item
        if index == (raw.len - 1) {
            raw.len -= 1
        } else {
            self.has_nil_item = true
        }

    }

    sparse_arr__remove_by_value:: proc(self: ^Sparce_Arr($T), value: ^T, loc := #caller_location) -> Core_Error {
        raw := (^runtime.Raw_Slice)(&self.items)
        for index:= 0; index < raw.len; index += 1 {
            if self.items[index] == value {
                sparse_arr__remove_by_index(self, index, loc)
                return Core_Error.None
            }
        }

        return Core_Error.Not_Found
    }

    sparse_arr__add :: proc(self: ^Sparce_Arr($T), value: ^T) -> (int, Core_Error) #no_bounds_check {
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
                    // has more nil values
                    self.has_nil_item = true
                    break // no need to iterate further
                }
            }

            // Sanity check
            assert(found) // Something is wrong, expected to find slot with nil value

        } else {    
            id = raw.len

            if id >= self.cap do return DELETED_INDEX, Core_Error.Container_Is_Full
    
            self.items[id] = value
            raw.len += 1
        }

        return id, nil
    }

    sparse_arr__len :: #force_inline proc(self: ^Sparce_Arr($T)) -> int {
        return ((^runtime.Raw_Slice)(&self.items)).len
    }

    sparse_arr__memory_usage :: proc (self: ^Sparce_Arr($T)) -> int {
        total := size_of(self^)

        if self.items != nil {
            total += size_of(self.items[0]) * self.cap
        }

        return total
    }

    sparse_arr__zero :: proc (self: ^Sparce_Arr($T)) {
        assert(self.items != nil)

        self.has_nil_item = false
        mem.zero(raw_data(self.items), size_of(^T) * self.cap)
    }

    sparse_arr__clear :: sparse_arr__zero


///////////////////////////////////////////////////////////////////////////////
// Tests
// 
    
    @(test)
    sparse_arr__test :: proc(t: ^testing.T) {
        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        ua_1: Sparce_Arr(int)
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

    }
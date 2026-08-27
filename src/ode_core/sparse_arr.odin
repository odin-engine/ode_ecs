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

    @(test)
    sparse_arr__test :: proc(t: ^testing.T) {
        // Log into console when panic happens
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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

    // sparse_arr__add's "more than one nil hole" branch: only the first hole fills, and has_nil_item stays true.
    @(test)
    sparse_arr__multiple_nil_holes__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

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
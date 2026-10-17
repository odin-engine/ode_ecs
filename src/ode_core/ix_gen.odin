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
// ix_gen -- index + generation; reusing an id bumps gen, so a stale saved id with the same ix reads as different from the new one.

    GEN_MAX :: 4_294_967_295

    ix_gen :: bit_field i64 {
        ix: int | 32,       // index
        gen: uint | 32,     // generation
    }

    Ix_Gen_Factory :: struct {
        created_count: int,
        
        cap: int, 
        items: []ix_gen,

        freed: []u32, // ix < cap <= max(u32)
        freed_count: int
    }

    ix_gen_factory__is_valid :: proc(self: ^Ix_Gen_Factory) -> bool {
        if self == nil do return false 
        if self.cap <= 0 do return false 
        if self.items == nil do return false 
        if self.freed == nil do return false 

        return true
    }

    ix_gen_factory__init :: proc(self: ^Ix_Gen_Factory, cap: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.cap = cap

        self.items = make([]ix_gen, cap, allocator) or_return
        self.freed = make([]u32, cap, allocator) or_return
        ix_gen_factory__clear(self, bump_gen = false) // fresh items: gens start at 0

        return runtime.Allocator_Error.None
    }
    
    ix_gen_factory__terminate :: proc(self: ^Ix_Gen_Factory, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.cap = 0
        self.created_count = 0
        self.freed_count = 0
        delete(self.freed, allocator) or_return
        self.freed = nil
        delete(self.items, allocator) or_return
        // nil (not just freed) so a terminated factory reads as empty, not dangling
        self.items = nil
        return runtime.Allocator_Error.None
    }

    @(require_results)
    ix_gen_factory__new_id :: proc(self: ^Ix_Gen_Factory) -> (ix_gen, Core_Error) {
        id: ix_gen 
        p: ^ix_gen
        ix: int

        if ix_gen_factory__len(self)  >= self.cap {
            id.ix = DELETED_INDEX
            id.gen = 0
            return id, Core_Error.Container_Is_Full
        }

        if self.freed_count > 0 {
            // reuse freed id
            self.freed_count -= 1
            ix = int(self.freed[self.freed_count])
            self.freed[self.freed_count] = max(u32) // debug fill only

            p = &self.items[ix]

            when VALIDATIONS do assert(p.ix == DELETED_INDEX)
            p.ix = ix
            p.gen = p.gen >= GEN_MAX ? 0 : p.gen + 1

            id = p^
        } else {
            p = &self.items[self.created_count]
            when VALIDATIONS do assert(p.ix == DELETED_INDEX)
            p.ix = self.created_count

            id = p^
            
            self.created_count += 1
        }

        return id, Core_Error.None
    }

    ix_gen_factory__free_id :: proc(self: ^Ix_Gen_Factory, id: ix_gen) -> Core_Error {
        if self.freed_count >= self.cap do return Core_Error.Container_Is_Full
        if id.ix < 0 || id.ix >= self.cap do return Core_Error.Out_Of_Bounds
        if self.items[id.ix].ix == DELETED_INDEX do return Core_Error.Already_Freed
        if self.items[id.ix] != id do return Core_Error.Not_Found
        
        self.items[id.ix].ix = DELETED_INDEX
        self.freed[self.freed_count] = u32(id.ix)
        self.freed_count += 1

        return Core_Error.None
    }

    ix_gen_factory__get_id :: #force_inline proc "contextless" (self: ^Ix_Gen_Factory, #any_int index: int, loc := #caller_location) -> ix_gen {
        runtime.bounds_check_error_loc(loc, index, self.cap)
    
        return self.items[index]
    }

    // #no_bounds_check: id.ix is range-checked right above
    ix_gen_factory__is_freed :: #force_inline proc "contextless" (self: ^Ix_Gen_Factory, id: ix_gen) -> bool #no_bounds_check {
        if id.ix < 0 || id.ix >= self.cap do return true // out of range -> not live
        return self.items[id.ix].ix == DELETED_INDEX
    }

    // #no_bounds_check: id.ix is range-checked right above
    ix_gen_factory__is_expired :: #force_inline proc "contextless" (self: ^Ix_Gen_Factory, id: ix_gen) -> bool #no_bounds_check {
        if id.ix < 0 || id.ix >= self.cap do return true // out of range -> expired
        // Comparing the whole id (ix + gen), not just gen, also rejects never-created/freed slots.
        return self.items[id.ix] != id
    }

    @(require_results)
    ix_gen_factory__len :: #force_inline proc "contextless" (self: ^Ix_Gen_Factory) -> int {
        return self.created_count - self.freed_count
    }

    // In bytes.
    ix_gen_factory__memory_usage :: proc(self: ^Ix_Gen_Factory) -> int {
        total := size_of(self^)
        if self.items != nil {
            total += size_of(self.items[0]) * self.cap
        }

        if self.freed != nil {
            total += size_of(self.freed[0]) * self.cap
        }
        
        return total
    }

    // bump_gen advances every slot's generation so pre-clear ids stop matching post-clear ones; pass false only when items are about to be overwritten wholesale.
    ix_gen_factory__clear :: proc(self: ^Ix_Gen_Factory, bump_gen := true) {
        assert(self != nil)
        assert(self.items != nil)
        assert(self.freed != nil)

        self.created_count = 0
        self.freed_count = 0
        if bump_gen {
            for &item in self.items {
                item.ix = DELETED_INDEX
                item.gen = item.gen >= GEN_MAX ? 0 : item.gen + 1
            }
        } else {
            for &item in self.items do item.ix = DELETED_INDEX
        }
        for i:=0; i < self.cap; i+=1 do self.freed[i] = max(u32) // debug fill only

    }

    // Keeps every id and generation; new slots start free with gen 0.
    ix_gen_factory__grow :: proc(self: ^Ix_Gen_Factory, cap: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        if cap <= self.cap do return .None

        items := make([]ix_gen, cap, allocator) or_return
        freed, err := make([]u32, cap, allocator)
        if err != .None {
            delete(items, allocator)
            return err
        }

        copy(items, self.items)
        for i in self.cap..<cap do items[i].ix = DELETED_INDEX
        copy(freed, self.freed[:self.freed_count])
        for i in self.freed_count..<cap do freed[i] = max(u32) // debug fill only

        delete(self.items, allocator)
        delete(self.freed, allocator)
        self.items = items
        self.freed = freed
        self.cap = cap
        return .None
    }

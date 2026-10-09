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
    ix_gen_factory__test :: proc(t: ^testing.T) {


        allocator := context.allocator
        context.allocator = mem.panic_allocator() // to make sure no allocations happen outside provided allocator

        id_1: ix_gen 
        id_2: ix_gen
        id_3: ix_gen

        testing.expect(t, id_1 == id_2)

        id_1.ix = DELETED_INDEX
        id_2.ix = DELETED_INDEX

        testing.expect(t, id_1 == id_2)
        testing.expect(t, id_1.ix == DELETED_INDEX)
        testing.expect(t, id_1.gen == 0)

        id_1.gen = 255
        testing.expect(t, id_1.ix == DELETED_INDEX)
        testing.expect(t, id_1 != id_2)

        factory: Ix_Gen_Factory

        defer ix_gen_factory__terminate(&factory, allocator)
        ix_gen_factory__init(&factory, 2, allocator)

        testing.expect(t, factory.cap == 2)
        testing.expect(t, factory.freed_count == 0)
        testing.expect(t, factory.created_count == 0)

        err: Core_Error

        id_1, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, id_1.ix == 0)
        testing.expect(t, id_1.gen == 0)

        id_2, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, id_2.ix == 1)
        testing.expect(t, id_2.gen == 0)

        id_3, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.Container_Is_Full)
        testing.expect(t, id_3.ix == DELETED_INDEX)
        testing.expect(t, id_3.gen == 0)

        testing.expect(t, id_1.ix == 0)
        err = ix_gen_factory__free_id(&factory, id_1)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, factory.created_count == 2)
        testing.expect(t, factory.freed_count == 1)

        id_1, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, id_1.ix == 0)
        testing.expect(t, id_1.gen == 1)
        
        err = ix_gen_factory__free_id(&factory, id_1)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, factory.created_count == 2)
        testing.expect(t, factory.freed_count == 1)

        id_1, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, id_1.ix == 0)
        testing.expect(t, id_1.gen == 2)

        err = ix_gen_factory__free_id(&factory, id_1)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, factory.created_count == 2)
        testing.expect(t, factory.freed_count == 1)
        testing.expect(t, ix_gen_factory__is_freed(&factory, id_1))
        testing.expect(t, ix_gen_factory__is_freed(&factory, id_2) == false)

        err = ix_gen_factory__free_id(&factory, id_2)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, factory.created_count == 2)
        testing.expect(t, factory.freed_count == 2)
        testing.expect(t, ix_gen_factory__is_freed(&factory, id_1))
        testing.expect(t, ix_gen_factory__is_freed(&factory, id_2))

        id_4, id_5: ix_gen

        testing.expect(t, id_1 != factory.items[0])
        testing.expect(t, factory.items[0].ix == DELETED_INDEX)
        testing.expect(t, factory.items[0].gen == 2)
        testing.expect(t, id_2 != factory.items[1])
        testing.expect(t, factory.items[1].ix == DELETED_INDEX)
        testing.expect(t, factory.items[1].gen == 0)

        id_3, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, id_3.ix == 1)
        testing.expect(t, id_3.gen == 1)
        testing.expect(t, factory.created_count == 2)
        testing.expect(t, factory.freed_count == 1)
        testing.expect(t, ix_gen_factory__is_freed(&factory, id_3) == false)
        testing.expect(t, ix_gen_factory__is_freed(&factory, id_2) == false)

        id_4, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, id_4.ix == 0)
        testing.expect(t, id_4.gen == 3)
        testing.expect(t, factory.created_count == 2)
        testing.expect(t, factory.freed_count == 0)

        testing.expect(t, id_4 != id_1)
        testing.expect(t, id_3 != id_2)

        id_5, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.Container_Is_Full)
        testing.expect(t, factory.created_count == 2)
        testing.expect(t, factory.freed_count == 0)

        // clear with bump_gen: ids issued before the clear must expire,
        // including against ids created right after it
        ix_gen_factory__clear(&factory, bump_gen = true)
        testing.expect(t, ix_gen_factory__is_expired(&factory, id_4))

        id_5, err = ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, id_5.ix == 0)
        testing.expect(t, id_5.gen == 4) // id_4 had gen 3
        testing.expect(t, id_5 != id_4)
        testing.expect(t, ix_gen_factory__is_expired(&factory, id_4))

        // out-of-range ids are "not live" for both queries, never an OOB read
        bad_id: ix_gen
        bad_id.ix = DELETED_INDEX // -1
        testing.expect(t, ix_gen_factory__is_freed(&factory, bad_id))
        testing.expect(t, ix_gen_factory__is_expired(&factory, bad_id))
        bad_id.ix = factory.cap // one past the end
        testing.expect(t, ix_gen_factory__is_freed(&factory, bad_id))
        testing.expect(t, ix_gen_factory__is_expired(&factory, bad_id))
    }

    @(test)
    ix_gen_factory__free_id_errors__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        factory: Ix_Gen_Factory
        defer ix_gen_factory__terminate(&factory, allocator)
        ix_gen_factory__init(&factory, 2, allocator)

        id, err := ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, id.ix == 0 && id.gen == 0)

        // Out_Of_Bounds: ix outside [0, cap)
        oob_id := id
        oob_id.ix = factory.cap
        testing.expect(t, ix_gen_factory__free_id(&factory, oob_id) == Core_Error.Out_Of_Bounds)

        // Already_Freed: freeing the same id twice in a row
        testing.expect(t, ix_gen_factory__free_id(&factory, id) == Core_Error.None)
        testing.expect(t, ix_gen_factory__free_id(&factory, id) == Core_Error.Already_Freed)

        // Not_Found: a stale (superseded) generation at a live index
        id_2, err_2 := ix_gen_factory__new_id(&factory) // reuses ix 0, bumps gen to 1
        testing.expect(t, err_2 == Core_Error.None)
        testing.expect(t, id_2.ix == 0 && id_2.gen == 1)

        stale_id := id_2
        stale_id.gen = 0 // the original, already-superseded generation
        testing.expect(t, ix_gen_factory__free_id(&factory, stale_id) == Core_Error.Not_Found)

        // The live id at that index is unaffected by the rejected frees above.
        testing.expect(t, ix_gen_factory__is_expired(&factory, id_2) == false)
    }

    @(test)
    ix_gen_factory__gen_wraparound__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        factory: Ix_Gen_Factory
        defer ix_gen_factory__terminate(&factory, allocator)
        ix_gen_factory__init(&factory, 1, allocator)

        first_id, err := ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)
        testing.expect(t, first_id.ix == 0 && first_id.gen == 0)

        // Fast-forward to one below the wrap instead of cycling GEN_MAX times.
        testing.expect(t, ix_gen_factory__free_id(&factory, first_id) == Core_Error.None)
        factory.items[0].gen = GEN_MAX - 1

        id, err2 := ix_gen_factory__new_id(&factory) // bumps GEN_MAX-1 -> GEN_MAX
        testing.expect(t, err2 == Core_Error.None)
        testing.expect(t, id.gen == GEN_MAX)
        testing.expect(t, ix_gen_factory__is_expired(&factory, first_id))

        // one more cycle wraps GEN_MAX -> 0 and the original id collides back to live
        testing.expect(t, ix_gen_factory__free_id(&factory, id) == Core_Error.None)
        id, err2 = ix_gen_factory__new_id(&factory)
        testing.expect(t, err2 == Core_Error.None)
        testing.expect(t, id.gen == 0)
        testing.expect(t, id == first_id)
        testing.expect(t, ix_gen_factory__is_expired(&factory, first_id) == false)
    }

    @(test)
    ix_gen_factory__clear_default_expires__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        factory: Ix_Gen_Factory
        defer ix_gen_factory__terminate(&factory, allocator)
        ix_gen_factory__init(&factory, 2, allocator)

        old_id, err := ix_gen_factory__new_id(&factory)
        testing.expect(t, err == Core_Error.None)

        ix_gen_factory__clear(&factory) // default bump_gen = true

        testing.expect(t, ix_gen_factory__is_expired(&factory, old_id))

        // the recreated slot hands out a different generation than old_id's
        new_id, err_2 := ix_gen_factory__new_id(&factory)
        testing.expect(t, err_2 == Core_Error.None)
        testing.expect(t, new_id.ix == old_id.ix)
        testing.expect(t, new_id != old_id)
        testing.expect(t, ix_gen_factory__is_expired(&factory, old_id))
    }

    @(test)
    ix_gen_factory__grow__test :: proc(t: ^testing.T) {

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        factory: Ix_Gen_Factory
        defer ix_gen_factory__terminate(&factory, allocator)
        ix_gen_factory__init(&factory, 2, allocator)

        a, _ := ix_gen_factory__new_id(&factory)
        b, _ := ix_gen_factory__new_id(&factory)
        testing.expect(t, ix_gen_factory__free_id(&factory, a) == Core_Error.None)
        a2, _ := ix_gen_factory__new_id(&factory) // a's slot, next generation
        testing.expect(t, ix_gen_factory__free_id(&factory, b) == Core_Error.None)

        testing.expect(t, ix_gen_factory__grow(&factory, 1, allocator) == .None) // smaller: no-op
        testing.expect_value(t, factory.cap, 2)

        testing.expect(t, ix_gen_factory__grow(&factory, 5, allocator) == .None)
        testing.expect_value(t, factory.cap, 5)
        testing.expect(t, !ix_gen_factory__is_expired(&factory, a2))
        testing.expect(t, ix_gen_factory__is_expired(&factory, a))
        testing.expect(t, ix_gen_factory__is_expired(&factory, b))
        testing.expect_value(t, ix_gen_factory__len(&factory), 1)

        // the freed slot comes back first, with a new generation
        b2, _ := ix_gen_factory__new_id(&factory)
        testing.expect_value(t, b2.ix, b.ix)
        testing.expect(t, b2 != b)

        for _ in 0..<3 {
            id, err := ix_gen_factory__new_id(&factory)
            testing.expect(t, err == Core_Error.None)
            testing.expect(t, id.ix >= 2)
        }
        _, full := ix_gen_factory__new_id(&factory)
        testing.expect(t, full == Core_Error.Container_Is_Full)
    }

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
    mem_track__test :: proc(t: ^testing.T) {
        // a check that finds a problem logs an error; keep those out of the test runner's log
        silent :: proc(check: proc(mt: ^Mem_Track) -> bool, mt: ^Mem_Track) -> bool {
            context.logger = log.nil_logger()
            return check(mt)
        }

        mt: Mem_Track
        tracked := mem_track__init(&mt, context.allocator)
        defer mem_track__terminate(&mt)

        // clean at start
        testing.expect(t, mem_track__check_leaks(&mt) == false)
        testing.expect(t, mem_track__check_bad_frees(&mt) == false)

        // an allocation without a free is reported as a leak
        p, aerr := mem.alloc(64, mem.DEFAULT_ALIGNMENT, tracked)
        testing.expect(t, aerr == .None)
        testing.expect(t, p != nil)
        testing.expect(t, silent(mem_track__check_leaks, &mt) == true)

        // freeing it clears the leak
        testing.expect(t, mem.free(p, tracked) == .None)
        testing.expect(t, mem_track__check_leaks(&mt) == false)

        // freeing a pointer this allocator never allocated is a bad free (collected, not panicked)
        x: int
        mem.free(&x, tracked)
        testing.expect(t, silent(mem_track__check_bad_frees, &mt) == true)

        // clear resets the tracked state
        mem_track__clear(&mt)
        testing.expect(t, mem_track__check_bad_frees(&mt) == false)
        testing.expect(t, mem_track__check_leaks(&mt) == false)

        // panic helpers pass through silently when clean
        mem_track__panic_if_bad_frees_or_leaks(&mt)
    }

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
// Mem_Track

    Mem_Track :: struct {
        default: runtime.Allocator,
        tracking: mem.Tracking_Allocator
    }

    mem_track__init ::  proc(self: ^Mem_Track, default_allocator: runtime.Allocator) -> runtime.Allocator {
        self.default = default_allocator
        mem.tracking_allocator_init(&self.tracking, self.default)
        // core:mem defaults to panicking inside the allocator on a bad free,
        // which would bypass check_bad_frees/panic_if_bad_frees entirely —
        // collect into bad_free_array instead so Mem_Track can report locations
        self.tracking.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
        return mem.tracking_allocator(&self.tracking)
    }

    mem_track__terminate :: proc(self: ^Mem_Track) {
        mem_track__clear(self)
    }

    mem_track__clear :: proc(self: ^Mem_Track) {
        mem.tracking_allocator_clear(&self.tracking)
    }

    mem_track__check_leaks :: proc(self: ^Mem_Track) -> bool {
        err := false

        for _, value in self.tracking.allocation_map {
            log.errorf("%v: Leaked %v bytes\n", value.location, value.size)
            err = true
        }

        return err
    }

    mem_track__panic_if_leaks :: proc(self: ^Mem_Track) {
        if mem_track__check_leaks(self) {
            log.panicf("\nMemory leaked!")
        }
    }

    mem_track__check_bad_frees :: proc(self: ^Mem_Track) -> bool {
        err := false

        for value in self.tracking.bad_free_array {

            log.errorf("Bad free at: %v\n", value.location)
            err = true
        }

        return err
    }

    mem_track__panic_if_bad_frees :: proc(self: ^Mem_Track) {
        if mem_track__check_bad_frees(self) {
            log.panicf("\nBad free!")
        }
    }

    mem_track__panic_if_bad_frees_or_leaks :: proc(self: ^Mem_Track) {
        mem_track__panic_if_bad_frees(self)
        mem_track__panic_if_leaks(self)
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    mem_track__test :: proc(t: ^testing.T) {
        // the check procs intentionally log an error per leak/bad free —
        // silence them while we exercise the failing paths on purpose
        context.logger = log.nil_logger()

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
        testing.expect(t, mem_track__check_leaks(&mt) == true)

        // freeing it clears the leak
        testing.expect(t, mem.free(p, tracked) == .None)
        testing.expect(t, mem_track__check_leaks(&mt) == false)

        // freeing a pointer this allocator never allocated is a bad free
        // (collected, not panicked — see mem_track__init)
        x: int
        mem.free(&x, tracked)
        testing.expect(t, mem_track__check_bad_frees(&mt) == true)

        // clear resets the tracked state
        mem_track__clear(&mt)
        testing.expect(t, mem_track__check_bad_frees(&mt) == false)
        testing.expect(t, mem_track__check_leaks(&mt) == false)

        // panic helpers pass through silently when clean
        mem_track__panic_if_bad_frees_or_leaks(&mt)
    }
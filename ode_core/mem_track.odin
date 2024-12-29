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
// Mem_Track

    Mem_Track :: struct {
        default: runtime.Allocator,
        tracking: mem.Tracking_Allocator
    }

    mem_track__init ::  proc(self: ^Mem_Track, default_allocator: runtime.Allocator) -> runtime.Allocator {
        self.default = default_allocator
        mem.tracking_allocator_init(&self.tracking, self.default) 
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
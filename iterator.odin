/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"
// Core
    import "core:mem"

///////////////////////////////////////////////////////////////////////////////
// Iterator
    
    Iterator :: struct {
        view: ^View,
        
        start_row: int,
        end_row: int, 
        orig_end_row: int, 

        one_record_size: int, 
        records_size: int,

        // cache
        index: int,
        raw_index: int,
        view_row: View_Row,

        // true when the whole view is dense-aligned: components of every Table(T) table
        // are read directly as table.rows[index], skipping the per-row rid records.
        // NOTE (measured dead end): reading per-column dense state here — a mask consulted
        // when only some columns are aligned — costs the fully-dense loop ~60% (the extra
        // path defeats the optimizer) and gains the mixed loop nothing. Per-column
        // alignment is exposed through view_dense_slice instead.
        dense: bool,
    }

    // Use start_row and end_row if you want to process View in batches
    iterator__init :: proc(self: ^Iterator, view: ^View, start_row: int = 0, end_row: int = 0) -> (err: Error)  {
        when VALIDATIONS {
            assert(view != nil)
            assert(self != nil)
            assert(start_row >= 0)
            assert(end_row <= len(view.rows))
            assert(start_row <= end_row)
            // The view missed membership updates while suspended — its rows may
            // reference destroyed entities / foreign table rows. rebuild() it first.
            assert(!view.stale, "view is stale (missed updates while suspended) — rebuild() it before iterating")
        }
       
        self.view = view 
        self.start_row = start_row
        self.orig_end_row = end_row

        if end_row == 0 {
            self.end_row = view_len(view)
        } else {
            self.end_row = end_row
        }

        self.view_row.view = view

        return iterator__reset(self)
    }

    iterator__reset :: proc(self: ^Iterator) -> Error {
        if self.view == nil || self.view.state != Object_State.Normal {
            self.view = nil
            self.raw_index = 0
            self.records_size = 0
            self.dense = false
            return API_Error.Object_Invalid
        }

        when VALIDATIONS {
            assert(!self.view.stale, "view is stale (missed updates while suspended) — rebuild() it before iterating")
        }

        self.dense = view__dense_resolve(self.view)

        // Recalculate end_now if original end_row was zero, which means end_row should be view_len()
        if self.orig_end_row == 0 {
            self.end_row = view_len(self.view)
        } else {
            // Explicit end_row: the view may have shrunk since init — clamp so
            // the iterator never walks cleared rows past the current length.
            self.end_row = min(self.orig_end_row, view_len(self.view))
            // A batch that now starts past the end is simply empty.
            if self.end_row < self.start_row do self.end_row = self.start_row
        }

        // We need to be careful here, because len of view might have changed
        assert(self.start_row <= self.end_row)

        self.one_record_size = self.view.one_record_size

        self.index = self.start_row - 1
        self.raw_index = self.one_record_size * self.index
        self.records_size = self.one_record_size * self.end_row

        return nil
    }

    // NOTE: the iterator caches the view's length (and dense-alignment state) at
    // init/reset. Structural changes while iterating — add/remove component,
    // create/destroy entity — are not reflected; call iterator_reset after them.
    // On the dense fast path this failure is SILENT: get_component reads
    // table.rows[it.index] directly, so a mid-iteration tail swap / group swap /
    // pack makes it return a different entity's component with no crash and no
    // wrong-looking eid. Defer structural changes with a Command_Buffer (or
    // pause_packing) instead of mutating mid-loop.
    iterator__next :: #force_inline proc "contextless" (self: ^Iterator) -> bool {

        self.raw_index += self.one_record_size
        self.index += 1

        if self.raw_index < self.records_size {
            #no_bounds_check {
                self.view_row.raw = (^View_Row_Raw)(&self.view.rows[self.raw_index])
            }

            return true

        } else {
            self.view_row.raw = nil 
            return false
        }
    }

    iterator__get_component_for_table :: #force_inline proc "contextless" (table: ^Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        if it.dense {
            // dense-aligned view: view row index == table row index
            #no_bounds_check {
                return &table.rows[it.index]
            }
        }
        return view_row__get_component_for_table(table, &it.view_row)
    }

    // for-in sugar over Table($T) columns: for v1 in ecs.iterate(&it, &t1) { ... }.
    // Equivalent to `for iterator_next(&it) { v1 := get_component(&t1, &it) }` — same
    // dense-fast-path getter, nothing new on the hot path. Table-only (see
    // view_dense_slice's "Only Table columns participate" note); Compact_Table/
    // Tiny_Table columns keep using the manual iterator_next + get_component form.
    iterator__iterate1 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1)) -> (v1: ^T1, cond: bool) {
        cond = iterator__next(it)
        if cond {
            v1 = iterator__get_component_for_table(t1, it)
        }
        return
    }

    // for-in sugar over two Table($T) columns: for v1, v2 in ecs.iterate(&it, &t1, &t2) { ... }.
    iterator__iterate2 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2)) -> (v1: ^T1, v2: ^T2, cond: bool) {
        cond = iterator__next(it)
        if cond {
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
        }
        return
    }

    // for-in sugar over three Table($T) columns: for v1, v2, v3 in ecs.iterate(&it, &t1, &t2, &t3) { ... }.
    iterator__iterate3 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2), t3: ^Table($T3)) -> (v1: ^T1, v2: ^T2, v3: ^T3, cond: bool) {
        cond = iterator__next(it)
        if cond {
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
            v3 = iterator__get_component_for_table(t3, it)
        }
        return
    }

    // for-in sugar over four Table($T) columns: for v1, v2, v3, v4 in ecs.iterate(&it, &t1, &t2, &t3, &t4) { ... }.
    iterator__iterate4 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2), t3: ^Table($T3), t4: ^Table($T4)) -> (v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, cond: bool) {
        cond = iterator__next(it)
        if cond {
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
            v3 = iterator__get_component_for_table(t3, it)
            v4 = iterator__get_component_for_table(t4, it)
        }
        return
    }

    iterator__get_component_for_compact_table :: #force_inline proc "contextless" (table: ^Compact_Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        return view_row__get_component_for_compact_table(table, &it.view_row)
    }

    iterator__get_component_for_tiny_table :: #force_inline proc "contextless" (table: ^Tiny_Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        return view_row__get_component_for_tiny_table(table, &it.view_row)
    }

    iterator__get_entity :: #force_inline proc "contextless" (self: ^Iterator) -> entity_id {
        return self.view_row.raw.eid
    }
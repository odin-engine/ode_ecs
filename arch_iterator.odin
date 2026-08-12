/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

///////////////////////////////////////////////////////////////////////////////
// Arch_Iterator — dense iterator directly over an Arch_Table's own rows, no View
// involved (archetype rows are already SoA-packed in lockstep across columns).
// Component types are supplied per `next()` call (`ecs.next(&it, Position, AI)`),
// not bound once at init, mirroring how iterator__init takes none either.
//
// Each nextN call lazily resolves and caches its column indices on the first call
// after init/reset. Caller discipline: don't mix different (T1..TN) type
// combinations on one iterator instance between resets — the cache can't detect that.

    Arch_Iterator :: struct {
        table: ^Arch_Table,

        start_row: int,
        end_row: int,
        orig_end_row: int,
        index: int,

        // Column-index cache, sized to the widest supported arity (7); only the
        // first N slots are meaningful for an N-arity nextN call.
        col_idx: [7]int,
        col_idx_resolved: bool,
    }

    // Use start_row/end_row to process an Arch_Table in batches. No component
    // types here — supplied per next() call instead.
    arch_iterator__init :: proc(self: ^Arch_Iterator, arch_table: ^Arch_Table, start_row: int = 0, end_row: int = 0, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(arch_table__is_valid(arch_table), loc = loc)
            assert(start_row >= 0, loc = loc)
            assert(end_row == 0 || start_row <= end_row, loc = loc)
        }

        self.table = arch_table
        self.start_row = start_row
        self.orig_end_row = end_row

        return arch_iterator__reset(self)
    }

    arch_iterator__reset :: proc(self: ^Arch_Iterator) -> Error {
        if self.table == nil || self.table.state != Object_State.Normal {
            self.table = nil
            self.index = self.start_row - 1
            self.end_row = 0
            self.col_idx_resolved = false
            return API_Error.Object_Invalid
        }

        if self.orig_end_row == 0 {
            self.end_row = arch_table__len(self.table)
        } else {
            // The table may have shrunk since init — clamp so the iterator
            // never walks past the current length.
            self.end_row = min(self.orig_end_row, arch_table__len(self.table))
            if self.end_row < self.start_row do self.end_row = self.start_row
        }

        self.index = self.start_row - 1
        self.col_idx_resolved = false // re-resolve lazily on the next next() call

        return nil
    }

    // Type-free variant: advances the cursor and returns just the entity id, skipping
    // holes exactly like next1..next7 but with no column resolution. Use when you don't
    // want to commit to a column set at the call site; fetch components afterward via
    // arch_table__get_component(table, eid, $T). Usable in a for-in loop or manually,
    // same as the typed variants below.
    arch_iterator__next :: #force_inline proc "contextless" (it: ^Arch_Iterator) -> (eid: entity_id, cond: bool) #no_bounds_check {
        it.index += 1
        // Skip the hole-check unless the table actually has holes — ~15% faster
        // on the common no-holes case (benchmarks/main.odin's iter_arch_it).
        if it.table.holes_count > 0 {
            for it.index < it.end_row && is_not_set(it.table.rid_to_eid[it.index]) do it.index += 1
        }

        cond = it.index < it.end_row
        if cond {
            eid = it.table.rid_to_eid[it.index]
        }
        return
    }

    // Sugar/step proc family — doubles as the for-in body (`for eid, pos, ai in
    // ecs.next(&at_it, Position, AI) { ... }`) and a manual-step call, matching how
    // iterator__iterate1..4 work. Skips holes left by paused removals. No `&` on
    // eid/pos/ai — Odin rejects `&`-prefixed loop vars for this custom-iterator
    // convention. "contextless": an unresolved column type can't assert, so it
    // permanently reports cond = false instead — pass a real column type.
    //
    arch_iterator__next1 :: #force_inline proc "contextless" (it: ^Arch_Iterator, $T1: typeid) -> (eid: entity_id, v1: ^T1, cond: bool) #no_bounds_check {
        if !it.col_idx_resolved {
            it.col_idx[0] = arch_table__column_index(it.table, typeid_of(T1))
            it.col_idx_resolved = true
        }
        if it.col_idx[0] < 0 do return

        it.index += 1
        // Skip the hole-check unless the table actually has holes — ~15% faster
        // on the common no-holes case (benchmarks/main.odin's iter_arch_it).
        if it.table.holes_count > 0 {
            for it.index < it.end_row && is_not_set(it.table.rid_to_eid[it.index]) do it.index += 1
        }

        cond = it.index < it.end_row
        if cond {
            eid = it.table.rid_to_eid[it.index]
            v1 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[0], T1)
        }
        return
    }

    arch_iterator__next2 :: #force_inline proc "contextless" (it: ^Arch_Iterator, $T1: typeid, $T2: typeid) -> (eid: entity_id, v1: ^T1, v2: ^T2, cond: bool) #no_bounds_check {
        if !it.col_idx_resolved {
            it.col_idx[0] = arch_table__column_index(it.table, typeid_of(T1))
            it.col_idx[1] = arch_table__column_index(it.table, typeid_of(T2))
            it.col_idx_resolved = true
        }
        if it.col_idx[0] < 0 || it.col_idx[1] < 0 do return

        it.index += 1
        // Skip the hole-check unless the table actually has holes — ~15% faster
        // on the common no-holes case (benchmarks/main.odin's iter_arch_it).
        if it.table.holes_count > 0 {
            for it.index < it.end_row && is_not_set(it.table.rid_to_eid[it.index]) do it.index += 1
        }

        cond = it.index < it.end_row
        if cond {
            eid = it.table.rid_to_eid[it.index]
            v1 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[0], T1)
            v2 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[1], T2)
        }
        return
    }

    arch_iterator__next3 :: #force_inline proc "contextless" (it: ^Arch_Iterator, $T1: typeid, $T2: typeid, $T3: typeid) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, cond: bool) #no_bounds_check {
        if !it.col_idx_resolved {
            it.col_idx[0] = arch_table__column_index(it.table, typeid_of(T1))
            it.col_idx[1] = arch_table__column_index(it.table, typeid_of(T2))
            it.col_idx[2] = arch_table__column_index(it.table, typeid_of(T3))
            it.col_idx_resolved = true
        }
        if it.col_idx[0] < 0 || it.col_idx[1] < 0 || it.col_idx[2] < 0 do return

        it.index += 1
        // Skip the hole-check unless the table actually has holes — ~15% faster
        // on the common no-holes case (benchmarks/main.odin's iter_arch_it).
        if it.table.holes_count > 0 {
            for it.index < it.end_row && is_not_set(it.table.rid_to_eid[it.index]) do it.index += 1
        }

        cond = it.index < it.end_row
        if cond {
            eid = it.table.rid_to_eid[it.index]
            v1 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[0], T1)
            v2 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[1], T2)
            v3 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[2], T3)
        }
        return
    }

    arch_iterator__next4 :: #force_inline proc "contextless" (it: ^Arch_Iterator, $T1: typeid, $T2: typeid, $T3: typeid, $T4: typeid) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, cond: bool) #no_bounds_check {
        if !it.col_idx_resolved {
            it.col_idx[0] = arch_table__column_index(it.table, typeid_of(T1))
            it.col_idx[1] = arch_table__column_index(it.table, typeid_of(T2))
            it.col_idx[2] = arch_table__column_index(it.table, typeid_of(T3))
            it.col_idx[3] = arch_table__column_index(it.table, typeid_of(T4))
            it.col_idx_resolved = true
        }
        if it.col_idx[0] < 0 || it.col_idx[1] < 0 || it.col_idx[2] < 0 || it.col_idx[3] < 0 do return

        it.index += 1
        // Skip the hole-check unless the table actually has holes — ~15% faster
        // on the common no-holes case (benchmarks/main.odin's iter_arch_it).
        if it.table.holes_count > 0 {
            for it.index < it.end_row && is_not_set(it.table.rid_to_eid[it.index]) do it.index += 1
        }

        cond = it.index < it.end_row
        if cond {
            eid = it.table.rid_to_eid[it.index]
            v1 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[0], T1)
            v2 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[1], T2)
            v3 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[2], T3)
            v4 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[3], T4)
        }
        return
    }

    arch_iterator__next5 :: #force_inline proc "contextless" (it: ^Arch_Iterator, $T1: typeid, $T2: typeid, $T3: typeid, $T4: typeid, $T5: typeid) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, v5: ^T5, cond: bool) #no_bounds_check {
        if !it.col_idx_resolved {
            it.col_idx[0] = arch_table__column_index(it.table, typeid_of(T1))
            it.col_idx[1] = arch_table__column_index(it.table, typeid_of(T2))
            it.col_idx[2] = arch_table__column_index(it.table, typeid_of(T3))
            it.col_idx[3] = arch_table__column_index(it.table, typeid_of(T4))
            it.col_idx[4] = arch_table__column_index(it.table, typeid_of(T5))
            it.col_idx_resolved = true
        }
        if it.col_idx[0] < 0 || it.col_idx[1] < 0 || it.col_idx[2] < 0 || it.col_idx[3] < 0 || it.col_idx[4] < 0 do return

        it.index += 1
        // Skip the hole-check unless the table actually has holes — ~15% faster
        // on the common no-holes case (benchmarks/main.odin's iter_arch_it).
        if it.table.holes_count > 0 {
            for it.index < it.end_row && is_not_set(it.table.rid_to_eid[it.index]) do it.index += 1
        }

        cond = it.index < it.end_row
        if cond {
            eid = it.table.rid_to_eid[it.index]
            v1 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[0], T1)
            v2 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[1], T2)
            v3 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[2], T3)
            v4 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[3], T4)
            v5 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[4], T5)
        }
        return
    }

    arch_iterator__next6 :: #force_inline proc "contextless" (it: ^Arch_Iterator, $T1: typeid, $T2: typeid, $T3: typeid, $T4: typeid, $T5: typeid, $T6: typeid) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, v5: ^T5, v6: ^T6, cond: bool) #no_bounds_check {
        if !it.col_idx_resolved {
            it.col_idx[0] = arch_table__column_index(it.table, typeid_of(T1))
            it.col_idx[1] = arch_table__column_index(it.table, typeid_of(T2))
            it.col_idx[2] = arch_table__column_index(it.table, typeid_of(T3))
            it.col_idx[3] = arch_table__column_index(it.table, typeid_of(T4))
            it.col_idx[4] = arch_table__column_index(it.table, typeid_of(T5))
            it.col_idx[5] = arch_table__column_index(it.table, typeid_of(T6))
            it.col_idx_resolved = true
        }
        if it.col_idx[0] < 0 || it.col_idx[1] < 0 || it.col_idx[2] < 0 || it.col_idx[3] < 0 || it.col_idx[4] < 0 || it.col_idx[5] < 0 do return

        it.index += 1
        // Skip the hole-check unless the table actually has holes — ~15% faster
        // on the common no-holes case (benchmarks/main.odin's iter_arch_it).
        if it.table.holes_count > 0 {
            for it.index < it.end_row && is_not_set(it.table.rid_to_eid[it.index]) do it.index += 1
        }

        cond = it.index < it.end_row
        if cond {
            eid = it.table.rid_to_eid[it.index]
            v1 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[0], T1)
            v2 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[1], T2)
            v3 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[2], T3)
            v4 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[3], T4)
            v5 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[4], T5)
            v6 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[5], T6)
        }
        return
    }

    arch_iterator__next7 :: #force_inline proc "contextless" (it: ^Arch_Iterator, $T1: typeid, $T2: typeid, $T3: typeid, $T4: typeid, $T5: typeid, $T6: typeid, $T7: typeid) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, v5: ^T5, v6: ^T6, v7: ^T7, cond: bool) #no_bounds_check {
        if !it.col_idx_resolved {
            it.col_idx[0] = arch_table__column_index(it.table, typeid_of(T1))
            it.col_idx[1] = arch_table__column_index(it.table, typeid_of(T2))
            it.col_idx[2] = arch_table__column_index(it.table, typeid_of(T3))
            it.col_idx[3] = arch_table__column_index(it.table, typeid_of(T4))
            it.col_idx[4] = arch_table__column_index(it.table, typeid_of(T5))
            it.col_idx[5] = arch_table__column_index(it.table, typeid_of(T6))
            it.col_idx[6] = arch_table__column_index(it.table, typeid_of(T7))
            it.col_idx_resolved = true
        }
        if it.col_idx[0] < 0 || it.col_idx[1] < 0 || it.col_idx[2] < 0 || it.col_idx[3] < 0 || it.col_idx[4] < 0 || it.col_idx[5] < 0 || it.col_idx[6] < 0 do return

        it.index += 1
        // Skip the hole-check unless the table actually has holes — ~15% faster
        // on the common no-holes case (benchmarks/main.odin's iter_arch_it).
        if it.table.holes_count > 0 {
            for it.index < it.end_row && is_not_set(it.table.rid_to_eid[it.index]) do it.index += 1
        }

        cond = it.index < it.end_row
        if cond {
            eid = it.table.rid_to_eid[it.index]
            v1 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[0], T1)
            v2 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[1], T2)
            v3 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[2], T3)
            v4 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[3], T4)
            v5 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[4], T5)
            v6 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[5], T6)
            v7 = arch_table__component_ptr_by_col(it.table, it.index, it.col_idx[6], T7)
        }
        return
    }

/*
    2025 (c) Oleh, https://github.com/zm69
    
    | DEPRECATED | Prefer slice(&view, T) + entities_slice(&view) instead.

    slice(&view, T) approach is about ~2x faster.
*/
package ode_ecs

///////////////////////////////////////////////////////////////////////////////
// Iterator (deprecated, prefer slice(&view, T) + entities_slice(&view) instead)

    Iterator :: struct {
        view: ^View,

        start_row: int,
        end_row: int,
        orig_end_row: int,

        index: int,

        dense: bool,
    }

    iterator__init :: proc(self: ^Iterator, view: ^View, start_row: int = 0, end_row: int = 0) -> (err: Error)  {
        when VALIDATIONS {
            assert(view != nil)
            assert(self != nil)
            assert(start_row >= 0)
            assert(end_row <= view.len)
            assert(start_row <= end_row)
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

        return iterator__reset(self)
    }

    iterator__reset :: proc(self: ^Iterator) -> Error {
        if self.view == nil || self.view.state != Object_State.Normal {
            self.view = nil
            self.dense = false
            return API_Error.Object_Invalid
        }

        when VALIDATIONS {
            assert(!self.view.stale, "view is stale (missed updates while suspended) — rebuild() it before iterating")
        }

        self.dense = view__dense_resolve(self.view)

        if self.orig_end_row == 0 {
            self.end_row = view_len(self.view)
        } else {
            self.end_row = min(self.orig_end_row, view_len(self.view))
            if self.end_row < self.start_row do self.end_row = self.start_row
        }

        assert(self.start_row <= self.end_row)

        self.index = self.start_row - 1

        return nil
    }

    iterator__next :: #force_inline proc "contextless" (self: ^Iterator) -> bool {

        self.index += 1

        if self.index < self.end_row {
            return true
        } else {
            return false
        }
    }

    iterator__get_component_for_table :: #force_inline proc "contextless" (table: ^Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        if it.dense {
            #no_bounds_check {
                return &table.rows[it.index]
            }
        }
        row := View_Row{view = it.view, row_ix = it.index}
        return view__get_component_for_table(it.view, &row, table)
    }

    iterator__iterate1 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1)) -> (v1: ^T1, cond: bool) {
        cond = iterator__next(it)
        if cond {
            v1 = iterator__get_component_for_table(t1, it)
        }
        return
    }

    iterator__iterate2 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2)) -> (v1: ^T1, v2: ^T2, cond: bool) {
        cond = iterator__next(it)
        if cond {
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
        }
        return
    }

    iterator__iterate3 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2), t3: ^Table($T3)) -> (v1: ^T1, v2: ^T2, v3: ^T3, cond: bool) {
        cond = iterator__next(it)
        if cond {
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
            v3 = iterator__get_component_for_table(t3, it)
        }
        return
    }

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

    iterator__next1 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1)) -> (eid: entity_id, v1: ^T1, cond: bool) {
        cond = iterator__next(it)
        if cond {
            eid = iterator__get_entity(it)
            v1 = iterator__get_component_for_table(t1, it)
        }
        return
    }

    iterator__next2 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2)) -> (eid: entity_id, v1: ^T1, v2: ^T2, cond: bool) {
        cond = iterator__next(it)
        if cond {
            eid = iterator__get_entity(it)
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
        }
        return
    }

    iterator__next3 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2), t3: ^Table($T3)) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, cond: bool) {
        cond = iterator__next(it)
        if cond {
            eid = iterator__get_entity(it)
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
            v3 = iterator__get_component_for_table(t3, it)
        }
        return
    }

    iterator__next4 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2), t3: ^Table($T3), t4: ^Table($T4)) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, cond: bool) {
        cond = iterator__next(it)
        if cond {
            eid = iterator__get_entity(it)
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
            v3 = iterator__get_component_for_table(t3, it)
            v4 = iterator__get_component_for_table(t4, it)
        }
        return
    }

    iterator__next5 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2), t3: ^Table($T3), t4: ^Table($T4), t5: ^Table($T5)) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, v5: ^T5, cond: bool) {
        cond = iterator__next(it)
        if cond {
            eid = iterator__get_entity(it)
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
            v3 = iterator__get_component_for_table(t3, it)
            v4 = iterator__get_component_for_table(t4, it)
            v5 = iterator__get_component_for_table(t5, it)
        }
        return
    }

    iterator__next6 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2), t3: ^Table($T3), t4: ^Table($T4), t5: ^Table($T5), t6: ^Table($T6)) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, v5: ^T5, v6: ^T6, cond: bool) {
        cond = iterator__next(it)
        if cond {
            eid = iterator__get_entity(it)
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
            v3 = iterator__get_component_for_table(t3, it)
            v4 = iterator__get_component_for_table(t4, it)
            v5 = iterator__get_component_for_table(t5, it)
            v6 = iterator__get_component_for_table(t6, it)
        }
        return
    }

    iterator__next7 :: #force_inline proc "contextless" (it: ^Iterator, t1: ^Table($T1), t2: ^Table($T2), t3: ^Table($T3), t4: ^Table($T4), t5: ^Table($T5), t6: ^Table($T6), t7: ^Table($T7)) -> (eid: entity_id, v1: ^T1, v2: ^T2, v3: ^T3, v4: ^T4, v5: ^T5, v6: ^T6, v7: ^T7, cond: bool) {
        cond = iterator__next(it)
        if cond {
            eid = iterator__get_entity(it)
            v1 = iterator__get_component_for_table(t1, it)
            v2 = iterator__get_component_for_table(t2, it)
            v3 = iterator__get_component_for_table(t3, it)
            v4 = iterator__get_component_for_table(t4, it)
            v5 = iterator__get_component_for_table(t5, it)
            v6 = iterator__get_component_for_table(t6, it)
            v7 = iterator__get_component_for_table(t7, it)
        }
        return
    }

    iterator__get_component_for_compact_table :: #force_inline proc "contextless" (table: ^Compact_Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        row := View_Row{view = it.view, row_ix = it.index}
        return view__get_component_for_compact_table(it.view, &row, table)
    }

    iterator__get_component_for_tiny_table :: #force_inline proc "contextless" (table: ^Tiny_Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        row := View_Row{view = it.view, row_ix = it.index}
        return view__get_component_for_tiny_table(it.view, &row, table)
    }

    iterator__get_component_for_arch_table :: #force_inline proc "contextless" (table: ^Arch_Table, it: ^Iterator, $T: typeid) -> ^T #no_bounds_check {
        row := View_Row{view = it.view, row_ix = it.index}
        return view__get_component_for_arch_table(it.view, &row, table, T)
    }

    iterator__get_entity :: #force_inline proc "contextless" (self: ^Iterator) -> entity_id {
        return self.view.rid_to_eid[self.index]
    }

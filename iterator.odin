/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"
// Core
    import "core:slice"
    import "core:log"
    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// Iterator
    
    Iterator :: struct {
        view: ^View,
        index: int,

        // precalculated
        mul_by_columns_count: int,

        // cached
    }

    iterator__init :: proc(self: ^Iterator, view: ^View) -> (err: Error)  {
        if view == nil || view.state != Object_State.Normal {
            self.view = nil
            self.index = -1
            return API_Error.Object_Invalid
        } 
        
        self.view = view
        self.index = -1

        return 
    }

    iterator__next :: proc "contextless" (self: ^Iterator) -> bool {
        self.index += 1

        if self.view == nil || self.index >= view__len(self.view) do return false

        self.mul_by_columns_count = self.index * self.view.columns_count

        return true
    }

    iterator__get_component :: #force_inline proc "contextless" (table: ^Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        view := it.view
        view_rid := view.records[it.mul_by_columns_count + view.tid_to_cid[table.id]]
        return &table.records[view_rid]
    }

    iterator__get_entity :: #force_inline proc "contextless" (self: ^Iterator) -> entity_id #no_bounds_check {
        return cast(entity_id)self.view.records[self.mul_by_columns_count]
    }
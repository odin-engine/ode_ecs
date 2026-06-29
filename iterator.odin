/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

import "core:log"
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
    }

    // Use start_row and end_row if you want to process View in batches
    iterator__init :: proc(self: ^Iterator, view: ^View, start_row: int = 0, end_row: int = 0) -> (err: Error)  {
        when VALIDATIONS {
            assert(view != nil)
            assert(self != nil)
            assert(start_row >= 0)
            assert(end_row <= len(view.rows))
            assert(start_row <= end_row)
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
            return API_Error.Object_Invalid
        } 
        
        // Recalculate end_now if original end_row was zero, which means end_row should be view_len()
        if self.orig_end_row == 0 {
            self.end_row = view_len(self.view)
        }

        // We need to be careful here, because len of view might have changed
        assert(self.start_row <= self.end_row)

        self.one_record_size = self.view.one_record_size

        self.index = self.start_row - 1
        self.raw_index = self.one_record_size * self.index
        self.records_size = self.one_record_size * self.end_row

        return nil
    }

    iterator__next :: proc "contextless" (self: ^Iterator) -> bool {

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
        return view_row__get_component_for_table(table, &it.view_row)
    }

    iterator__get_component_for_small_table :: #force_inline proc "contextless" (table: ^Compact_Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        return view_row__get_component_for_small_table(table, &it.view_row)
    }

    iterator__get_component_for_tiny_table :: #force_inline proc "contextless" (table: ^Tiny_Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        return view_row__get_component_for_tiny_table(table, &it.view_row)
    }

    iterator__get_entity :: #force_inline proc "contextless" (self: ^Iterator) -> entity_id {
        return self.view_row.raw.eid
    }


// TableIterators

// NOTE:
// Tables report length as "alive things in this db".
// Dbs are the underlying structure holding "alive and expired"
// So the index has no meaning outside of this iterator and/or table,
// returning it on "get" would be confusing ?
TableIterator :: struct($T: typeid) {
	table:           ^Table(T),

	// current state
	alive_index:           int,
	alive_index_max: int,
}

// Use start_row and end_row if you want to process View in batches
table_iterator__init :: proc(table: ^Table($T)) -> (iterator: TableIterator(T)) {
	when VALIDATIONS {assert(table != nil)}

	iterator = TableIterator(T) {
		table = table,
	}
	table_iterator__reset(&iterator)

	return iterator
}

table_iterator__reset :: proc(iterator: ^TableIterator($T)) {
	when VALIDATIONS {assert(iterator.table != nil)}
	iterator.alive_index = -1
	iterator.alive_index_max = len(iterator.table.rows) // alive things inside this table
}

table_iterator__next :: proc(iterator: ^TableIterator($T)) -> bool {
	iterator.alive_index += 1
	return iterator.alive_index < iterator.alive_index_max
}


table_iterator__get :: proc(self: ^TableIterator($T)) -> (component: ^T, entity: entity_id) {
	component = &self.table.rows[self.alive_index]
	entity = get_entity(self.table, self.alive_index)
	return
}

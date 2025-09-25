/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// Iterator
    
    Iterator :: struct {
        view: ^View,
        
        start_row: int,
        end_row: int, 

        one_record_size: int, 
        records_size: int,


        // cache
        raw_index: int,
        record: ^View_Record,
    }

    // Use start_row and end_row if you want to process View in batches
    iterator_init :: proc(self: ^Iterator, view: ^View, start_row: int = 0, end_row: int = 0) -> (err: Error)  {
        when VALIDATIONS {
            assert(view != nil)
            assert(self != nil)
            assert(start_row >= 0)
            assert(end_row <= len(view.rows))
            assert(start_row <= end_row)
        }
       
        self.view = view 
        self.start_row = start_row
        if end_row == 0 {
            self.end_row = len(view.rows)
        } else {
            self.end_row = end_row
        }

        return iterator_reset(self)
    }

    iterator_reset :: proc(self: ^Iterator) -> Error {
        if self.view == nil || self.view.state != Object_State.Normal {
            self.view = nil
            self.raw_index = 0
            self.records_size = 0
            return API_Error.Object_Invalid
        } 

        self.one_record_size = self.view.one_record_size

        self.raw_index = self.one_record_size * (self.start_row - 1)
        self.records_size = self.one_record_size * self.end_row

        return nil
    }

    iterator_next :: proc "contextless" (self: ^Iterator) -> bool {

        self.raw_index += self.one_record_size

        if self.raw_index < self.records_size {
            #no_bounds_check {
                self.record = (^View_Record)(&self.view.rows[self.raw_index])
            }
            return true 

        } else {
            self.record = nil 
            return false
        }
    }

    iterator__get_component_for_table :: #force_inline proc "contextless" (table: ^Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        #no_bounds_check {
            return (^T)(it.record.refs[it.view.tid_to_cid[table.id]])
        }
    }

    iterator__get_component_for_small_table :: #force_inline proc "contextless" (table: ^Compact_Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        #no_bounds_check {
            return (^T)(it.record.refs[it.view.tid_to_cid[table.id]])
        }
    }

    iterator__get_component_for_tiny_table :: #force_inline proc "contextless" (table: ^Tiny_Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        #no_bounds_check {
            return (^T)(it.record.refs[it.view.tid_to_cid[table.id]])
        }
    }

    iterator__get_entity :: #force_inline proc "contextless" (self: ^Iterator) -> entity_id {
        return self.record.eid
    }
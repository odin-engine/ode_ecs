/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// Iterator
    
    Iterator :: struct {
        view: ^View,
        one_record_size: int, 
        records_size: int,

        // cache
        raw_index: int,
        record: ^View_Record,
    }

    iterator_init :: proc(self: ^Iterator, view: ^View) -> (err: Error)  {
        self.view = view 

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
        self.raw_index = -self.one_record_size

        self.records_size = len(self.view.rows) * self.one_record_size

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

    get_component_by_iterator :: #force_inline proc "contextless" (table: ^Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        #no_bounds_check {
            return (^T)(it.record.refs[it.view.tid_to_cid[table.id]])
        }
    }

    get_entity_by_iterator :: #force_inline proc "contextless" (self: ^Iterator) -> entity_id {
        return self.record.eid
    }
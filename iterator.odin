/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

///////////////////////////////////////////////////////////////////////////////
// Iterator
    
    Iterator :: struct {
        view: ^View,
        index: int, 
        raw_index: int,
        len: int,
        record: ^View_Record,
    }

    iterator_init :: proc(self: ^Iterator, view: ^View) -> (err: Error)  {
        if view == nil || view.state != Object_State.Normal {
            self.view = nil
            self.raw_index = 0
            self.index = DELETED_INDEX
            self.len = 0
            return API_Error.Object_Invalid
        } 
        
        self.view = view
        self.raw_index = -view.one_record_size
        self.index = -1
        self.len = view_len(view)

        return 
    }

    iterator_next :: proc "contextless" (self: ^Iterator) -> bool {
        if self.view == nil do return false 
        
        self.raw_index += self.view.one_record_size
        self.index += 1

        if self.index >= self.len do return false
        
        #no_bounds_check {
            self.record = (^View_Record)(&self.view.records[self.raw_index])
        }

        return true
    }

    get_component_by_iterator :: #force_inline proc "contextless" (table: ^Table($T), it: ^Iterator) -> ^T #no_bounds_check {
        #no_bounds_check {
            return (^T)(it.record.refs[it.view.tid_to_cid[table.id]])
        }
    }

    get_entity_by_iterator :: #force_inline proc "contextless" (self: ^Iterator) -> entity_id {
        return self.record.eid
    }
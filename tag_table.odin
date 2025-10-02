/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:log"
    import "core:math"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"


///////////////////////////////////////////////////////////////////////////////
// Tag_Table

    Tag_Table :: struct {
        using shared: Shared_Table,

        rows: []entity_id,                          // rid_to_eid
        eid_to_ptr: oc_maps.Rh_Map(^entity_id),     // pointer to cell in rows

        cap: int, 

        subscribers: oc.Dense_Arr(^View),
    }

    tag_table__is_valid :: proc(self: ^Tag_Table) -> bool {
        if self == nil do return false 
        if !shared_table__is_valid_internal(&self.shared) do return false 
        if self.rows == nil do return false
        if !oc_maps.rh_map__is_valid(&self.eid_to_ptr) do return false 
        if self.cap <= 0 do return false 
        if !oc.dense_arr__is_valid(&self.subscribers) do return false 

        return true
    }

    tag_table__init :: proc(self: ^Tag_Table, db: ^Database, cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // should be NOT_INITIALIZED
            assert(cap > 0, loc = loc)
            assert(cap <= db.id_factory.cap, loc = loc) // cannot be larger than entities_cap
        }

        shared_table__init(&self.shared, Table_Type.Tag_Table, db)
        self.cap = cap

        oc.dense_arr__init(&self.subscribers, VIEWS_CAP, db.allocator) or_return

        self.rows = make([]entity_id, self.cap, db.allocator) or_return
        // load factor 0.5 and make it power of two
        oc_maps.rh_map__init(&self.eid_to_ptr, math.next_power_of_two(self.cap * 2), db.allocator) or_return

        self.id = database__attach_table(db, self) or_return
        self.state = Object_State.Normal

        tag_table__clear(self) or_return

        return nil
    }

    tag_table__terminate :: proc(self: ^Tag_Table) -> Error {
        oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return
        oc_maps.rh_map__terminate(&self.eid_to_ptr, self.db.allocator) or_return

        delete(self.rows, self.db.allocator) or_return

        database__detach_table(self.db, self)

        shared_table__clear_state(&self.shared)

        return nil
    }

    tag_table__memory_usage :: proc (self: ^Tag_Table) -> int {  
        total := size_of(self^)

        if self.rows != nil {
            total += size_of(self.rows[0]) * len(self.rows)
        }

        total += oc_maps.rh_map__memory_usage(&self.eid_to_ptr)

        return total
    }

    tag_table__len :: #force_inline proc "contextless" (self: ^Tag_Table) -> int {
        return oc_maps.rh_map__len(&self.eid_to_ptr)
    }

    tag_table__cap :: #force_inline proc "contextless" (self: ^Tag_Table) -> int {
        return self.cap
    }

    tag_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Tag_Table, #any_int row_number: int) -> entity_id {
        return self.rows[row_number]
    }

    tag_table__add_tag :: proc(self: ^Tag_Table, eid: entity_id, loc:= #caller_location) -> (err: Error) {
        database__is_entity_correct(self.db, eid) or_return

        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len >= self.cap do return oc.Core_Error.Container_Is_Full 

        eidptr := oc_maps.rh_map__get(&self.eid_to_ptr, eid.ix)

        if eidptr != nil do return nil // already added

        // Update rows
        #no_bounds_check {
            eidptr = &self.rows[raw.len]
        }

        eidptr^ = eid // copy
         
        // Add eid_to_ptr
        oc_maps.rh_map__add(&self.eid_to_ptr, eid.ix, eidptr) or_return

        // Update eid_to_bits in db
        database__add_component(self.db, eid, self.id)

        raw.len += 1

        // Notify subscribed views
        for view in self.subscribers.items {
            if !view.suspended && view__entity_match(view, eid) do view__add_record(view, eid)
        }

        return nil
    }

    tag_table__remove_tag :: proc(self: ^Tag_Table, target_eid: entity_id, loc:= #caller_location) -> (err: Error) {
        database__is_entity_correct(self.db, target_eid) or_return

        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found 

        target_ptr := oc_maps.rh_map__get(&self.eid_to_ptr, target_eid.ix)

        // Check if exists
        if target_ptr == nil do return oc.Core_Error.Not_Found 

        tail_rid := raw.len - 1
        tail_ptr := &self.rows[tail_rid]
        
        error : Error
        
        if target_ptr == tail_ptr {
            // Remove indexes
            error = oc_maps.rh_map__remove(&self.eid_to_ptr, target_eid.ix)
            assert(error == nil) // should not happen because we already checked it does exist

            self.rows[tail_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
            }

        } else {
            tail_eid := tail_ptr^
            assert(tail_eid.ix != DELETED_INDEX)

            // Update tail indexes
            oc_maps.rh_map__update(&self.eid_to_ptr, tail_eid.ix, target_ptr)
            oc_maps.rh_map__remove(&self.eid_to_ptr, target_eid.ix)

            target_ptr^ = tail_eid // copy eid from tail
            tail_ptr.ix = DELETED_INDEX

            // Notify subscribed views
            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component(view, self, tail_eid, target_ptr)
                }
            }
        }

        raw.len -= 1

        // Update eid_to_bits in db
        database__remove_component(self.db, target_eid, self.id)

        return nil
    }

    tag_table__remove_component :: tag_table__remove_tag

    tag_table__clear :: proc (self: ^Tag_Table) -> Error {
        if !tag_table__is_valid(self) do return API_Error.Object_Invalid

        if self.rows != nil {
            for i := 0; i < len(self.rows); i+=1 do self.rows[i].ix = DELETED_INDEX
        }

        (^runtime.Raw_Slice)(&self.rows).len = 0

        oc_maps.rh_map__clear(&self.eid_to_ptr)

        return nil
    }

    @(private)
    tag_table__attach_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        _, err := oc.dense_arr__add(&self.subscribers, view)
        return err
    }

    @(private)
    tag_table__detach_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        err := oc.dense_arr__remove_by_value(&self.subscribers, view)
        return err
    }
/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:slice"
    import "core:math"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Compact_Table_Base

    // Base for Compact_Table
    @(private)
    Compact_Table_Base :: struct {
        using shared: Shared_Table,

        type_info: ^runtime.Type_Info,
        rid_to_eid: []entity_id,
        // eid.ix -> row id; 8-byte map items instead of 16 (see Rh_Map32). The
        // component address is derived as &rows[rid] on lookup, so a tail swap
        // patches a rid value here instead of a pointer.
        eid_to_rid: oc_maps.Rh_Map32,

        cap: int,

        // Deferred tail swap (db.tail_swap_paused) hole bookkeeping, see Table_Base
        holes_count: int,
        first_hole_rid: int,

        subscribers: oc.Dense_Arr(^View),
        subscribers_with_filter: oc.Dense_Arr(^View),
        subscribers_excluding: oc.Dense_Arr(^View), // views that EXCLUDE this table (see view__init excludes)
    }

    @(private)
    compact_table_base__is_valid :: proc(self: ^Compact_Table_Base) -> bool {
        if self == nil do return false 
        if !shared_table__is_valid_internal(&self.shared) do return false 
        if self.type_info == nil do return false
        if self.rid_to_eid == nil do return false
        if !oc_maps.rh_map32__is_valid(&self.eid_to_rid) do return false
        if self.cap <= 0 do return false 
        if !oc.dense_arr__is_valid(&self.subscribers) do return false
        if !oc.dense_arr__is_valid(&self.subscribers_with_filter) do return false
        if !oc.dense_arr__is_valid(&self.subscribers_excluding) do return false

        return true
    }

    @(private)
    compact_table_base__init :: proc(self: ^Compact_Table_Base, db: ^Database, cap: int, subscribers_cap: int = VIEWS_CAP) -> Error {
        shared_table__init(&self.shared, Table_Type.Compact_Table, db)

        self.cap = cap

        self.rid_to_eid = make([]entity_id, self.cap, db.allocator) or_return

        // load factor 0.5 and make it power of two
        oc_maps.rh_map32__init(&self.eid_to_rid, math.next_power_of_two(self.cap * 2), db.allocator) or_return

        oc.dense_arr__init(&self.subscribers, subscribers_cap, db.allocator) or_return
        oc.dense_arr__init(&self.subscribers_with_filter, subscribers_cap, db.allocator) or_return
        oc.dense_arr__init(&self.subscribers_excluding, subscribers_cap, db.allocator) or_return

        return nil
    }

    @(private)
    compact_table_base__terminate :: proc(self: ^Compact_Table_Base) -> Error {
        oc.dense_arr__terminate(&self.subscribers_excluding, self.db.allocator) or_return
        oc.dense_arr__terminate(&self.subscribers_with_filter, self.db.allocator) or_return
        oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return

        delete(self.rid_to_eid, self.db.allocator) or_return
        oc_maps.rh_map32__terminate(&self.eid_to_rid, self.db.allocator) or_return
       
        return nil
    }

    @(private)
    compact_table_base__cap :: proc(self: ^Compact_Table_Base) -> int {
        return self.cap
    }

    @(private)
    compact_table_base__attach_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        _, err := oc.dense_arr__add(&self.subscribers, view)
        if err != nil do return err

        if view.filter != nil {
            _, err = oc.dense_arr__add(&self.subscribers_with_filter, view)
            if err != nil do return err
        }

        return nil
    }

    @(private)
    compact_table_base__detach_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        err := oc.dense_arr__remove_by_value(&self.subscribers, view)
        if err != nil do return err

        err = oc.dense_arr__remove_by_value(&self.subscribers_with_filter, view)
        if err == oc.Core_Error.Not_Found do return nil // not found is ok, it means view has no filter
        return err
    }

    @(private)
    compact_table_base__attach_exclude_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        _, err := oc.dense_arr__add(&self.subscribers_excluding, view)
        return err
    }

    @(private)
    compact_table_base__detach_exclude_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_excluding, view)
    }

    @(private)
    // See table_base__notify_excluding_views
    compact_table_base__notify_excluding_views :: proc(self: ^Compact_Table_Base, eid: entity_id) {
        if self.db.destroying_eid_ix == eid.ix do return
        for view in self.subscribers_excluding.items {
            if !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }
    }

    @(private)
    compact_table_base__memory_usage :: proc (self: ^Compact_Table_Base) -> int {    
        total := size_of(self^)

        if self.rid_to_eid != nil {
            total += size_of(self.rid_to_eid[0]) * len(self.rid_to_eid)
        }

        total += oc_maps.rh_map32__memory_usage(&self.eid_to_rid)

        // rows
        total += self.type_info.size * self.cap

        total += oc.dense_arr__memory_usage(&self.subscribers)
        total += oc.dense_arr__memory_usage(&self.subscribers_with_filter)
        total += oc.dense_arr__memory_usage(&self.subscribers_excluding)

        return total
    }

    @(private)
    compact_table_base__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Compact_Table_Base, #any_int row_number: int) -> entity_id {
        return self.rid_to_eid[row_number]
    }

///////////////////////////////////////////////////////////////////////////////
// Compact_Table_Raw

    @(private)
    Compact_Table_Raw :: struct {
        using base: Compact_Table_Base,
        rows: []byte,
    }

    @(private)
    compact_table_raw__rid_to_ptr :: #force_inline proc "contextless" (self: ^Compact_Table_Raw, #any_int rid: int) -> rawptr {
        return rawptr(uintptr(raw_data(self.rows)) + uintptr(rid) * uintptr(self.type_info.size))
    }

    @(private)
    compact_table_raw__get_component_by_entity :: proc (self: ^Compact_Table_Raw, eid: entity_id) -> rawptr {
        rid := oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix))
        if rid == oc_maps.RH_MAP32_DELETED do return nil
        return compact_table_raw__rid_to_ptr(self, rid)
    }

    @(private)
    compact_table_raw__terminate :: proc(self: ^Compact_Table_Raw) -> Error {
        for view in self.subscribers.items do view.state = Object_State.Invalid
        for view in self.subscribers_excluding.items do view.state = Object_State.Invalid

        // Clear this table's bit from all entities, see table_raw__terminate
        for &bits in self.db.eid_to_bits do uni_bits__remove(&bits, self.id)

        database__detach_table(self.db, self)

        if self.rows != nil do delete(self.rows, self.db.allocator) or_return

        compact_table_base__terminate(self) or_return

        shared_table__clear_state(&self.shared)

        return nil
    }

    @(private)
    // #no_bounds_check: row indexes derive from raw.len < cap or from the rid map
    compact_table_raw__remove_component :: proc(self: ^Compact_Table_Raw, target_eid: entity_id, loc:= #caller_location) -> (err: Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found

        target_rid := oc_maps.rh_map32__get(&self.eid_to_rid, u32(target_eid.ix))

        // Check if component exists
        if target_rid == oc_maps.RH_MAP32_DELETED do return oc.Core_Error.Not_Found

        T_size := self.type_info.size
        target := compact_table_raw__rid_to_ptr(self, target_rid)

        // Deferred tail swap: clear the component in place, leaving a hole.
        // Nothing moves, so component pointers stay stable while iterating.
        if shared_table__is_packing_paused(cast(^Shared_Table) self) {
            oc_maps.rh_map32__remove(&self.eid_to_rid, u32(target_eid.ix))
            self.rid_to_eid[target_rid].ix = DELETED_INDEX
            mem.zero(target, T_size)

            if int(target_rid) == raw.len - 1 {
                raw.len -= 1
                // absorb trailing holes so they never need packing
                for raw.len > 0 && is_not_set(self.rid_to_eid[raw.len - 1]) {
                    raw.len -= 1
                    self.holes_count -= 1
                }
            } else {
                self.holes_count += 1
                if int(target_rid) < self.first_hole_rid do self.first_hole_rid = int(target_rid)
            }

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
            }

            database__remove_component(self.db, target_eid, self.id)
            compact_table_base__notify_excluding_views(self, target_eid)
            return
        }

        tail_rid := raw.len - 1
        tail_eid := self.rid_to_eid[tail_rid]

        assert(!is_not_set(tail_eid))

        tail := compact_table_raw__rid_to_ptr(self, tail_rid)

        error : Error

        // Replace removed component with tail
        if int(target_rid) == tail_rid {
            // Remove indexes
            error = oc_maps.rh_map32__remove(&self.eid_to_rid, u32(target_eid.ix))
            assert(error == nil) // should not happen because we already checked it does exist

            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
            }
        }
        else {
            // DATA COPY
            mem.copy(target, tail, T_size)

            // Update tail indexes
            oc_maps.rh_map32__update(&self.eid_to_rid, u32(tail_eid.ix), target_rid)
            oc_maps.rh_map32__remove(&self.eid_to_rid, u32(target_eid.ix))

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            // Notify subscribed views
            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component_rid(view, self, tail_eid, target_rid)
                }
            }
        }

        // Zero tail
        mem.zero(tail, T_size)
        raw.len -= 1

        // Update eid_to_bits in db
        database__remove_component(self.db, target_eid, self.id)

        compact_table_base__notify_excluding_views(self, target_eid)

        return
    }

    @(private)
    // Adds (or finds) the entity's row and returns a pointer to the component.
    // If `data` is not nil it is copied into the component BEFORE the subscriber
    // notifications run (view filters read component data through the row refs),
    // and it also overwrites the existing value on the Component_Already_Exist
    // path — "last write wins", used by Command_Buffer.
    // #no_bounds_check: callers validate eid via database__is_entity_correct;
    // row indexes derive from raw.len < cap or from the rid map
    compact_table_raw__add_component :: proc(self: ^Compact_Table_Raw, eid: entity_id, data: rawptr = nil) -> (component: rawptr, err: Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        rid := oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix))

        // Check if component already exist
        if rid == oc_maps.RH_MAP32_DELETED {
            // Capacity only matters when actually inserting — re-adding an
            // existing component on a full table must still report Component_Already_Exist
            if raw.len >= self.cap do return nil, oc.Core_Error.Container_Is_Full

            // Get component
            component = compact_table_raw__rid_to_ptr(self, raw.len)
            if data != nil do mem.copy(component, data, self.type_info.size)

            // Update rid_to_eid
            self.rid_to_eid[raw.len] = eid

            // Add eid_to_rid
            oc_maps.rh_map32__add(&self.eid_to_rid, u32(eid.ix), u32(raw.len)) or_return

            // Update eid_to_bits in db
            database__add_component(self.db, eid, self.id)

            raw.len += 1
        } else {
            component = compact_table_raw__rid_to_ptr(self, rid)
            if data != nil do mem.copy(component, data, self.type_info.size)
            err = API_Error.Component_Already_Exist
        }

        // Notify subscribed views. Also runs on the already-exists path on purpose: it
        // recovers a view membership that a previous add failed to register (e.g. view was at cap).
        for view in self.subscribers.items {
            if !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }

        // Views excluding this table lose the entity (no-op if it wasn't a member)
        for view in self.subscribers_excluding.items {
            if !view.suspended do view__remove_record(view, eid)
        }

        return
    }

    // Compact holes left by removals made while tail swap was paused,
    // see table_raw__pack for the algorithm
    @(private)
    compact_table_raw__pack :: proc(self: ^Compact_Table_Raw) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.holes_count <= 0 {
            self.first_hole_rid = max(int)
            return nil
        }

        raw := (^runtime.Raw_Slice)(&self.rows)
        T_size := self.type_info.size
        rows := raw_data(self.rows)

        front := self.first_hole_rid
        back := raw.len - 1

        for self.holes_count > 0 {
            // shrink span past trailing holes
            for back >= 0 && is_not_set(self.rid_to_eid[back]) {
                back -= 1
                self.holes_count -= 1
            }
            if self.holes_count <= 0 do break

            // next hole from the front; guaranteed to exist below back
            for !is_not_set(self.rid_to_eid[front]) do front += 1

            // move the last live row into the hole
            dst := rawptr(uintptr(rows) + uintptr(front) * uintptr(T_size))
            src := rawptr(uintptr(rows) + uintptr(back)  * uintptr(T_size))
            mem.copy(dst, src, T_size)

            moved_eid := self.rid_to_eid[back]
            self.rid_to_eid[front] = moved_eid
            self.rid_to_eid[back].ix = DELETED_INDEX
            oc_maps.rh_map32__update(&self.eid_to_rid, u32(moved_eid.ix), u32(front))
            mem.zero(src, T_size)

            for view in self.subscribers.items {
                if !view.suspended do view__update_component_rid(view, self, moved_eid, front)
            }

            back -= 1
            front += 1
            self.holes_count -= 1
        }

        raw.len = back + 1
        self.first_hole_rid = max(int)

        return nil
    }

    @(private)
    compact_table_raw__pause_packing :: proc(self: ^Compact_Table_Raw) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = true
        return nil
    }

    @(private)
    compact_table_raw__resume_packing :: proc(self: ^Compact_Table_Raw) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = false
        return compact_table_raw__pack(self)
    }

    compact_table_raw__len :: #force_inline proc "contextless" (self: ^Compact_Table_Raw) -> int {
        return (^runtime.Raw_Slice)(&self.rows).len
    }

    // clear data, nothing else
    compact_table_raw__clear :: proc (self: ^Compact_Table_Raw, zero_components := true) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.rid_to_eid != nil {
            for i := 0; i < len(self.rid_to_eid); i+=1 do self.rid_to_eid[i].ix = DELETED_INDEX
        }

        oc_maps.rh_map32__clear(&self.eid_to_rid)
       
        if zero_components && self.cap > 0 && self.rows != nil {
            raw := (^runtime.Raw_Slice)(&self.rows)
            mem.zero(raw_data(self.rows), self.type_info.size * raw.len)
        }
        (^runtime.Raw_Slice)(&self.rows).len = 0

        self.holes_count = 0
        self.first_hole_rid = max(int)

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Compact_Table

    // Components table
    Compact_Table :: struct($T: typeid) {
        using base: Compact_Table_Base,
        // table_record_id => component
        rows: []T,     
    }

    compact_table__is_valid :: proc(self: ^Compact_Table($T)) -> bool {
        if self == nil do return false 
        if !compact_table_base__is_valid(&self.base) do return false
        if self.rows == nil do return false

        return true
    }

    compact_table__init :: proc(self: ^Compact_Table($T), db: ^Database, cap: int, subscribers_cap: int = VIEWS_CAP, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // table should be NOT_INITIALIZED
            assert(cap > 0, loc = loc)
            assert(cap <= db.id_factory.cap, loc = loc) // cannot be larger than entities_cap
            assert(db.id_factory.cap < int(max(u32)), loc = loc) // eid.ix keys must fit the u32 rid map
        }

        if size_of(T) == 0 do return API_Error.Component_Size_Cannot_Be_Zero

        self.type_info = type_info_of(typeid_of(T))

        compact_table_base__init(&self.base, db, cap, subscribers_cap) or_return

        self.rows = make([]T, cap, db.allocator) or_return
        
        self.id = database__attach_table(db, self) or_return

        self.state = Object_State.Normal

        compact_table_raw__clear(cast(^Compact_Table_Raw)self) or_return 

        return nil
    }

    compact_table__terminate :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.type_info.id == typeid_of(T))
            assert(self.db != nil)
        }

        compact_table_raw__terminate(cast(^Compact_Table_Raw) self) or_return

        return nil
    }
    
    compact_table__add_component :: proc(self: ^Compact_Table($T), eid: entity_id) -> (component: ^T, err: Error) {
        err = database__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        c, aerr := compact_table_raw__add_component(cast(^Compact_Table_Raw) self, eid)
        return cast(^T) c, aerr
    }

    // Compact holes left by removals made while tail swap was paused
    // (see database__pause_packing). Callable mid-pause too.
    compact_table__pack :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return compact_table_raw__pack(cast(^Compact_Table_Raw) self)
    }

    // Pause tail swapping for this table only, independent of the
    // database-wide pause_packing.
    compact_table__pause_packing :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return compact_table_raw__pause_packing(cast(^Compact_Table_Raw) self)
    }

    // Resume tail swapping for this table and pack the holes it accumulated.
    compact_table__resume_packing :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return compact_table_raw__resume_packing(cast(^Compact_Table_Raw) self)
    }

    compact_table__remove_component :: proc(self: ^Compact_Table($T), eid: entity_id, loc:= #caller_location) -> Error {
        database__is_entity_correct(self.db, eid) or_return
       
        return compact_table_raw__remove_component(cast(^Compact_Table_Raw) self, eid, loc)
    }

    // Goes through subscribed views with filters and reruns filter for entity `eid` and its components
    compact_table__rerun_views_filters :: proc(self: ^Compact_Table($T), eid: entity_id) -> Error {
        database__is_entity_correct(self.db, eid) or_return

        for view in self.subscribers_with_filter.items {
            if !view.suspended do view__rerun_filter(view, eid) or_return
        }

        return nil
    }

    compact_table__len :: #force_inline proc "contextless" (self: ^Compact_Table($T)) -> int {
        return compact_table_raw__len(cast(^Compact_Table_Raw) self)
    }

    compact_table__cap :: #force_inline proc "contextless" (self: ^Compact_Table($T)) -> int {
        return compact_table_base__cap(self)
    }

    @(require_results)
    compact_table__get_component_by_entity :: proc (self: ^Compact_Table($T), eid: entity_id) -> ^T {
        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        return cast(^T) compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, eid)
    }

    @(require_results)
    compact_table__has_component :: proc (self: ^Compact_Table($T), eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix)) != oc_maps.RH_MAP32_DELETED
    }

    compact_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Compact_Table($T), #any_int row_number: int) -> entity_id {
        return compact_table_base__get_entity_by_row_number(self, row_number)
    }

    compact_table__memory_usage :: proc (self: ^Compact_Table($T)) -> int {    
       return compact_table_base__memory_usage(cast(^Compact_Table_Base) self)
    }
 
    // Component data for entity `eid`` is copied into `dest` table from `src` table and linked to enitity `eid`
    compact_table__copy_component :: proc(dest: ^Compact_Table($T), src: ^Compact_Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        src_component = compact_table__get_component_by_entity(src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found // component not found

        dest_component = compact_table__get_component_by_entity(dest, eid) // if it exists we will overwrite data
        if dest_component == nil {
            dest_component = add_component(dest, eid) or_return 
        }

        // copy data
        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    // Component data for entity `eid`` is moved into `dest` table from `src` table and linked to enitity `eid`
    compact_table__move_component :: proc(dest: ^Compact_Table($T), src: ^Compact_Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = copy_component(dest, src, eid) or_return

        remove_component(src, eid) or_return

        return dest_component, nil
    }

    compact_table__clear :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        compact_table_raw__clear((^Compact_Table_Raw)(self), true) or_return

        return nil
    }

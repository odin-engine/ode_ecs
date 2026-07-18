/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table_Base 

    @(private)
    Tiny_Table_Base :: struct {
        using shared: Shared_Table,

        type_info: ^runtime.Type_Info,
        rid_to_eid: [TINY_TABLE__ROW_CAP]entity_id,
        eid_to_ptr: oc_maps.Tt_Map(TINY_TABLE__MAP_CAP, rawptr),
        subscribers: [TINY_TABLE__VIEWS_CAP]^View,
        subscribers_excluding: [TINY_TABLE__VIEWS_CAP]^View, // views that EXCLUDE this table (see view__init excludes)
        len: int,

        // Deferred tail swap (db.tail_swap_paused) hole bookkeeping, see Table_Base
        holes_count: int,
        first_hole_rid: int,
    }

    @(private)
    tiny_table_base__is_valid :: proc (self: ^Tiny_Table_Base) -> bool {
        if self == nil do return false 
        if !shared_table__is_valid_internal(&self.shared) do return false 
        if self.type_info == nil do return false 

        return true 
    }

    @(private)
    tiny_table_base__init :: proc(self: ^Tiny_Table_Base, db: ^Database) -> Error {
        shared_table__init(&self.shared, Table_Type.Tiny_Table, db)

        // Unlike Table/Compact_Table, whose subscriber arrays are re-allocated
        // fresh on init, these fixed arrays survive terminate + re-init
        // (issue #8) and would keep notifying views from a previous life.
        self.subscribers = {}
        self.subscribers_excluding = {}

        self.id = database__attach_table(db, self) or_return
        self.state = Object_State.Normal

        return nil
    }

    @(private)
    tiny_table_base__terminate :: proc(self: ^Tiny_Table_Base) ->Error {

        for view in self.subscribers do if view != nil do view.state = Object_State.Invalid
        for view in self.subscribers_excluding do if view != nil do view.state = Object_State.Invalid

        // Clear this table's bit from all entities, see table_raw__terminate
        for &bits in self.db.eid_to_bits do uni_bits__remove(&bits, self.id)

        database__detach_table(self.db, self)

        shared_table__clear_state(&self.shared)

        return nil
    }

    @(private)
    tiny_table_base__attach_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if self.subscribers[i] == nil {
                self.subscribers[i] = view
                return nil 
            }
        }

        return oc.Core_Error.Container_Is_Full
    }

    @(private)
    tiny_table_base__detach_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if self.subscribers[i] == view {
                self.subscribers[i] = nil
                return nil
            }
        }

        return oc.Core_Error.Not_Found
    }

    @(private)
    tiny_table_base__attach_exclude_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if self.subscribers_excluding[i] == nil {
                self.subscribers_excluding[i] = view
                return nil
            }
        }

        return oc.Core_Error.Container_Is_Full
    }

    @(private)
    tiny_table_base__detach_exclude_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if self.subscribers_excluding[i] == view {
                self.subscribers_excluding[i] = nil
                return nil
            }
        }

        return oc.Core_Error.Not_Found
    }

    @(private)
    // See table_base__notify_excluding_views
    tiny_table_base__notify_excluding_views :: proc(self: ^Tiny_Table_Base, eid: entity_id) {
        if self.db.destroying_eid_ix == eid.ix do return
        for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
            view := self.subscribers_excluding[i]
            if view != nil && !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }
    }

    @(private)
    tiny_table_base__len :: #force_inline proc "contextless" (self: ^Tiny_Table_Base) -> int {
        return self.len
    }

    @(private)
    tiny_table_base__cap :: #force_inline proc "contextless" (self: ^Tiny_Table_Base) -> int {
        return TINY_TABLE__ROW_CAP
    }

    @(private)
    tiny_table_base__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Tiny_Table_Base, #any_int row_number: int) -> entity_id {
        return self.rid_to_eid[row_number]
    }

    @(private)
    tiny_table_base__get_component_by_entity :: proc (self: ^Tiny_Table_Base, eid: entity_id) -> rawptr {
        return oc_maps.tt_map__get(&self.eid_to_ptr, eid.ix)
    }

    @(private)
    tiny_table_base__memory_usage :: proc (self: ^Tiny_Table_Base) -> int {
        if self == nil || self.type_info == nil do return DELETED_INDEX
        return size_of(self^) + self.type_info.size * TINY_TABLE__ROW_CAP
    }

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table_Raw

    @(private)
    Tiny_Table_Raw :: struct {
        using base: Tiny_Table_Base,
        rows: [1]byte,
    }

    @(private)
    tiny_table_raw__remove_component :: proc(self: ^Tiny_Table_Raw, target_eid: entity_id) -> (err: Error) {
        if self.len <= 0 do return oc.Core_Error.Not_Found 

        target := oc_maps.tt_map__get(&self.eid_to_ptr,  target_eid.ix)

        // Check if component exists
        if target == nil do return oc.Core_Error.Not_Found

        T_size := self.type_info.size

        // Deferred tail swap: clear the component in place, leaving a hole.
        // Nothing moves, so component pointers stay stable while iterating.
        if shared_table__is_packing_paused(cast(^Shared_Table) self) {
            target_rid := int(uintptr(target) - uintptr(&self.rows[0])) / T_size

            oc_maps.tt_map__remove(&self.eid_to_ptr, target_eid.ix)
            self.rid_to_eid[target_rid].ix = DELETED_INDEX
            mem.zero(target, T_size)

            if target_rid == self.len - 1 {
                self.len -= 1
                // absorb trailing holes so they never need packing
                for self.len > 0 && is_not_set(self.rid_to_eid[self.len - 1]) {
                    self.len -= 1
                    self.holes_count -= 1
                }
            } else {
                self.holes_count += 1
                if target_rid < self.first_hole_rid do self.first_hole_rid = target_rid
            }

            for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                view := self.subscribers[i]
                if view != nil && !view.suspended do view__remove_record(view, target_eid)
            }

            database__remove_component(self.db, target_eid, self.id)
            tiny_table_base__notify_excluding_views(self, target_eid)
            return
        }

        tail_rid := self.len - 1
        tail_eid := self.rid_to_eid[tail_rid]

        assert(!is_not_set(tail_eid))

        tail :=oc_maps.tt_map__get(&self.eid_to_ptr, tail_eid.ix)
        assert(tail != nil)
        
        target_rid := int(uintptr(target) - uintptr(&self.rows[0])) / T_size

        // Replace removed component with tail
        if target == tail {
            // Remove indexes
            oc_maps.tt_map__remove(&self.eid_to_ptr, target_eid.ix)
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                view := self.subscribers[i]
                if view != nil && !view.suspended do view__remove_record(view, target_eid)
            }
        }
        else {
            tail_eid := self.rid_to_eid[tail_rid]
            assert(!is_not_set(tail_eid))

            // DATA COPY
            mem.copy(target, tail, T_size)

            // Update tail indexes
            oc_maps.tt_map__add(&self.eid_to_ptr, tail_eid.ix, target)
            oc_maps.tt_map__remove(&self.eid_to_ptr, target_eid.ix)

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            // Notify subscribed views
            for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                view := self.subscribers[i]
                if view != nil && !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component_rid(view, self, tail_eid, target_rid)
                }
            }
        }

        // Zero tail
        mem.zero(tail, T_size)
        self.len -= 1

        // Update eid_to_bits in db
        database__remove_component(self.db, target_eid, self.id)

        tiny_table_base__notify_excluding_views(self, target_eid)

        return
    }

    @(private)
    // Adds (or finds) the entity's row and returns a pointer to the component.
    // If `data` is not nil it is copied into the component BEFORE the subscriber
    // notifications run (view filters read component data through the row refs),
    // and it also overwrites the existing value on the Component_Already_Exist
    // path — "last write wins", used by Command_Buffer.
    // Contract: callers validate eid via database__is_entity_correct.
    // The raw pointer math below matches &Tiny_Table(T).rows[len] — guaranteed
    // by the offset_of #assert in tiny_table__init.
    tiny_table_raw__add_component :: proc(self: ^Tiny_Table_Raw, eid: entity_id, data: rawptr = nil) -> (component: rawptr, err: Error) {
        component = oc_maps.tt_map__get(&self.eid_to_ptr, eid.ix)

        // Check if component already exist
        if component == nil {
            // Capacity only matters when actually inserting — re-adding an
            // existing component on a full table must still report Component_Already_Exist
            if self.len >= TINY_TABLE__ROW_CAP do return nil, oc.Core_Error.Container_Is_Full

            T_size := self.type_info.size

            // Get component
            component = rawptr(uintptr(&self.rows[0]) + uintptr(self.len) * uintptr(T_size))
            if data != nil do mem.copy(component, data, T_size)

            // Update eid_to_ptr
            err = oc_maps.tt_map__add(&self.eid_to_ptr, eid.ix, component)
            if err != nil do return nil, err

            // Update rid_to_eid
            self.rid_to_eid[self.len] = eid

            // Update eid_to_bits in db
            database__add_component(self.db, eid, self.id)

            self.len += 1
        } else {
            if data != nil do mem.copy(component, data, self.type_info.size)
            err = API_Error.Component_Already_Exist
        }

        // Notify subscribed views. Also runs on the already-exists path on purpose: it
        // recovers a view membership that a previous add failed to register (e.g. view was at cap).
        for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
            view := self.subscribers[i]
            if view != nil && !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }

        // Views excluding this table lose the entity (no-op if it wasn't a member)
        for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
            view := self.subscribers_excluding[i]
            if view != nil && !view.suspended do view__remove_record(view, eid)
        }

        return
    }

    // clear data, nothing else
    @(private)
    tiny_table_raw__clear :: proc (self: ^Tiny_Table_Raw, zero_components := true) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        for i := 0; i < TINY_TABLE__ROW_CAP; i+=1 do self.rid_to_eid[i].ix = DELETED_INDEX

        oc_maps.tt_map__clear(&self.eid_to_ptr)
        
        if zero_components {
            mem.zero(&self.rows, self.type_info.size * self.len)
        }
        self.len = 0

        self.holes_count = 0
        self.first_hole_rid = max(int)

        return nil
    }

    // Compact holes left by removals made while tail swap was paused,
    // see table_raw__pack for the algorithm
    @(private)
    tiny_table_raw__pack :: proc(self: ^Tiny_Table_Raw) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.holes_count <= 0 {
            self.first_hole_rid = max(int)
            return nil
        }

        T_size := self.type_info.size
        rows := rawptr(&self.rows[0])

        front := self.first_hole_rid
        back := self.len - 1

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
            oc_maps.tt_map__add(&self.eid_to_ptr, moved_eid.ix, dst)
            mem.zero(src, T_size)

            for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                view := self.subscribers[i]
                if view != nil && !view.suspended do view__update_component_rid(view, self, moved_eid, front)
            }

            back -= 1
            front += 1
            self.holes_count -= 1
        }

        self.len = back + 1
        self.first_hole_rid = max(int)

        return nil
    }

    @(private)
    tiny_table_raw__pause_packing :: proc(self: ^Tiny_Table_Raw) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = true
        return nil
    }

    @(private)
    tiny_table_raw__resume_packing :: proc(self: ^Tiny_Table_Raw) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = false
        return tiny_table_raw__pack(self)
    }

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table

    Tiny_Table :: struct($T: typeid) {
        using base: Tiny_Table_Base, 
        rows: [TINY_TABLE__ROW_CAP]T,       
    }

    // Is table valid and ready to use (initialized and everything is ok)
    tiny_table__is_valid :: proc (self: ^Tiny_Table($T)) -> bool {
        if self == nil do return false 
        if !tiny_table_base__is_valid(&self.base) do return false

        return true
    }

    // Initialize table
    tiny_table__init :: proc(self: ^Tiny_Table($T), db: ^Database, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // table should be NOT_INITIALIZED
        }

        // Tiny_Table_Raw does pointer math assuming rows sits at the same offset
        // in both structs; an over-aligned T would pad rows to a different offset
        #assert(offset_of(Tiny_Table(T), rows) == offset_of(Tiny_Table_Raw, rows))

        if size_of(T) == 0 do return API_Error.Component_Size_Cannot_Be_Zero

        self.type_info = type_info_of(typeid_of(T))
        tiny_table_base__init(cast(^Tiny_Table_Base) self, db) or_return
        tiny_table_raw__clear(cast(^Tiny_Table_Raw) self, false) or_return

        return nil
    }

    // Terminate table
    tiny_table__terminate :: proc(self: ^Tiny_Table($T), loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.type_info.id == typeid_of(T), loc = loc)
            assert(self.db != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc) // table should be Normal
            assert(self.db.state == Object_State.Normal, loc = loc) // db should be Normal
        }

        tiny_table_base__terminate(cast(^Tiny_Table_Base) self) or_return

        return nil
    }

    // Add component for entity `eid`
    tiny_table__add_component :: proc(self: ^Tiny_Table($T), eid: entity_id) -> (component: ^T, err: Error) {
        err = database__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        c, aerr := tiny_table_raw__add_component(cast(^Tiny_Table_Raw) self, eid)
        return cast(^T) c, aerr
    }

    // Compact holes left by removals made while tail swap was paused
    // (see database__pause_packing). Callable mid-pause too.
    tiny_table__pack :: proc(self: ^Tiny_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return tiny_table_raw__pack(cast(^Tiny_Table_Raw) self)
    }

    // Pause tail swapping for this table only, independent of the
    // database-wide pause_packing.
    tiny_table__pause_packing :: proc(self: ^Tiny_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return tiny_table_raw__pause_packing(cast(^Tiny_Table_Raw) self)
    }

    // Resume tail swapping for this table and pack the holes it accumulated.
    tiny_table__resume_packing :: proc(self: ^Tiny_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return tiny_table_raw__resume_packing(cast(^Tiny_Table_Raw) self)
    }

    // Remove component for entity `eid`
    tiny_table__remove_component :: proc(self: ^Tiny_Table($T), eid: entity_id) -> (err: Error) {
        database__is_entity_correct(self.db, eid) or_return

        return tiny_table_raw__remove_component(cast(^Tiny_Table_Raw) self, eid)
    }

    // Goes through subscribed views with filters and reruns filter for entity `eid` and its components
    tiny_table__rerun_views_filters :: proc(self: ^Tiny_Table($T), eid: entity_id) -> Error {
        database__is_entity_correct(self.db, eid) or_return

        for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
            view := self.subscribers[i]
            if view != nil && !view.suspended {
                view__rerun_filter(view, eid) or_return
            }
        }

        return nil
    }

    @(require_results)
    tiny_table__get_component_by_entity :: proc (self: ^Tiny_Table($T), eid: entity_id) -> ^T {
        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        return cast(^T) tiny_table_base__get_component_by_entity(self, eid)
    }

    tiny_table__len :: #force_inline proc "contextless" (self: ^Tiny_Table($T)) -> int {
        return tiny_table_base__len(cast(^Tiny_Table_Base) self)
    }

    tiny_table__cap :: #force_inline proc "contextless" (self: ^Tiny_Table($T)) -> int {
        return tiny_table_base__cap(cast(^Tiny_Table_Base) self)
    }

    @(require_results)
    tiny_table__has_component :: proc (self: ^Tiny_Table($T), eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return oc_maps.tt_map__get(&self.eid_to_ptr, eid.ix) != nil
    }

    tiny_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Tiny_Table($T), #any_int row_number: int) -> entity_id {
        return tiny_table_base__get_entity_by_row_number(self, row_number)
    }

    tiny_table__memory_usage :: proc (self: ^Tiny_Table($T)) -> int {    
        return tiny_table_base__memory_usage(cast(^Tiny_Table_Base) self)
    }
 
    // Component data for entity `eid`` is copied into `dest` table from `src` table and linked to enitity `eid`
    tiny_table__copy_component :: proc(dest: ^Tiny_Table($T), src: ^Tiny_Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        src_component = tiny_table__get_component_by_entity(src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found // component not found

        dest_component = tiny_table__get_component_by_entity(dest, eid) // if it exists we will overwrite data
        if dest_component == nil {
            dest_component = tiny_table__add_component(dest, eid) or_return 
        }

        // copy data
        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    // Component data for entity `eid`` is moved into `dest` table from `src` table and linked to enitity `eid`
    tiny_table__move_component :: proc(dest: ^Tiny_Table($T), src: ^Tiny_Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = tiny_table__copy_component(dest, src, eid) or_return

        tiny_table__remove_component(src, eid) or_return

        return dest_component, nil
    }

    // Clear all data, nothing else
    tiny_table__clear :: proc(self: ^Tiny_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return tiny_table_raw__clear((^Tiny_Table_Raw)(self), true)
    }


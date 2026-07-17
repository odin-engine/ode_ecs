/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:slice"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Table_Base

    // eid_to_rid value for "entity has no component in this table"
    @(private)
    TABLE_NO_RID :: max(u32)

    // Base for Table
    @(private)
    Table_Base :: struct {
        using shared: Shared_Table,

        type_info: ^runtime.Type_Info,
        rid_to_eid: []entity_id,
        // eid.ix -> row id (TABLE_NO_RID when absent); u32 instead of a pointer
        // halves this entities_cap-sized array. The component address is derived
        // as &rows[rid] on lookup, so a tail swap patches a rid, not a pointer.
        eid_to_rid: []u32,

        // Group that owns this table (at most one), nil when not owned.
        // See group.odin: the owner keeps group members in the aligned prefix
        // [0, owner.len) of rows, so add/remove paths below notify it.
        owner: ^Group,

        cap: int,

        // Deferred tail swap (db.tail_swap_paused) hole bookkeeping.
        // A hole is a row with rid_to_eid[rid].ix == DELETED_INDEX inside [0, len).
        holes_count: int,
        first_hole_rid: int, // scan-start hint for pack; max(int) when no holes

        subscribers: oc.Dense_Arr(^View),
        subscribers_with_filter: oc.Dense_Arr(^View),
        subscribers_excluding: oc.Dense_Arr(^View), // views that EXCLUDE this table (see view__init excludes)
    }

    @(private)
    table_base__is_valid :: proc(self: ^Table_Base) -> bool {
        if self == nil do return false 
        if !shared_table__is_valid_internal(&self.shared) do return false 
        if self.type_info == nil do return false
        if self.rid_to_eid == nil do return false
        if self.eid_to_rid == nil do return false
        if self.cap <= 0 do return false
        if !oc.dense_arr__is_valid(&self.subscribers) do return false
        if !oc.dense_arr__is_valid(&self.subscribers_with_filter) do return false
        if !oc.dense_arr__is_valid(&self.subscribers_excluding) do return false

        return true
    }

    @(private)
    table_base__init :: proc(self: ^Table_Base, db: ^Database, cap: int, subscribers_cap: int = VIEWS_CAP) -> Error {
        shared_table__init(&self.shared, Table_Type.Table, db)

        // a re-init'd struct (issue #8) may carry an owner from its previous life
        self.owner = nil

        self.cap = cap

        self.rid_to_eid = make([]entity_id, cap, db.allocator) or_return

        // if you need to optimize memory usage, use Tiny_Table if your table cap is less or equal than TINY_TABLE__ROW_CAP,
        // and use Compact_Table if you want to save memory and your table cap is less than db.id_factory.cap / 4 but greater than TINY_TABLE__ROW_CAP
        // in other cases or if you do not care about memory usage, use Table
        // db.id_factory.cap is database entities cap
        self.eid_to_rid = make([]u32, db.id_factory.cap, db.allocator) or_return

        oc.dense_arr__init(&self.subscribers, subscribers_cap, db.allocator) or_return
        oc.dense_arr__init(&self.subscribers_with_filter, subscribers_cap, db.allocator) or_return
        oc.dense_arr__init(&self.subscribers_excluding, subscribers_cap, db.allocator) or_return

        return nil
    }

    @(private)
    table_base__terminate :: proc(self: ^Table_Base) -> Error {
        oc.dense_arr__terminate(&self.subscribers_excluding, self.db.allocator) or_return
        oc.dense_arr__terminate(&self.subscribers_with_filter, self.db.allocator) or_return
        oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return

        delete(self.rid_to_eid, self.db.allocator) or_return
        delete(self.eid_to_rid, self.db.allocator) or_return
       
        return nil
    }

    @(private)
    table_base__cap :: proc(self: ^Table_Base) -> int {
        return self.cap
    }

    @(private)
    table_base__attach_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        _, err := oc.dense_arr__add(&self.subscribers, view)
        if err != nil do return err

        if view.filter != nil {
            _, err = oc.dense_arr__add(&self.subscribers_with_filter, view)
            if err != nil do return err
        }

        return nil
    }

    @(private)
    table_base__detach_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        err := oc.dense_arr__remove_by_value(&self.subscribers, view)
        if err != nil do return err

        err = oc.dense_arr__remove_by_value(&self.subscribers_with_filter, view)
        if err == oc.Core_Error.Not_Found do return nil // not found is ok, it means view has no filter
        return err
    }

    @(private)
    table_base__attach_exclude_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        _, err := oc.dense_arr__add(&self.subscribers_excluding, view)
        return err
    }

    @(private)
    table_base__detach_exclude_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_excluding, view)
    }

    @(private)
    // After a component was removed from this table (eid_to_bits already updated),
    // a view excluding this table may newly match the entity. Skipped while the
    // entity itself is being destroyed — later removals would just evict it again.
    table_base__notify_excluding_views :: proc(self: ^Table_Base, eid: entity_id) {
        if self.db.destroying_eid_ix == eid.ix do return
        for view in self.subscribers_excluding.items {
            if !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }
    }

    @(private)
    table_base__memory_usage :: proc (self: ^Table_Base) -> int {    
        total := size_of(self^)

        if self.rid_to_eid != nil {
            total += size_of(self.rid_to_eid[0]) * len(self.rid_to_eid)
        }

        if self.eid_to_rid != nil {
            total += size_of(self.eid_to_rid[0]) * len(self.eid_to_rid)
        }

        // rows
        total += self.type_info.size * self.cap

        total += oc.dense_arr__memory_usage(&self.subscribers)
        total += oc.dense_arr__memory_usage(&self.subscribers_with_filter)
        total += oc.dense_arr__memory_usage(&self.subscribers_excluding)

        return total
    }

    @(private)
    table_base__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Table_Base, #any_int row_number: int) -> entity_id {
        return self.rid_to_eid[row_number]
    }

///////////////////////////////////////////////////////////////////////////////
// Table_Raw

    @(private)
    Table_Raw :: struct {
        using base: Table_Base,
        rows: []byte,
    }

    @(private)
    table_raw__rid_to_ptr :: #force_inline proc "contextless" (self: ^Table_Raw, #any_int rid: int) -> rawptr {
        return rawptr(uintptr(raw_data(self.rows)) + uintptr(rid) * uintptr(self.type_info.size))
    }

    @(private)
    // Swap two live rows (component data + both index directions) and notify
    // subscribed views of the address changes. Used by group maintenance
    // (group.odin); must not be called while tail swap is paused (rows must
    // stay put) — group hooks defer to a rebuild instead.
    table_raw__swap_rows :: proc(self: ^Table_Raw, #any_int rid_a: int, #any_int rid_b: int) #no_bounds_check {
        if rid_a == rid_b do return

        pa := table_raw__rid_to_ptr(self, rid_a)
        pb := table_raw__rid_to_ptr(self, rid_b)
        slice.ptr_swap_non_overlapping(pa, pb, self.type_info.size)

        eid_a := self.rid_to_eid[rid_a]
        eid_b := self.rid_to_eid[rid_b]
        self.rid_to_eid[rid_a] = eid_b
        self.rid_to_eid[rid_b] = eid_a
        self.eid_to_rid[eid_a.ix] = u32(rid_b)
        self.eid_to_rid[eid_b.ix] = u32(rid_a)

        for view in self.subscribers.items {
            if !view.suspended {
                view__update_component_address(view, self, eid_a, pb)
                view__update_component_address(view, self, eid_b, pa)
            }
        }
    }

    @(private)
    // #no_bounds_check: callers validate eid via database__is_entity_correct,
    // and len(eid_to_rid) == db.id_factory.cap
    table_raw__get_component_by_entity :: #force_inline proc "contextless" (self: ^Table_Raw, eid: entity_id) -> rawptr #no_bounds_check {
        rid := self.eid_to_rid[eid.ix]
        if rid == TABLE_NO_RID do return nil
        return table_raw__rid_to_ptr(self, rid)
    }

    @(private)
    table_raw__terminate :: proc(self: ^Table_Raw) -> Error {
        for view in self.subscribers.items do view.state = Object_State.Invalid
        for view in self.subscribers_excluding.items do view.state = Object_State.Invalid

        // A group missing one of its owned tables is meaningless — invalidate it
        // (it still owns its allocations; terminate it to release them).
        if self.owner != nil {
            self.owner.state = Object_State.Invalid
            self.owner = nil
        }

        // Clear this table's bit from all entities: the id may be reused by a
        // future table, and a stale bit would make destroy_entity fail on it.
        // (eid_to_bits is nil-len when the whole database is terminating.)
        for &bits in self.db.eid_to_bits do uni_bits__remove(&bits, self.id)

        database__detach_table(self.db, self)

        if self.rows != nil do delete(self.rows, self.db.allocator) or_return

        table_base__terminate(self) or_return

        shared_table__clear_state(&self.shared)

        return nil
    }

    @(private)
    // Is packing (tail swap) currently deferred for this table — a table
    // owned by a Group defers to the group's own pause state (rows must move
    // in lock-step across every table the group owns); a standalone table
    // checks the database-wide flag or its own pause_packing.
    table_raw__is_packing_paused :: #force_inline proc "contextless" (self: ^Table_Raw) -> bool {
        if self.owner != nil do return group__is_packing_paused(self.owner)
        return shared_table__is_packing_paused(cast(^Shared_Table) self)
    }

    @(private)
    // #no_bounds_check: callers validate target_eid (len(eid_to_rid) == db.id_factory.cap);
    // all row indexes derive from raw.len < cap or from the rid index
    table_raw__remove_component :: proc(self: ^Table_Raw, target_eid: entity_id, loc:= #caller_location) -> (err: Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found

        target_rid := self.eid_to_rid[target_eid.ix]

        // Check if component exists
        if target_rid == TABLE_NO_RID do return oc.Core_Error.Not_Found

        T_size := self.type_info.size
        target := table_raw__rid_to_ptr(self, target_rid)

        // Group maintenance: a member losing an owned component leaves the group —
        // swap its rows out of the prefix (in every owned table) before this
        // table's own tail swap runs. Members sit at rid < owner.len by invariant.
        // While tail swap is paused rows must not move: mark dirty, rebuild on resume.
        if self.owner != nil && int(target_rid) < self.owner.len {
            if table_raw__is_packing_paused(self) {
                self.owner.dirty = true
            } else {
                group__swap_out(self.owner, target_eid)
                target_rid = self.eid_to_rid[target_eid.ix]
                target = table_raw__rid_to_ptr(self, target_rid)
            }
        }

        // Deferred tail swap: clear the component in place, leaving a hole.
        // Nothing moves, so component pointers stay stable while iterating.
        if table_raw__is_packing_paused(self) {
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID
            self.rid_to_eid[target_rid].ix = DELETED_INDEX
            mem.zero(target, T_size)

            if int(target_rid) == raw.len - 1 {
                raw.len -= 1
                // absorb trailing holes so they never need packing
                for raw.len > 0 && is_deleted(self.rid_to_eid[raw.len - 1]) {
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
            table_base__notify_excluding_views(self, target_eid)
            return
        }

        tail_rid := raw.len - 1
        tail_eid := self.rid_to_eid[tail_rid]

        assert(!is_deleted(tail_eid))

        tail := table_raw__rid_to_ptr(self, tail_rid)

        // Replace removed component with tail
        if int(target_rid) == tail_rid {
            // Remove indexes
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
            }
        }
        else {
            // DATA COPY
            mem.copy(target, tail, T_size)

            // Update tail indexes
            self.eid_to_rid[tail_eid.ix] = target_rid
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            // Notify subscribed views
            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component_address(view, self, tail_eid, rawptr(target))
                }
            }
        }

        // Zero tail
        mem.zero(tail, T_size)
        raw.len -= 1

        // Update eid_to_bits in db
        database__remove_component(self.db, target_eid, self.id)

        table_base__notify_excluding_views(self, target_eid)

        return
    }

    @(private)
    // Adds (or finds) the entity's row and returns a pointer to the component.
    // If `data` is not nil it is copied into the component BEFORE the group hook
    // and subscriber notifications run (view filters read component data through
    // the row refs), and it also overwrites the existing value on the
    // Component_Already_Exist path — "last write wins", used by Command_Buffer.
    // #no_bounds_check: callers validate eid via database__is_entity_correct,
    // len(eid_to_rid) == db.id_factory.cap; row indexes derive from raw.len < cap
    table_raw__add_component :: proc(self: ^Table_Raw, eid: entity_id, data: rawptr = nil) -> (component: rawptr, err: Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        rid := self.eid_to_rid[eid.ix]

        // Check if component already exist
        if rid == TABLE_NO_RID {
            // Capacity only matters when actually inserting — re-adding an
            // existing component on a full table must still report Component_Already_Exist
            if raw.len >= self.cap do return nil, oc.Core_Error.Container_Is_Full

            // Get component
            component = table_raw__rid_to_ptr(self, raw.len)
            if data != nil do mem.copy(component, data, self.type_info.size)

            // Update eid_to_rid
            self.eid_to_rid[eid.ix] = u32(raw.len)

            // Update rid_to_eid
            self.rid_to_eid[raw.len] = eid

            // Update eid_to_bits in db
            database__add_component(self.db, eid, self.id)

            raw.len += 1

            // Group maintenance: if the entity now has every owned component, swap
            // its rows into the group prefix (deferred while tail swap is paused).
            // Before the subscriber loop so views record the final addresses.
            if self.owner != nil {
                group__on_add(self.owner, eid)
                // the swap may have moved the new row — re-derive the returned pointer
                component = table_raw__rid_to_ptr(self, self.eid_to_rid[eid.ix])
            }
        } else {
            component = table_raw__rid_to_ptr(self, rid)
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

    // Compact holes left by removals made while tail swap was paused: each hole is
    // filled with the current last live row — exactly holes_count moves, the minimum
    // possible (rows are unordered, so order does not need to be preserved).
    @(private)
    table_raw__pack :: proc(self: ^Table_Raw) -> Error {
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
            for back >= 0 && is_deleted(self.rid_to_eid[back]) {
                back -= 1
                self.holes_count -= 1
            }
            if self.holes_count <= 0 do break

            // next hole from the front; guaranteed to exist below back
            for !is_deleted(self.rid_to_eid[front]) do front += 1

            // move the last live row into the hole
            dst := rawptr(uintptr(rows) + uintptr(front) * uintptr(T_size))
            src := rawptr(uintptr(rows) + uintptr(back)  * uintptr(T_size))
            mem.copy(dst, src, T_size)

            moved_eid := self.rid_to_eid[back]
            self.rid_to_eid[front] = moved_eid
            self.rid_to_eid[back].ix = DELETED_INDEX
            self.eid_to_rid[moved_eid.ix] = u32(front)
            mem.zero(src, T_size)

            for view in self.subscribers.items {
                if !view.suspended do view__update_component_address(view, self, moved_eid, dst)
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
    table_raw__pause_packing :: proc(self: ^Table_Raw) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.owner != nil do return API_Error.Cannot_Pause_Table_Owned_By_Group

        self.pause_packing = true
        return nil
    }

    @(private)
    table_raw__resume_packing :: proc(self: ^Table_Raw) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.owner != nil do return API_Error.Cannot_Pause_Table_Owned_By_Group

        self.pause_packing = false
        return table_raw__pack(self)
    }

    table_raw__len :: #force_inline proc "contextless" (self: ^Table_Raw) -> int {
        return (^runtime.Raw_Slice)(&self.rows).len
    }

    // clear data, nothing else
    table_raw__clear :: proc (self: ^Table_Raw, zero_components := true) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.rid_to_eid != nil {
            for i := 0; i < len(self.rid_to_eid); i+=1 do self.rid_to_eid[i].ix = DELETED_INDEX
        }

        slice.fill(self.eid_to_rid, TABLE_NO_RID)

        // an empty owned table means no entity can match the owner group
        if self.owner != nil {
            self.owner.len = 0
            self.owner.dirty = false
        }
       
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
// Table

    // Components table
    Table :: struct($T: typeid) {
        using base: Table_Base,
        // table_record_id => component
        rows: []T,     
    }

    table__is_valid :: proc(self: ^Table($T)) -> bool {
        if self == nil do return false 
        if !table_base__is_valid(self) do return false 
        if self.rows == nil do return false 

        return true
    }

    table__init :: proc(self: ^Table($T), db: ^Database, cap: int, subscribers_cap: int = VIEWS_CAP, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // should be NOT_INITIALIZED
            assert(cap > 0, loc = loc)
            assert(cap <= db.id_factory.cap, loc = loc) // cannot be larger than entities_cap
            assert(cap < int(max(u32)), loc = loc) // row ids must fit the u32 eid_to_rid index
        }

        if size_of(T) == 0 do return API_Error.Component_Size_Cannot_Be_Zero

        self.type_info = type_info_of(typeid_of(T))

        table_base__init(&self.base, db, cap, subscribers_cap) or_return 

        self.rows = make([]T, cap, db.allocator) or_return
        
        self.id = database__attach_table(db, self) or_return

        self.state = Object_State.Normal

        table_raw__clear(cast(^Table_Raw)self) or_return 

        return nil
    }

    table__terminate :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.type_info.id == typeid_of(T))
            assert(self.db != nil)
        }

        table_raw__terminate(cast(^Table_Raw) self) or_return

        return nil
    }
    
    table__add_component :: proc(self: ^Table($T), eid: entity_id) -> (component: ^T, err: Error) {
        err = database__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        c, aerr := table_raw__add_component(cast(^Table_Raw) self, eid)
        return cast(^T) c, aerr
    }

    // Compact holes left by removals made while tail swap was paused
    // (see database__pause_packing). Callable mid-pause too.
    table__pack :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return table_raw__pack(cast(^Table_Raw) self)
    }

    // Pause tail swapping for this table only, independent of the
    // database-wide pause_packing. Rejected with
    // API_Error.Cannot_Pause_Table_Owned_By_Group if the table is owned by a
    // Group — pause/resume the Group instead (group__pause_packing), since
    // group membership requires every owned table to move rows in lock-step.
    table__pause_packing :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return table_raw__pause_packing(cast(^Table_Raw) self)
    }

    // Resume tail swapping for this table and pack the holes it accumulated.
    table__resume_packing :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return table_raw__resume_packing(cast(^Table_Raw) self)
    }

    table__remove_component :: proc(self: ^Table($T), eid: entity_id, loc:= #caller_location) -> Error {
        database__is_entity_correct(self.db, eid) or_return
       
        return table_raw__remove_component(cast(^Table_Raw) self, eid, loc)
    }

    // Goes through subscribed views with filters and reruns filter for entity `eid` and its components
    table__rerun_views_filters :: proc(self: ^Table($T), eid: entity_id) -> Error {
        database__is_entity_correct(self.db, eid) or_return

        for view in self.subscribers_with_filter.items {
            if !view.suspended do view__rerun_filter(view, eid) or_return
        }

        return nil
    }

    table__len :: #force_inline proc "contextless" (self: ^Table($T)) -> int {
        return table_raw__len(cast(^Table_Raw) self)
    }

    table__cap :: #force_inline proc "contextless" (self: ^Table($T)) -> int {
        return table_base__cap(self)
    }

    @(require_results)
    table__get_component_by_entity :: proc (self: ^Table($T), eid: entity_id) -> ^T {
        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        #no_bounds_check {
            rid := self.eid_to_rid[eid.ix]
            if rid == TABLE_NO_RID do return nil
            return &self.rows[rid]
        }
    }

    @(require_results)
    table__has_component :: proc (self: ^Table($T), eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return self.eid_to_rid[eid.ix] != TABLE_NO_RID
    }

    table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Table($T), #any_int row_number: int) -> entity_id {
        return table_base__get_entity_by_row_number(self, row_number)
    }

    table__memory_usage :: proc (self: ^Table($T)) -> int {    
       return table_base__memory_usage(cast(^Table_Base) self)
    }
 
    // Component data for entity `eid`` is copied into `dest` table from `src` table and linked to enitity `eid`
    table__copy_component :: proc(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        src_component = table__get_component_by_entity(src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found // component not found

        dest_component = table__get_component_by_entity(dest, eid) // if it exists we will overwrite data
        if dest_component == nil {
            dest_component = add_component(dest, eid) or_return 
        }

        // copy data
        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    // Component data for entity `eid`` is moved into `dest` table from `src` table and linked to enitity `eid`
    table__move_component :: proc(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = copy_component(dest, src, eid) or_return

        remove_component(src, eid) or_return

        return dest_component, nil
    }

    table__clear :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        table_raw__clear((^Table_Raw)(self), true) or_return

        return nil
    }



/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:math"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"


///////////////////////////////////////////////////////////////////////////////
// Tag_Table

    Tag_Table :: struct {
        using shared: Shared_Table,

        rows: []entity_id,                          // rid_to_eid
        eid_to_rid: oc_maps.Rh_Map32,               // eid.ix -> row id in rows (8-byte items, see Compact_Table)

        cap: int,

        // Deferred tail swap (db.tail_swap_paused) hole bookkeeping.
        // A hole is a row with rows[rid].ix == DELETED_INDEX inside [0, len).
        holes_count: int,
        first_hole_rid: int, // scan-start hint for pack; max(int) when no holes

        subscribers: oc.Dense_Arr(^View),
        subscribers_excluding: oc.Dense_Arr(^View), // views that EXCLUDE this table (see view__init excludes)
    }

    // It table valid and ready to use (initialized and everything is ok)
    tag_table__is_valid :: proc(self: ^Tag_Table) -> bool {
        if self == nil do return false 
        if !shared_table__is_valid_internal(&self.shared) do return false 
        if self.rows == nil do return false
        if !oc_maps.rh_map32__is_valid(&self.eid_to_rid) do return false
        if self.cap <= 0 do return false 
        if !oc.dense_arr__is_valid(&self.subscribers) do return false
        if !oc.dense_arr__is_valid(&self.subscribers_excluding) do return false

        return true
    }

    tag_table__init :: proc(self: ^Tag_Table, db: ^Database, cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // should be NOT_INITIALIZED
            assert(cap > 0, loc = loc)
            assert(cap <= db.overbase.id_factory.cap, loc = loc) // cannot be larger than entities_cap
            assert(db.overbase.id_factory.cap < int(max(u32)), loc = loc) // eid.ix keys must fit the u32 rid map
        }

        shared_table__init(&self.shared, Table_Type.Tag_Table, db)
        self.cap = cap

        oc.dense_arr__init(&self.subscribers, VIEWS_CAP, db.allocator) or_return
        oc.dense_arr__init(&self.subscribers_excluding, VIEWS_CAP, db.allocator) or_return

        self.rows = make([]entity_id, self.cap, db.allocator) or_return
        // load factor 0.5 and make it power of two
        oc_maps.rh_map32__init(&self.eid_to_rid, math.next_power_of_two(self.cap * 2), db.allocator) or_return

        self.id = database__attach_table(db, self) or_return
        self.state = Object_State.Normal

        tag_table__clear(self) or_return

        return nil
    }

    tag_table__terminate :: proc(self: ^Tag_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        for view in self.subscribers.items do view.state = Object_State.Invalid
        for view in self.subscribers_excluding.items do view.state = Object_State.Invalid

        // Clear this table's bit from all entities, see table_raw__terminate
        for &bits in self.db.eid_to_bits do uni_bits__remove(&bits, self.id)

        oc.dense_arr__terminate(&self.subscribers_excluding, self.db.allocator) or_return
        oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return
        oc_maps.rh_map32__terminate(&self.eid_to_rid, self.db.allocator) or_return

        delete(self.rows, self.db.allocator) or_return

        database__detach_table(self.db, self)

        shared_table__clear_state(&self.shared)

        return nil
    }

    // Memory usage in bytes
    tag_table__memory_usage :: proc (self: ^Tag_Table) -> int {  
        total := size_of(self^)

        if self.rows != nil {
            total += size_of(self.rows[0]) * len(self.rows)
        }

        total += oc_maps.rh_map32__memory_usage(&self.eid_to_rid)

        return total
    }

    tag_table__len :: #force_inline proc "contextless" (self: ^Tag_Table) -> int {
        return oc_maps.rh_map32__len(&self.eid_to_rid)
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

        if oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix)) != oc_maps.RH_MAP32_DELETED do return nil // already added

        // Capacity only matters when actually inserting — re-adding an
        // existing tag on a full table must still be a no-op (see the same
        // ordering in table__add_component)
        if raw.len >= self.cap do return oc.Core_Error.Container_Is_Full

        // Update rows
        #no_bounds_check {
            self.rows[raw.len] = eid
        }

        // Add eid_to_rid
        oc_maps.rh_map32__add(&self.eid_to_rid, u32(eid.ix), u32(raw.len)) or_return

        // Update eid_to_bits in db
        database__add_component(self.db, eid, self.id)

        raw.len += 1

        // Notify subscribed views
        for view in self.subscribers.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        // Views excluding this table lose the entity (no-op if it wasn't a member)
        for view in self.subscribers_excluding.items {
            if !view.suspended do view__remove_record(view, eid)
        }

        return nil
    }

    tag_table__remove_tag :: proc(self: ^Tag_Table, target_eid: entity_id, loc:= #caller_location) -> (err: Error) {
        database__is_entity_correct(self.db, target_eid) or_return

        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found

        // One lookup serves both the existence check and the removal below —
        // remove_at reuses the slot index instead of re-probing the key
        target_rid_u, target_slot := oc_maps.rh_map32__get_with_index(&self.eid_to_rid, u32(target_eid.ix))

        // Check if exists
        if target_slot == oc.DELETED_INDEX do return oc.Core_Error.Not_Found

        target_rid := int(target_rid_u)

        // Deferred tail swap: clear the tag in place, leaving a hole.
        // Nothing moves, so nothing needs to stay stable while iterating.
        if shared_table__is_packing_paused(cast(^Shared_Table) self) {
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)

            self.rows[target_rid].ix = DELETED_INDEX

            if target_rid == raw.len - 1 {
                raw.len -= 1
                // absorb trailing holes so they never need packing
                for raw.len > 0 && is_not_set(self.rows[raw.len - 1]) {
                    raw.len -= 1
                    self.holes_count -= 1
                }
            } else {
                self.holes_count += 1
                if target_rid < self.first_hole_rid do self.first_hole_rid = target_rid
            }

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
            }

            // Update eid_to_bits in db
            database__remove_component(self.db, target_eid, self.id)
            tag_table__notify_excluding_views(self, target_eid)

            return nil
        }

        tail_rid := raw.len - 1

        if target_rid == tail_rid {
            // Remove indexes
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)

            self.rows[tail_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
            }

        } else {
            tail_eid := self.rows[tail_rid]
            assert(!is_not_set(tail_eid))

            // Update tail indexes (value-only update — slots don't move, so
            // target_slot stays valid for the remove_at)
            oc_maps.rh_map32__update(&self.eid_to_rid, u32(tail_eid.ix), target_rid_u)
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)

            self.rows[target_rid] = tail_eid // copy eid from tail
            self.rows[tail_rid].ix = DELETED_INDEX

            // Notify subscribed views
            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    // tag columns carry no component data, but the notification also
                    // feeds the dense safety net — the moved tag now occupies the
                    // removed row's id
                    view__update_component_rid(view, self, tail_eid, target_rid)
                }
            }
        }

        raw.len -= 1

        // Update eid_to_bits in db
        database__remove_component(self.db, target_eid, self.id)

        tag_table__notify_excluding_views(self, target_eid)

        return nil
    }

    tag_table__remove_component :: tag_table__remove_tag

    @(require_results)
    tag_table__has_tag :: proc (self: ^Tag_Table, eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix)) != oc_maps.RH_MAP32_DELETED
    }

    // Compact holes left by removals made while tail swap was paused
    // (see database__pause_packing). Callable mid-pause too.
    tag_table__pack :: proc(self: ^Tag_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.holes_count <= 0 {
            self.first_hole_rid = max(int)
            return nil
        }

        raw := (^runtime.Raw_Slice)(&self.rows)

        front := self.first_hole_rid
        back := raw.len - 1

        for self.holes_count > 0 {
            // shrink span past trailing holes
            for back >= 0 && is_not_set(self.rows[back]) {
                back -= 1
                self.holes_count -= 1
            }
            if self.holes_count <= 0 do break

            // next hole from the front; guaranteed to exist below back
            for !is_not_set(self.rows[front]) do front += 1

            // move the last live row's tag into the hole
            moved_eid := self.rows[back]
            self.rows[front] = moved_eid
            self.rows[back].ix = DELETED_INDEX

            oc_maps.rh_map32__update(&self.eid_to_rid, u32(moved_eid.ix), u32(front))

            back -= 1
            front += 1
            self.holes_count -= 1
        }

        raw.len = back + 1
        self.first_hole_rid = max(int)

        return nil
    }

    // Pause tail swapping for this table only, independent of the
    // database-wide pause_packing.
    tag_table__pause_packing :: proc(self: ^Tag_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = true
        return nil
    }

    // Resume tail swapping for this table and pack the holes it accumulated.
    tag_table__resume_packing :: proc(self: ^Tag_Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = false
        return tag_table__pack(self)
    }

    tag_table__clear :: proc (self: ^Tag_Table) -> Error {
        if !tag_table__is_valid(self) do return API_Error.Object_Invalid

        if self.rows != nil {
            for i := 0; i < len(self.rows); i+=1 do self.rows[i].ix = DELETED_INDEX
        }

        (^runtime.Raw_Slice)(&self.rows).len = 0

        oc_maps.rh_map32__clear(&self.eid_to_rid)

        self.holes_count = 0
        self.first_hole_rid = max(int)

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

    @(private)
    tag_table__attach_exclude_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        _, err := oc.dense_arr__add(&self.subscribers_excluding, view)
        return err
    }

    @(private)
    tag_table__detach_exclude_subscriber :: proc(self: ^Tag_Table, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_excluding, view)
    }

    @(private)
    // See table_base__notify_excluding_views
    tag_table__notify_excluding_views :: proc(self: ^Tag_Table, eid: entity_id) {
        if self.db.destroying_eid_ix == eid.ix do return
        for view in self.subscribers_excluding.items {
            if !view.suspended && view_entity_match(view, eid) do view__add_record(view, eid)
        }
    }
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

///////////////////////////////////////////////////////////////////////////////
// Table_Base

    // eid_to_rid value for "entity has no component in this table"
    @(private)
    TABLE_NO_RID :: max(u32)

    @(private)
    Table_Base :: struct {
        using shared: Shared_Table,

        type_info: ^runtime.Type_Info,
        rid_to_eid: []entity_id,
        // eid.ix -> row id (TABLE_NO_RID when absent); u32 instead of a pointer
        // halves this entities_cap-sized array. Component address is &rows[rid].
        eid_to_rid: []u32,

        // Group that owns this table (at most one), nil when not owned.
        // Owner keeps group members in the aligned prefix [0, owner.len) of rows.
        owner: ^Group,

        cap: int,

        // Deferred tail swap (db.tail_swap_paused) hole bookkeeping.
        // A hole is a row with rid_to_eid[rid].ix == DELETED_INDEX inside [0, len).
        holes_count: int,
        first_hole_rid: int, // scan-start hint for pack; max(int) when no holes

        // Sizes the subscriber lists below, lazily allocated on first attach.
        subscribers_cap: int,

        subscribers: oc.Dense_Arr(^View),
        subscribers_with_filter: oc.Dense_Arr(^View),
        subscribers_excluding: oc.Dense_Arr(^View), // views that EXCLUDE this table (see view__init excludes)
        subscribers_any_of: oc.Dense_Arr(^View), // views that any_of this table (see view__init any_of)

        // Sizes sync_watchers, lazily allocated on first sync_register regardless of SYNC_ENABLED.
        sync_channels_cap: int,
        sync_watchers: oc.Dense_Arr(^Sync_Channel),
    }

    @(private)
    table_base__is_valid :: proc(self: ^Table_Base) -> bool {
        if self == nil do return false
        if !shared_table__is_valid_internal(&self.shared) do return false
        if self.type_info == nil do return false
        if self.rid_to_eid == nil do return false
        if self.eid_to_rid == nil do return false
        if self.cap <= 0 do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_with_filter) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_excluding) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_any_of) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.sync_watchers) do return false

        return true
    }

    @(private)
    table_base__init :: proc(self: ^Table_Base, db: ^Database, cap: int, subscribers_cap: int = SUBSCRIBERS_CAP, sync_channels_cap: int = SYNC_CHANNELS_CAP) -> Error {
        shared_table__init(&self.shared, Table_Type.Table, db)

        // a re-init'd struct (issue #8) may carry an owner from its previous life
        self.owner = nil

        self.cap = cap

        self.rid_to_eid = make([]entity_id, cap, db.allocator) or_return

        // Use Tiny_Table when cap <= TINY_TABLE__ROW_CAP, Compact_Table when cap is
        // small relative to db.overbase.id_factory.cap (entities cap), else Table.
        self.eid_to_rid = make([]u32, db.overbase.id_factory.cap, db.allocator) or_return

        self.subscribers_cap = subscribers_cap
        self.sync_channels_cap = sync_channels_cap
        // subscriber lists and sync_watchers are allocated lazily, on first attach.

        return nil
    }

    @(private)
    table_base__terminate :: proc(self: ^Table_Base) -> Error {
        if self.sync_watchers.items != nil do oc.dense_arr__terminate(&self.sync_watchers, self.db.allocator) or_return
        if self.subscribers_any_of.items != nil do oc.dense_arr__terminate(&self.subscribers_any_of, self.db.allocator) or_return
        if self.subscribers_excluding.items != nil do oc.dense_arr__terminate(&self.subscribers_excluding, self.db.allocator) or_return
        if self.subscribers_with_filter.items != nil do oc.dense_arr__terminate(&self.subscribers_with_filter, self.db.allocator) or_return
        if self.subscribers.items != nil do oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return

        delete(self.rid_to_eid, self.db.allocator) or_return
        delete(self.eid_to_rid, self.db.allocator) or_return

        return nil
    }

    @(private)
    table_base__cap :: #force_inline proc "contextless" (self: ^Table_Base) -> int {
        return self.cap
    }

    @(private)
    table_base__attach_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        if self.subscribers.items == nil do oc.dense_arr__init(&self.subscribers, self.subscribers_cap, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers, view, self.db.allocator)
        if err != nil do return err

        if view.filter != nil {
            if self.subscribers_with_filter.items == nil do oc.dense_arr__init(&self.subscribers_with_filter, self.subscribers_cap, self.db.allocator) or_return

            _, err = oc.dense_arr__add_growing(&self.subscribers_with_filter, view, self.db.allocator)
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
        if self.subscribers_excluding.items == nil do oc.dense_arr__init(&self.subscribers_excluding, self.subscribers_cap, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers_excluding, view, self.db.allocator)
        return err
    }

    @(private)
    table_base__detach_exclude_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_excluding, view)
    }

    @(private)
    table_base__attach_any_of_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        if self.subscribers_any_of.items == nil do oc.dense_arr__init(&self.subscribers_any_of, self.subscribers_cap, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers_any_of, view, self.db.allocator)
        return err
    }

    @(private)
    table_base__detach_any_of_subscriber :: proc(self: ^Table_Base, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_any_of, view)
    }

    @(private)
    table_base__attach_sync_channel :: proc(self: ^Table_Base, ch: ^Sync_Channel) -> Error {
        when !SYNC_ENABLED do return API_Error.Sync_Feature_Disabled

        if self.sync_watchers.items == nil do oc.dense_arr__init(&self.sync_watchers, self.sync_channels_cap, self.db.allocator) or_return
        _, err := oc.dense_arr__add(&self.sync_watchers, ch)
        return err
    }

    @(private)
    table_base__detach_sync_channel :: proc(self: ^Table_Base, ch: ^Sync_Channel) -> Error {
        when !SYNC_ENABLED do return API_Error.Sync_Feature_Disabled

        return oc.dense_arr__remove_by_value(&self.sync_watchers, ch)
    }

    @(private)
    // After a component is removed, a view excluding this table may newly match the
    // entity. Skipped while the entity is being destroyed — later removals would just
    // evict it again. #force_inline collapses the common empty-subscribers case to a
    // single length check instead of a call/return.
    table_base__notify_excluding_views :: #force_inline proc(self: ^Table_Base, eid: entity_id) {
        if self.db.destroying_eid_ix == eid.ix do return
        for view in self.subscribers_excluding.items {
            if !view.suspended && view__components_match(view, eid) {
                when VALIDATIONS {
                    // An excluding view's cap is derived from ITS included tables,
                    // not from this table — a full one silently drops the entity
                    aerr := view__add_record(view, eid)
                    assert(aerr != API_Error.Cannot_Add_Record_To_View_Container_Is_Full, "excluding view is full — entity silently dropped, raise the view's included tables' caps")
                } else {
                    view__add_record(view, eid)
                }
            }
        }
    }

    @(private)
    // After a component is removed, an any_of view may have lost its only qualifying
    // table for this entity — recheck and evict if so. Only ever removes (a no-op if
    // not a member), so needs no destroying_eid_ix guard, unlike notify_excluding_views.
    table_base__notify_any_of_views :: #force_inline proc(self: ^Table_Base, eid: entity_id) {
        for view in self.subscribers_any_of.items {
            if !view.suspended && !view__components_match(view, eid) do view__remove_record(view, eid)
        }
    }

    @(private)
    // A component was added — every watching Sync_Channel gets a structural "added"
    // event AND has eid marked touched, so its initial value transmits even without
    // a follow-up get_component_mut call.
    table_base__notify_sync_add :: #force_inline proc(self: ^Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            for ch in self.sync_watchers.items {
                sync_channel__notify_structural(ch, self.id, eid, true)
                sync_channel__mark_touched(ch, self.id, eid)
            }
        }
    }

    @(private)
    // A component was removed — every watching Sync_Channel gets a structural
    // "removed" event, which also zeroes that channel's shadow slot for eid.
    table_base__notify_sync_remove :: #force_inline proc(self: ^Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            for ch in self.sync_watchers.items {
                sync_channel__notify_structural(ch, self.id, eid, false)
            }
        }
    }

    @(private)
    // Mark eid touched in every watching Sync_Channel so the next collect_delta diffs it.
    table_base__mark_touched :: #force_inline proc(self: ^Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            for ch in self.sync_watchers.items {
                sync_channel__mark_touched(ch, self.id, eid)
            }
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
        total += oc.dense_arr__memory_usage(&self.subscribers_any_of)
        total += oc.dense_arr__memory_usage(&self.sync_watchers)

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
        return table_raw__rid_to_ptr_sized(self, rid, self.type_info.size)
    }

    // elem_size is an explicit parameter so a #force_inline caller that knows T at
    // compile time folds the multiply into a shift; type-erased callers just pass
    // self.type_info.size and get identical codegen.
    @(private)
    table_raw__rid_to_ptr_sized :: #force_inline proc "contextless" (self: ^Table_Raw, #any_int rid: int, elem_size: int) -> rawptr {
        return rawptr(uintptr(raw_data(self.rows)) + uintptr(rid) * uintptr(elem_size))
    }

    @(private)
    // Swap two live rows (component data + both index directions) and notify
    // subscribed views of the new row ids. Used by group maintenance; must not be
    // called while tail swap is paused — group hooks defer to a rebuild instead.
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
                view__update_component_rid(view, self, eid_a, rid_b)
                view__update_component_rid(view, self, eid_b, rid_a)
            } else {
                view__missed_update_for_member(view, eid_a)
                view__missed_update_for_member(view, eid_b)
            }
        }
    }

    @(private)
    // #no_bounds_check: callers validate eid via database__is_entity_correct,
    // and len(eid_to_rid) == db.overbase.id_factory.cap
    table_raw__get_component_by_entity :: #force_inline proc "contextless" (self: ^Table_Raw, eid: entity_id) -> rawptr #no_bounds_check {
        rid := self.eid_to_rid[eid.ix]
        if rid == TABLE_NO_RID do return nil
        return table_raw__rid_to_ptr(self, rid)
    }

    @(private)
    table_raw__terminate :: proc(self: ^Table_Raw) -> Error {
        for view in self.subscribers.items do view.state = Object_State.Invalid
        for view in self.subscribers_excluding.items do view.state = Object_State.Invalid
        for view in self.subscribers_any_of.items do view.state = Object_State.Invalid
        for ch in self.sync_watchers.items do sync_channel__on_table_terminated(ch, self.id)

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
    // Is packing (tail swap) currently deferred for this table — an owned table
    // defers to the group's pause state (rows must move in lock-step); a standalone
    // table checks the database-wide flag or its own pause_packing.
    table_raw__is_packing_paused :: #force_inline proc "contextless" (self: ^Table_Raw) -> bool {
        if self.owner != nil do return group__is_packing_paused(self.owner)
        return shared_table__is_packing_paused(cast(^Shared_Table) self)
    }

    @(private)
    // Type-erased entry point (Command_Buffer replay, database-wide sweeps,
    // Group — none of which have T at compile time): reads self.type_info.size.
    table_raw__remove_component :: proc(self: ^Table_Raw, target_eid: entity_id, loc:= #caller_location) -> (err: Error) {
        return table_raw__remove_component_sized(self, target_eid, self.type_info.size, loc)
    }

    @(private)
    // See table_raw__add_component_sized for why elem_size is an explicit
    // parameter instead of a self.type_info.size field read.
    // #no_bounds_check: callers validate target_eid (len(eid_to_rid) == db.overbase.id_factory.cap);
    // all row indexes derive from raw.len < cap or from the rid index
    table_raw__remove_component_sized :: #force_inline proc(self: ^Table_Raw, target_eid: entity_id, elem_size: int, loc:= #caller_location) -> (err: Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found

        target_rid := self.eid_to_rid[target_eid.ix]

        if target_rid == TABLE_NO_RID do return oc.Core_Error.Not_Found

        T_size := elem_size
        target := table_raw__rid_to_ptr_sized(self, target_rid, elem_size)

        // Fires before any mutation below, so an observer can still read the
        // about-to-be-removed value through `data`.
        database__notify_observers(self.db, .Component_Removed, target_eid, table_id = self.id, data = target)

        // Cached once — nothing below changes the pause state before it's used.
        paused := table_raw__is_packing_paused(self)

        // Group maintenance: a member losing an owned component leaves the group —
        // swap its rows out of the prefix before this table's own tail swap runs.
        // While tail swap is paused rows must not move: mark dirty, rebuild on resume.
        if self.owner != nil && int(target_rid) < self.owner.len {
            if paused {
                self.owner.dirty = true
            } else {
                group__swap_out(self.owner, target_eid)
                target_rid = self.eid_to_rid[target_eid.ix]
                target = table_raw__rid_to_ptr_sized(self, target_rid, elem_size)
            }
        }

        // Deferred tail swap: clear the component in place, leaving a hole.
        // Nothing moves, so component pointers stay stable while iterating.
        if paused {
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID
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
                else do view__missed_update_for_member(view, target_eid)
            }

            database__remove_component(self.db, target_eid, self.id)
            table_base__notify_sync_remove(self, target_eid)
            table_base__notify_excluding_views(self, target_eid)
            table_base__notify_any_of_views(self, target_eid)
            return
        }

        tail_rid := raw.len - 1
        tail_eid := self.rid_to_eid[tail_rid]

        when VALIDATIONS do assert(!is_not_set(tail_eid))

        tail := table_raw__rid_to_ptr_sized(self, tail_rid, elem_size)

        // Replace removed component with tail
        if int(target_rid) == tail_rid {
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
                else do view__missed_update_for_member(view, target_eid)
            }
        }
        else {
            mem.copy(target, tail, T_size)

            self.eid_to_rid[tail_eid.ix] = target_rid
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component_rid(view, self, tail_eid, target_rid)
                } else {
                    view__missed_update_for_member(view, target_eid)
                    view__missed_update_for_member(view, tail_eid)
                }
            }
        }

        // Zero tail — upholds the contract that a freshly added component reads as
        // zero-initialized. Dropping this would leak stale data into future adds.
        mem.zero(tail, T_size)
        raw.len -= 1

        database__remove_component(self.db, target_eid, self.id)

        table_base__notify_sync_remove(self, target_eid)
        table_base__notify_excluding_views(self, target_eid)
        table_base__notify_any_of_views(self, target_eid)

        return
    }

    @(private)
    // Type-erased entry point (Command_Buffer replay — see
    // command_buffer.odin's shared_table__add_component dispatch, which is
    // the only outside caller): reads self.type_info.size.
    table_raw__add_component :: proc(self: ^Table_Raw, eid: entity_id, data: rawptr = nil) -> (component: rawptr, err: Error) {
        return table_raw__add_component_sized(self, eid, self.type_info.size, data)
    }

    @(private)
    // Adds (or finds) the entity's row and returns a pointer to the component. If
    // `data` is not nil it is copied in before notifications run, and overwrites the
    // existing value on the Component_Already_Exist path — "last write wins", used
    // by Command_Buffer. elem_size is explicit so a #force_inline caller that knows
    // T at compile time gets the multiply folded into a constant/shift.
    // #no_bounds_check: callers validate eid; row indexes derive from raw.len < cap.
    table_raw__add_component_sized :: #force_inline proc(self: ^Table_Raw, eid: entity_id, elem_size: int, data: rawptr = nil) -> (component: rawptr, err: Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        rid := self.eid_to_rid[eid.ix]

        if rid == TABLE_NO_RID {
            // Capacity only matters when actually inserting — re-adding an
            // existing component on a full table must still report Component_Already_Exist
            if raw.len >= self.cap do return nil, oc.Core_Error.Container_Is_Full

            component = table_raw__rid_to_ptr_sized(self, raw.len, elem_size)
            if data != nil do mem.copy(component, data, elem_size)

            self.eid_to_rid[eid.ix] = u32(raw.len)
            self.rid_to_eid[raw.len] = eid

            database__add_component(self.db, eid, self.id)

            table_base__notify_sync_add(self, eid)
            database__notify_observers(self.db, .Component_Added, eid, table_id = self.id, data = component)

            raw.len += 1

            // Group maintenance: if the entity now has every owned component, swap
            // its rows into the group prefix (deferred while tail swap is paused).
            // Before the subscriber loop so views record the final addresses.
            if self.owner != nil && group__on_add(self.owner, eid) {
                // the swap moved the new row — re-derive the returned pointer
                component = table_raw__rid_to_ptr_sized(self, self.eid_to_rid[eid.ix], elem_size)
            }
        } else {
            component = table_raw__rid_to_ptr_sized(self, rid, elem_size)
            if data != nil {
                mem.copy(component, data, elem_size)
                table_base__mark_touched(self, eid)
                // Overwrite can flip a view's filter verdict; the add-notify below
                // short-circuits on existing members, so re-run filters explicitly
                // (Command_Buffer "last write wins" path).
                for view in self.subscribers_with_filter.items {
                    if !view.suspended do view__rerun_filter(view, eid)
                }
            }
            err = API_Error.Component_Already_Exist
        }

        // Notify subscribed views. Also runs on the already-exists path on purpose: it
        // recovers a view membership that a previous add failed to register (e.g. view was at cap).
        for view in self.subscribers.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        // Views any_of-ing this table may have gained their (first) matching table for
        // this entity. If the entity was already a member via another any_of table,
        // view__add_record's Already_Exists is silently discarded, same as above.
        for view in self.subscribers_any_of.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        // Views excluding this table lose the entity (no-op if it wasn't a member)
        for view in self.subscribers_excluding.items {
            if !view.suspended do view__remove_record(view, eid)
        }

        return
    }

    // Type-erased entry point (database-wide resume_packing sweeps, Group,
    // Command_Buffer-adjacent callers): reads self.type_info.size.
    @(private)
    table_raw__pack :: proc(self: ^Table_Raw) -> Error {
        return table_raw__pack_sized(self, self.type_info.size)
    }

    // Compact holes left by removals made while tail swap was paused: each hole is
    // filled with the current last live row — exactly holes_count moves, the minimum
    // possible (rows are unordered, so order does not need to be preserved).
    // elem_size explicit parameter: see table_raw__add_component_sized.
    @(private)
    table_raw__pack_sized :: #force_inline proc(self: ^Table_Raw, elem_size: int) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.holes_count <= 0 {
            self.first_hole_rid = max(int)
            return nil
        }

        raw := (^runtime.Raw_Slice)(&self.rows)
        T_size := elem_size
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
            self.eid_to_rid[moved_eid.ix] = u32(front)
            mem.zero(src, T_size)

            for view in self.subscribers.items {
                if !view.suspended do view__update_component_rid(view, self, moved_eid, front)
                else do view__missed_update_for_member(view, moved_eid)
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

    table__init :: proc(self: ^Table($T), db: ^Database, cap: int, subscribers_cap: int = SUBSCRIBERS_CAP, sync_channels_cap: int = SYNC_CHANNELS_CAP, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(cap > 0, loc = loc)
            assert(cap <= db.overbase.id_factory.cap, loc = loc) // cannot be larger than entities_cap
            assert(cap < int(max(u32)), loc = loc) // row ids must fit the u32 eid_to_rid index
            assert(size_of(T) != 0, "component type T must not be zero-sized — use Tag_Table for a marker/tag component that carries no data", loc = loc)
        }

        if size_of(T) == 0 do return API_Error.Component_Size_Cannot_Be_Zero

        self.type_info = type_info_of(typeid_of(T))

        table_base__init(&self.base, db, cap, subscribers_cap, sync_channels_cap) or_return

        self.rows = make([]T, cap, db.allocator) or_return

        // database__attach_table is capacity-limited (Container_Is_Full once
        // tables_cap is exhausted) — unlike the allocations above, which only
        // fail on OOM, this is a routine, expected failure mode with a small
        // per-database tables_cap, so it must not leak what already succeeded.
        id, aerr := database__attach_table(db, self)
        if aerr != nil {
            delete(self.rows, db.allocator)
            table_base__terminate(&self.base)
            return aerr
        }
        self.id = id

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
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err = database__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        c, aerr := table_raw__add_component_sized(cast(^Table_Raw) self, eid, size_of(T))
        return cast(^T) c, aerr
    }

    // Compact holes left by removals made while tail swap was paused
    // (see database__pause_packing). Callable mid-pause too.
    table__pack :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return table_raw__pack_sized(cast(^Table_Raw) self, size_of(T))
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
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(eid.ix >= 0, loc = loc)
            assert(self.type_info.id == typeid_of(T), loc = loc)
        }

        database__is_entity_correct(self.db, eid) or_return

        return table_raw__remove_component_sized(cast(^Table_Raw) self, eid, size_of(T), loc)
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

    // Live rows as one contiguous slice. Return via call, not direct field access —
    // `for &p in t.rows` can't be proven non-aliasing by the optimizer and reloads
    // the pointer every store (~30-40% slower measured).
    @(require_results)
    table__slice :: #force_inline proc "contextless" (self: ^Table($T)) -> []T {
        return self.rows
    }

    @(require_results)
    table__get_component_by_entity :: proc (self: ^Table($T), eid: entity_id) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        #no_bounds_check {
            rid := self.eid_to_rid[eid.ix]
            if rid == TABLE_NO_RID do return nil
            return &self.rows[rid]
        }
    }

    // Same as table__get_component_by_entity, but marks eid touched in every
    // Sync_Channel watching this table — use whenever you intend to WRITE through
    // the returned pointer, so the next collect_delta picks up the change.
    @(require_results)
    table__get_component_mut :: proc (self: ^Table($T), eid: entity_id) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        #no_bounds_check {
            rid := self.eid_to_rid[eid.ix]
            if rid == TABLE_NO_RID do return nil
            table_base__mark_touched(self, eid)
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

    // Soft toggle: excludes the component from View matching without removing it — see
    // database.odin's "Component enable/disable" section.
    table__disable_component :: proc(self: ^Table($T), eid: entity_id) -> Error {
        return database__disable_component(self.db, eid, self.id)
    }

    table__enable_component :: proc(self: ^Table($T), eid: entity_id) -> Error {
        return database__enable_component(self.db, eid, self.id)
    }

    @(require_results)
    table__is_component_disabled :: proc(self: ^Table($T), eid: entity_id) -> bool {
        return database__is_component_disabled(self.db, eid, self.id)
    }

    table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Table($T), #any_int row_number: int) -> entity_id {
        return table_base__get_entity_by_row_number(self, row_number)
    }

    table__memory_usage :: proc (self: ^Table($T)) -> int {    
       return table_base__memory_usage(cast(^Table_Base) self)
    }
 
    // Component data for entity `eid`` is copied into `dest` table from `src`
    // table and linked to enitity `eid`
    table__copy_component :: proc(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        // Validate eid once per db (src/dest may belong to different Databases)
        // instead of the get/get/add path re-validating dest three times over.
        database__is_entity_correct(src.db, eid) or_return
        database__is_entity_correct(dest.db, eid) or_return

        src_component = cast(^T) table_raw__get_component_by_entity(cast(^Table_Raw) src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found

        dest_component = cast(^T) table_raw__get_component_by_entity(cast(^Table_Raw) dest, eid) // if it exists we will overwrite data
        if dest_component == nil {
            c, aerr := table_raw__add_component(cast(^Table_Raw) dest, eid)
            if aerr != nil do return nil, src_component, aerr
            dest_component = cast(^T) c
        }

        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    // Component data for entity `eid`` is moved into `dest` table from `src` 
    // table and linked to enitity `eid`
    table__move_component :: proc(dest: ^Table($T), src: ^Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = table__copy_component(dest, src, eid) or_return

        table__remove_component(src, eid) or_return

        return dest_component, nil
    }

    table__clear :: proc(self: ^Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        table_raw__clear((^Table_Raw)(self), true) or_return

        return nil
    }



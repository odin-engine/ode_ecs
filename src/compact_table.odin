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

    @(private)
    Compact_Table_Base :: struct {
        using shared: Shared_Table,

        type_info: ^runtime.Type_Info,
        rid_to_eid: []entity_id,
        eid_to_rid: oc_maps.Rh_Map32,

        cap: int,

        holes_count: int,
        first_hole_rid: int,

        subscribers_cap: int,

        subscribers: oc.Dense_Arr(^View),
        subscribers_with_filter: oc.Dense_Arr(^View),
        subscribers_excluding: oc.Dense_Arr(^View),
        subscribers_any_of: oc.Dense_Arr(^View),

        sync_channels_cap: int,
        sync_watchers: oc.Dense_Arr(^Sync_Channel),
    }

    @(private)
    compact_table_base__is_valid :: proc(self: ^Compact_Table_Base) -> bool {
        if self == nil do return false
        if !shared_table__is_valid_internal(&self.shared) do return false
        if self.type_info == nil do return false
        if self.rid_to_eid == nil do return false
        if !oc_maps.rh_map32__is_valid(&self.eid_to_rid) do return false
        if self.cap <= 0 do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_with_filter) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_excluding) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.subscribers_any_of) do return false
        if !oc.dense_arr__is_valid_or_empty(&self.sync_watchers) do return false

        return true
    }

    @(private)
    compact_table_base__init :: proc(self: ^Compact_Table_Base, db: ^Database, cap: int, subscribers_cap: int = SUBSCRIBERS_CAP, sync_channels_cap: int = SYNC_CHANNELS_CAP) -> Error {
        shared_table__init(&self.shared, Table_Type.Compact_Table, db)

        self.cap = cap

        self.rid_to_eid = make([]entity_id, self.cap, db.allocator) or_return

        oc_maps.rh_map32__init(&self.eid_to_rid, math.next_power_of_two(self.cap * 2), db.allocator) or_return

        self.subscribers_cap = subscribers_cap
        self.sync_channels_cap = sync_channels_cap

        return nil
    }

    @(private)
    compact_table_base__terminate :: proc(self: ^Compact_Table_Base) -> Error {
        if self.sync_watchers.items != nil do oc.dense_arr__terminate(&self.sync_watchers, self.db.allocator) or_return
        if self.subscribers_any_of.items != nil do oc.dense_arr__terminate(&self.subscribers_any_of, self.db.allocator) or_return
        if self.subscribers_excluding.items != nil do oc.dense_arr__terminate(&self.subscribers_excluding, self.db.allocator) or_return
        if self.subscribers_with_filter.items != nil do oc.dense_arr__terminate(&self.subscribers_with_filter, self.db.allocator) or_return
        if self.subscribers.items != nil do oc.dense_arr__terminate(&self.subscribers, self.db.allocator) or_return

        delete(self.rid_to_eid, self.db.allocator) or_return
        oc_maps.rh_map32__terminate(&self.eid_to_rid, self.db.allocator) or_return

        return nil
    }

    @(private)
    compact_table_base__cap :: #force_inline proc "contextless" (self: ^Compact_Table_Base) -> int {
        return self.cap
    }

    @(private)
    compact_table_base__attach_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
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
    compact_table_base__detach_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        err := oc.dense_arr__remove_by_value(&self.subscribers, view)
        if err != nil do return err

        err = oc.dense_arr__remove_by_value(&self.subscribers_with_filter, view)
        if err == oc.Core_Error.Not_Found do return nil
        return err
    }

    @(private)
    compact_table_base__attach_exclude_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        if self.subscribers_excluding.items == nil do oc.dense_arr__init(&self.subscribers_excluding, self.subscribers_cap, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers_excluding, view, self.db.allocator)
        return err
    }

    @(private)
    compact_table_base__detach_exclude_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_excluding, view)
    }

    @(private)
    compact_table_base__attach_any_of_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        if self.subscribers_any_of.items == nil do oc.dense_arr__init(&self.subscribers_any_of, self.subscribers_cap, self.db.allocator) or_return

        _, err := oc.dense_arr__add_growing(&self.subscribers_any_of, view, self.db.allocator)
        return err
    }

    @(private)
    compact_table_base__detach_any_of_subscriber :: proc(self: ^Compact_Table_Base, view: ^View) -> Error {
        return oc.dense_arr__remove_by_value(&self.subscribers_any_of, view)
    }

    @(private)
    compact_table_base__attach_sync_channel :: proc(self: ^Compact_Table_Base, ch: ^Sync_Channel) -> Error {
        when !SYNC_ENABLED do return API_Error.Sync_Feature_Disabled

        if self.sync_watchers.items == nil do oc.dense_arr__init(&self.sync_watchers, self.sync_channels_cap, self.db.allocator) or_return
        _, err := oc.dense_arr__add(&self.sync_watchers, ch)
        return err
    }

    @(private)
    compact_table_base__detach_sync_channel :: proc(self: ^Compact_Table_Base, ch: ^Sync_Channel) -> Error {
        when !SYNC_ENABLED do return API_Error.Sync_Feature_Disabled

        return oc.dense_arr__remove_by_value(&self.sync_watchers, ch)
    }

    @(private)
    compact_table_base__notify_excluding_views :: #force_inline proc(self: ^Compact_Table_Base, eid: entity_id) {
        if self.db.destroying_eid_ix == eid.ix do return
        for view in self.subscribers_excluding.items {
            if !view.suspended && view__components_match(view, eid) {
                when VALIDATIONS {
                    aerr := view__add_record(view, eid)
                    assert(aerr != API_Error.Cannot_Add_Record_To_View_Container_Is_Full, "excluding view is full — entity silently dropped, raise the view's included tables' caps")
                } else {
                    view__add_record(view, eid)
                }
            }
        }
    }

    @(private)
    compact_table_base__notify_any_of_views :: #force_inline proc(self: ^Compact_Table_Base, eid: entity_id) {
        for view in self.subscribers_any_of.items {
            if !view.suspended && !view__components_match(view, eid) do view__remove_record(view, eid)
        }
    }

    @(private)
    compact_table_base__notify_sync_add :: #force_inline proc(self: ^Compact_Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            for ch in self.sync_watchers.items {
                sync_channel__notify_structural(ch, self.id, eid, true, false)
                sync_channel__mark_touched(ch, self.id, eid)
            }
        }
    }

    @(private)
    compact_table_base__notify_sync_remove :: #force_inline proc(self: ^Compact_Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            for ch in self.sync_watchers.items {
                sync_channel__notify_structural(ch, self.id, eid, false, false)
            }
        }
    }

    @(private)
    compact_table_base__mark_touched :: #force_inline proc(self: ^Compact_Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            for ch in self.sync_watchers.items {
                sync_channel__mark_touched(ch, self.id, eid)
            }
        }
    }

    @(private)
    compact_table_base__memory_usage :: proc (self: ^Compact_Table_Base) -> int {
        total := size_of(self^)

        if self.rid_to_eid != nil {
            total += size_of(self.rid_to_eid[0]) * len(self.rid_to_eid)
        }

        total += oc_maps.rh_map32__memory_usage(&self.eid_to_rid)

        total += self.type_info.size * self.cap

        total += oc.dense_arr__memory_usage(&self.subscribers)
        total += oc.dense_arr__memory_usage(&self.subscribers_with_filter)
        total += oc.dense_arr__memory_usage(&self.subscribers_excluding)
        total += oc.dense_arr__memory_usage(&self.subscribers_any_of)
        total += oc.dense_arr__memory_usage(&self.sync_watchers)

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
        return compact_table_raw__rid_to_ptr_sized(self, rid, self.type_info.size)
    }

    @(private)
    compact_table_raw__rid_to_ptr_sized :: #force_inline proc "contextless" (self: ^Compact_Table_Raw, #any_int rid: int, elem_size: int) -> rawptr {
        return rawptr(uintptr(raw_data(self.rows)) + uintptr(rid) * uintptr(elem_size))
    }

    @(private)
    compact_table_raw__get_component_by_entity :: #force_inline proc "contextless" (self: ^Compact_Table_Raw, eid: entity_id) -> rawptr {
        rid := oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix))
        if rid == oc_maps.RH_MAP32_DELETED do return nil
        return compact_table_raw__rid_to_ptr(self, rid)
    }

    @(private)
    compact_table_raw__terminate :: proc(self: ^Compact_Table_Raw) -> Error {
        for view in self.subscribers.items do view.state = Object_State.Invalid
        for view in self.subscribers_excluding.items do view.state = Object_State.Invalid
        for view in self.subscribers_any_of.items do view.state = Object_State.Invalid
        for ch in self.sync_watchers.items do sync_channel__on_table_terminated(ch, self.id, false)

        for &bits in self.db.eid_to_bits do uni_bits__remove(&bits, self.id)

        database__detach_table(self.db, self)

        if self.rows != nil do delete(self.rows, self.db.allocator) or_return

        compact_table_base__terminate(self) or_return

        shared_table__clear_state(&self.shared)

        return nil
    }

    @(private)
    compact_table_raw__remove_component :: proc(self: ^Compact_Table_Raw, target_eid: entity_id, loc:= #caller_location) -> (err: Error) {
        return compact_table_raw__remove_component_sized(self, target_eid, self.type_info.size, loc)
    }

    @(private)
    compact_table_raw__remove_component_sized :: #force_inline proc(self: ^Compact_Table_Raw, target_eid: entity_id, elem_size: int, loc:= #caller_location) -> (err: Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        if raw.len <= 0 do return oc.Core_Error.Not_Found

        target_rid, target_slot := oc_maps.rh_map32__get_with_index(&self.eid_to_rid, u32(target_eid.ix))

        if target_slot == oc.DELETED_INDEX do return oc.Core_Error.Not_Found

        T_size := elem_size
        target := compact_table_raw__rid_to_ptr_sized(self, target_rid, elem_size)

        database__notify_observers(self.db, .Component_Removed, target_eid, table_id = self.id, data = target)

        if shared_table__is_packing_paused(cast(^Shared_Table) self) {
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)
            self.rid_to_eid[target_rid].ix = DELETED_INDEX
            mem.zero(target, T_size)

            if int(target_rid) == raw.len - 1 {
                raw.len -= 1
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
            compact_table_base__notify_sync_remove(self, target_eid)
            compact_table_base__notify_excluding_views(self, target_eid)
            compact_table_base__notify_any_of_views(self, target_eid)
            return
        }

        tail_rid := raw.len - 1
        tail_eid := self.rid_to_eid[tail_rid]

        when VALIDATIONS do assert(!is_not_set(tail_eid))

        tail := compact_table_raw__rid_to_ptr_sized(self, tail_rid, elem_size)

        if int(target_rid) == tail_rid {
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)

            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended do view__remove_record(view, target_eid)
                else do view__missed_update_for_member(view, target_eid)
            }
        }
        else {
            mem.copy(target, tail, T_size)

            oc_maps.rh_map32__update(&self.eid_to_rid, u32(tail_eid.ix), target_rid)
            oc_maps.rh_map32__remove_at(&self.eid_to_rid, target_slot)

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            for view in self.subscribers.items {
                if !view.suspended {
                    view__remove_record(view, target_eid)
                    view__update_component_ptr(view, self, tail_eid, target)
                } else {
                    view__missed_update_for_member(view, target_eid)
                    view__missed_update_for_member(view, tail_eid)
                }
            }
        }

        mem.zero(tail, T_size)
        raw.len -= 1

        database__remove_component(self.db, target_eid, self.id)

        compact_table_base__notify_sync_remove(self, target_eid)
        compact_table_base__notify_excluding_views(self, target_eid)
        compact_table_base__notify_any_of_views(self, target_eid)

        return
    }

    @(private)
    compact_table_raw__add_component :: proc(self: ^Compact_Table_Raw, eid: entity_id, data: rawptr = nil) -> (component: rawptr, err: Error) {
        return compact_table_raw__add_component_sized(self, eid, self.type_info.size, data)
    }

    @(private)
    compact_table_raw__add_component_sized :: #force_inline proc(self: ^Compact_Table_Raw, eid: entity_id, elem_size: int, data: rawptr = nil) -> (component: rawptr, err: Error) #no_bounds_check {
        raw := (^runtime.Raw_Slice)(&self.rows)

        rid, found, gerr := oc_maps.rh_map32__get_or_insert(&self.eid_to_rid, u32(eid.ix), u32(raw.len), raw.len < self.cap)

        if !found {
            if raw.len >= self.cap do return nil, oc.Core_Error.Container_Is_Full
            if gerr != nil do return nil, gerr

            component = compact_table_raw__rid_to_ptr_sized(self, raw.len, elem_size)
            if data != nil do mem.copy(component, data, elem_size)

            self.rid_to_eid[raw.len] = eid

            database__add_component(self.db, eid, self.id)

            compact_table_base__notify_sync_add(self, eid)
            database__notify_observers(self.db, .Component_Added, eid, table_id = self.id, data = component)

            raw.len += 1
        } else {
            component = compact_table_raw__rid_to_ptr_sized(self, rid, elem_size)
            if data != nil {
                mem.copy(component, data, elem_size)
                compact_table_base__mark_touched(self, eid)
                for view in self.subscribers_with_filter.items {
                    if !view.suspended do view__rerun_filter(view, eid)
                }
            }
            err = API_Error.Component_Already_Exist
        }

        for view in self.subscribers.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        for view in self.subscribers_any_of.items {
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        for view in self.subscribers_excluding.items {
            if !view.suspended do view__remove_record(view, eid)
        }

        return
    }

    @(private)
    compact_table_raw__pack :: proc(self: ^Compact_Table_Raw) -> Error {
        return compact_table_raw__pack_sized(self, self.type_info.size)
    }

    @(private)
    compact_table_raw__pack_sized :: #force_inline proc(self: ^Compact_Table_Raw, elem_size: int) -> Error {
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
            for back >= 0 && is_not_set(self.rid_to_eid[back]) {
                back -= 1
                self.holes_count -= 1
            }
            if self.holes_count <= 0 do break

            for !is_not_set(self.rid_to_eid[front]) do front += 1

            dst := rawptr(uintptr(rows) + uintptr(front) * uintptr(T_size))
            src := rawptr(uintptr(rows) + uintptr(back)  * uintptr(T_size))
            mem.copy(dst, src, T_size)

            moved_eid := self.rid_to_eid[back]
            self.rid_to_eid[front] = moved_eid
            self.rid_to_eid[back].ix = DELETED_INDEX
            oc_maps.rh_map32__update(&self.eid_to_rid, u32(moved_eid.ix), u32(front))
            mem.zero(src, T_size)

            for view in self.subscribers.items {
                if !view.suspended do view__update_component_ptr(view, self, moved_eid, dst)
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

    @(private)
    compact_table_raw__len :: #force_inline proc "contextless" (self: ^Compact_Table_Raw) -> int {
        return (^runtime.Raw_Slice)(&self.rows).len
    }

    @(private)
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

    Compact_Table :: struct($T: typeid) {
        using base: Compact_Table_Base,
        rows: []T,
    }

    compact_table__is_valid :: proc(self: ^Compact_Table($T)) -> bool {
        if self == nil do return false
        if !compact_table_base__is_valid(&self.base) do return false
        if self.rows == nil do return false

        return true
    }

    compact_table__init :: proc(self: ^Compact_Table($T), db: ^Database, cap: int, subscribers_cap: int = SUBSCRIBERS_CAP, sync_channels_cap: int = SYNC_CHANNELS_CAP, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(cap > 0, loc = loc)
            assert(cap <= db.overbase.id_factory.cap, loc = loc)
            assert(db.overbase.id_factory.cap < int(max(u32)), loc = loc)
            assert(size_of(T) != 0, "component type T must not be zero-sized — use Tag_Table for a marker/tag component that carries no data", loc = loc)
        }

        if size_of(T) == 0 do return API_Error.Component_Size_Cannot_Be_Zero

        self.type_info = type_info_of(typeid_of(T))

        compact_table_base__init(&self.base, db, cap, subscribers_cap, sync_channels_cap) or_return

        self.rows = make([]T, cap, db.allocator) or_return

        id, aerr := database__attach_table(db, self)
        if aerr != nil {
            delete(self.rows, db.allocator)
            compact_table_base__terminate(&self.base)
            return aerr
        }
        self.id = id

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
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err = database__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        c, aerr := compact_table_raw__add_component_sized(cast(^Compact_Table_Raw) self, eid, size_of(T))
        return cast(^T) c, aerr
    }

    compact_table__pack :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return compact_table_raw__pack_sized(cast(^Compact_Table_Raw) self, size_of(T))
    }

    compact_table__pause_packing :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return compact_table_raw__pause_packing(cast(^Compact_Table_Raw) self)
    }

    compact_table__resume_packing :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return compact_table_raw__resume_packing(cast(^Compact_Table_Raw) self)
    }

    compact_table__remove_component :: proc(self: ^Compact_Table($T), eid: entity_id, loc:= #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(eid.ix >= 0, loc = loc)
            assert(self.type_info.id == typeid_of(T), loc = loc)
        }

        database__is_entity_correct(self.db, eid) or_return

        return compact_table_raw__remove_component_sized(cast(^Compact_Table_Raw) self, eid, size_of(T), loc)
    }

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
    compact_table__slice :: #force_inline proc "contextless" (self: ^Compact_Table($T)) -> []T {
        return self.rows
    }

    compact_table__entities_slice :: #force_inline proc "contextless" (self: ^Compact_Table($T)) -> []entity_id {
        return self.rid_to_eid[:compact_table_raw__len(cast(^Compact_Table_Raw) self)]
    }

    @(require_results)
    compact_table__get_component_by_entity :: proc (self: ^Compact_Table($T), eid: entity_id) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        return cast(^T) compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, eid)
    }

    @(require_results)
    compact_table__get_component_mut :: proc (self: ^Compact_Table($T), eid: entity_id) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        c := compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, eid)
        if c == nil do return nil
        compact_table_base__mark_touched(self, eid)
        return cast(^T) c
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

    compact_table__disable_component :: proc(self: ^Compact_Table($T), eid: entity_id) -> Error {
        return database__disable_component(self.db, eid, self.id)
    }

    compact_table__enable_component :: proc(self: ^Compact_Table($T), eid: entity_id) -> Error {
        return database__enable_component(self.db, eid, self.id)
    }

    @(require_results)
    compact_table__is_component_disabled :: proc(self: ^Compact_Table($T), eid: entity_id) -> bool {
        return database__is_component_disabled(self.db, eid, self.id)
    }

    compact_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Compact_Table($T), #any_int row_number: int) -> entity_id {
        return compact_table_base__get_entity_by_row_number(self, row_number)
    }

    compact_table__memory_usage :: proc (self: ^Compact_Table($T)) -> int {
       return compact_table_base__memory_usage(cast(^Compact_Table_Base) self)
    }

    compact_table__copy_component :: proc(dest: ^Compact_Table($T), src: ^Compact_Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        database__is_entity_correct(src.db, eid) or_return
        database__is_entity_correct(dest.db, eid) or_return

        src_component = cast(^T) compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found

        dest_component = cast(^T) compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) dest, eid)
        if dest_component == nil {
            c, aerr := compact_table_raw__add_component(cast(^Compact_Table_Raw) dest, eid)
            if aerr != nil do return nil, src_component, aerr
            dest_component = cast(^T) c
        }

        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    compact_table__move_component :: proc(dest: ^Compact_Table($T), src: ^Compact_Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = compact_table__copy_component(dest, src, eid) or_return

        compact_table__remove_component(src, eid) or_return

        return dest_component, nil
    }

    compact_table__clear :: proc(self: ^Compact_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        compact_table_raw__clear((^Compact_Table_Raw)(self), true) or_return

        return nil
    }

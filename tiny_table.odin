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
// Tiny_Table_Subscriber_Slot

    when SYNC_ENABLED {
        @(private)
        Tiny_Table_Subscriber_Slot :: struct {
            in_use: bool,
            subscribers: [TINY_TABLE__VIEWS_CAP]^View,
            subscribers_excluding: [TINY_TABLE__VIEWS_CAP]^View,
            subscribers_any_of: [TINY_TABLE__VIEWS_CAP]^View,
            sync_channels: [TINY_TABLE__SYNC_CHANNELS_CAP]^Sync_Channel,
        }
    } else {
        @(private)
        Tiny_Table_Subscriber_Slot :: struct {
            in_use: bool,
            subscribers: [TINY_TABLE__VIEWS_CAP]^View,
            subscribers_excluding: [TINY_TABLE__VIEWS_CAP]^View,
            subscribers_any_of: [TINY_TABLE__VIEWS_CAP]^View,
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Tiny_Table_Base

    when SYNC_ENABLED {
        @(private)
        Tiny_Table_Base :: struct {
            using shared: Shared_Table,

            type_info: ^runtime.Type_Info,
            rid_to_eid: [TINY_TABLE__ROW_CAP]entity_id,
            eid_to_ptr: oc_maps.Tt_Map(TINY_TABLE__MAP_CAP, rawptr),

            subscribers_slot_id: int,

            subscribers_count: int,
            subscribers_excluding_count: int,
            subscribers_any_of_count: int,
            sync_channels_count: int,
            len: int,

            holes_count: int,
            first_hole_rid: int,
        }
    } else {
        @(private)
        Tiny_Table_Base :: struct {
            using shared: Shared_Table,

            type_info: ^runtime.Type_Info,
            rid_to_eid: [TINY_TABLE__ROW_CAP]entity_id,
            eid_to_ptr: oc_maps.Tt_Map(TINY_TABLE__MAP_CAP, rawptr),

            subscribers_slot_id: int,

            subscribers_count: int,
            subscribers_excluding_count: int,
            subscribers_any_of_count: int,
            len: int,

            holes_count: int,
            first_hole_rid: int,
        }
    }

    @(private)
    tiny_table_base__is_valid :: proc (self: ^Tiny_Table_Base) -> bool {
        if self == nil do return false
        if !shared_table__is_valid_internal(&self.shared) do return false
        if self.type_info == nil do return false

        return true
    }

    @(private)
    tiny_table_base__slot :: #force_inline proc "contextless" (self: ^Tiny_Table_Base) -> ^Tiny_Table_Subscriber_Slot #no_bounds_check {
        return &self.db.tiny_table_subscriber_slots[self.subscribers_slot_id]
    }

    @(private)
    tiny_table_base__init :: proc(self: ^Tiny_Table_Base, db: ^Database) -> Error {
        shared_table__init(&self.shared, Table_Type.Tiny_Table, db)

        self.subscribers_slot_id = database__attach_tiny_table_subscribers(db) or_return
        self.subscribers_count = 0
        self.subscribers_excluding_count = 0
        self.subscribers_any_of_count = 0
        when SYNC_ENABLED {
            self.sync_channels_count = 0
        }

        id, aerr := database__attach_table(db, self)
        if aerr != nil {
            database__detach_tiny_table_subscribers(db, self.subscribers_slot_id)
            return aerr
        }
        self.id = id
        self.state = Object_State.Normal

        return nil
    }

    @(private)
    tiny_table_base__terminate :: proc(self: ^Tiny_Table_Base) ->Error {

        slot := tiny_table_base__slot(self)
        for view in slot.subscribers do if view != nil do view.state = Object_State.Invalid
        for view in slot.subscribers_excluding do if view != nil do view.state = Object_State.Invalid
        for view in slot.subscribers_any_of do if view != nil do view.state = Object_State.Invalid
        when SYNC_ENABLED {
            for ch in slot.sync_channels do if ch != nil do sync_channel__on_table_terminated(ch, self.id)
        }

        for &bits in self.db.eid_to_bits do uni_bits__remove(&bits, self.id)

        database__detach_table(self.db, self)
        database__detach_tiny_table_subscribers(self.db, self.subscribers_slot_id)

        shared_table__clear_state(&self.shared)

        return nil
    }

    @(private)
    tiny_table_base__attach_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        slot := tiny_table_base__slot(self)
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if slot.subscribers[i] == nil {
                slot.subscribers[i] = view
                self.subscribers_count += 1
                return nil
            }
        }

        return oc.Core_Error.Container_Is_Full
    }

    @(private)
    tiny_table_base__detach_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        slot := tiny_table_base__slot(self)
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if slot.subscribers[i] == view {
                slot.subscribers[i] = nil
                self.subscribers_count -= 1
                return nil
            }
        }

        return oc.Core_Error.Not_Found
    }

    @(private)
    tiny_table_base__attach_exclude_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        slot := tiny_table_base__slot(self)
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if slot.subscribers_excluding[i] == nil {
                slot.subscribers_excluding[i] = view
                self.subscribers_excluding_count += 1
                return nil
            }
        }

        return oc.Core_Error.Container_Is_Full
    }

    @(private)
    tiny_table_base__detach_exclude_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        slot := tiny_table_base__slot(self)
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if slot.subscribers_excluding[i] == view {
                slot.subscribers_excluding[i] = nil
                self.subscribers_excluding_count -= 1
                return nil
            }
        }

        return oc.Core_Error.Not_Found
    }

    @(private)
    tiny_table_base__attach_any_of_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        slot := tiny_table_base__slot(self)
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if slot.subscribers_any_of[i] == nil {
                slot.subscribers_any_of[i] = view
                self.subscribers_any_of_count += 1
                return nil
            }
        }

        return oc.Core_Error.Container_Is_Full
    }

    @(private)
    tiny_table_base__detach_any_of_subscriber :: proc(self: ^Tiny_Table_Base, view: ^View) -> Error {
        slot := tiny_table_base__slot(self)
        for i:=0; i < TINY_TABLE__VIEWS_CAP; i+=1 {
            if slot.subscribers_any_of[i] == view {
                slot.subscribers_any_of[i] = nil
                self.subscribers_any_of_count -= 1
                return nil
            }
        }

        return oc.Core_Error.Not_Found
    }

    @(private)
    tiny_table_base__attach_sync_channel :: proc(self: ^Tiny_Table_Base, ch: ^Sync_Channel) -> Error {
        when SYNC_ENABLED {
            slot := tiny_table_base__slot(self)
            for i := 0; i < TINY_TABLE__SYNC_CHANNELS_CAP; i += 1 {
                if slot.sync_channels[i] == nil {
                    slot.sync_channels[i] = ch
                    self.sync_channels_count += 1
                    return nil
                }
            }
            return oc.Core_Error.Container_Is_Full
        } else {
            return API_Error.Sync_Feature_Disabled
        }
    }

    @(private)
    tiny_table_base__detach_sync_channel :: proc(self: ^Tiny_Table_Base, ch: ^Sync_Channel) -> Error {
        when SYNC_ENABLED {
            slot := tiny_table_base__slot(self)
            for i := 0; i < TINY_TABLE__SYNC_CHANNELS_CAP; i += 1 {
                if slot.sync_channels[i] == ch {
                    slot.sync_channels[i] = nil
                    self.sync_channels_count -= 1
                    return nil
                }
            }
            return oc.Core_Error.Not_Found
        } else {
            return API_Error.Sync_Feature_Disabled
        }
    }

    @(private)
    tiny_table_base__notify_sync_add :: #force_inline proc(self: ^Tiny_Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            if self.sync_channels_count == 0 do return
            slot := tiny_table_base__slot(self)
            for ch in slot.sync_channels {
                if ch == nil do continue
                sync_channel__notify_structural(ch, self.id, eid, true)
                sync_channel__mark_touched(ch, self.id, eid)
            }
        }
    }

    @(private)
    tiny_table_base__notify_sync_remove :: #force_inline proc(self: ^Tiny_Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            if self.sync_channels_count == 0 do return
            slot := tiny_table_base__slot(self)
            for ch in slot.sync_channels {
                if ch == nil do continue
                sync_channel__notify_structural(ch, self.id, eid, false)
            }
        }
    }

    @(private)
    tiny_table_base__mark_touched :: #force_inline proc(self: ^Tiny_Table_Base, eid: entity_id) {
        when SYNC_ENABLED {
            if self.sync_channels_count == 0 do return
            slot := tiny_table_base__slot(self)
            for ch in slot.sync_channels {
                if ch == nil do continue
                sync_channel__mark_touched(ch, self.id, eid)
            }
        }
    }

    @(private)
    tiny_table_base__notify_excluding_views :: #force_inline proc(self: ^Tiny_Table_Base, eid: entity_id) {
        if self.subscribers_excluding_count == 0 do return
        if self.db.destroying_eid_ix == eid.ix do return
        slot := tiny_table_base__slot(self)
        for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
            view := slot.subscribers_excluding[i]
            if view != nil && !view.suspended && view__components_match(view, eid) {
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
    tiny_table_base__notify_any_of_views :: #force_inline proc(self: ^Tiny_Table_Base, eid: entity_id) {
        if self.subscribers_any_of_count == 0 do return
        slot := tiny_table_base__slot(self)
        for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
            view := slot.subscribers_any_of[i]
            if view != nil && !view.suspended && !view__components_match(view, eid) do view__remove_record(view, eid)
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
    tiny_table_base__get_component_by_entity :: #force_inline proc (self: ^Tiny_Table_Base, eid: entity_id) -> rawptr {
        return oc_maps.tt_map__get(&self.eid_to_ptr, eid.ix)
    }

    @(private)
    tiny_table_base__memory_usage :: proc (self: ^Tiny_Table_Base) -> int {
        if self == nil || self.type_info == nil {
            when VALIDATIONS do assert(false, "memory_usage on an uninitialized Tiny_Table")
            return 0
        }
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
        return tiny_table_raw__remove_component_sized(self, target_eid, self.type_info.size)
    }

    @(private)
    tiny_table_raw__remove_component_sized :: #force_inline proc(self: ^Tiny_Table_Raw, target_eid: entity_id, elem_size: int) -> (err: Error) {
        if self.len <= 0 do return oc.Core_Error.Not_Found

        target_item, target_slot := oc_maps.tt_map__find_item_with_index(&self.eid_to_ptr, target_eid.ix)

        if target_item == nil || target_item.value == nil do return oc.Core_Error.Not_Found

        target := target_item.value

        T_size := elem_size

        database__notify_observers(self.db, .Component_Removed, target_eid, table_id = self.id, data = target)

        if shared_table__is_packing_paused(cast(^Shared_Table) self) {
            target_rid := int(uintptr(target) - uintptr(&self.rows[0])) / T_size

            oc_maps.tt_map__remove_found(&self.eid_to_ptr, target_item, target_slot)
            self.rid_to_eid[target_rid].ix = DELETED_INDEX
            mem.zero(target, T_size)

            if target_rid == self.len - 1 {
                self.len -= 1
                for self.len > 0 && is_not_set(self.rid_to_eid[self.len - 1]) {
                    self.len -= 1
                    self.holes_count -= 1
                }
            } else {
                self.holes_count += 1
                if target_rid < self.first_hole_rid do self.first_hole_rid = target_rid
            }

            if self.subscribers_count > 0 {
                slot := tiny_table_base__slot(self)
                for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                    view := slot.subscribers[i]
                    if view == nil do continue
                    if !view.suspended do view__remove_record(view, target_eid)
                    else do view__missed_update_for_member(view, target_eid)
                }
            }

            database__remove_component(self.db, target_eid, self.id)
            tiny_table_base__notify_sync_remove(self, target_eid)
            tiny_table_base__notify_excluding_views(self, target_eid)
            tiny_table_base__notify_any_of_views(self, target_eid)
            return
        }

        tail_rid := self.len - 1
        tail_eid := self.rid_to_eid[tail_rid]

        when VALIDATIONS do assert(!is_not_set(tail_eid))

        tail := rawptr(uintptr(&self.rows[0]) + uintptr(tail_rid) * uintptr(T_size))

        target_rid := int(uintptr(target) - uintptr(&self.rows[0])) / T_size

        if target == tail {
            oc_maps.tt_map__remove_found(&self.eid_to_ptr, target_item, target_slot)
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            if self.subscribers_count > 0 {
                slot := tiny_table_base__slot(self)
                for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                    view := slot.subscribers[i]
                    if view == nil do continue
                    if !view.suspended do view__remove_record(view, target_eid)
                    else do view__missed_update_for_member(view, target_eid)
                }
            }
        }
        else {
            tail_eid := self.rid_to_eid[tail_rid]
            when VALIDATIONS do assert(!is_not_set(tail_eid))

            mem.copy(target, tail, T_size)

            oc_maps.tt_map__add(&self.eid_to_ptr, tail_eid.ix, target)
            oc_maps.tt_map__remove_found(&self.eid_to_ptr, target_item, target_slot)

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX

            if self.subscribers_count > 0 {
                slot := tiny_table_base__slot(self)
                for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                    view := slot.subscribers[i]
                    if view == nil do continue
                    if !view.suspended {
                        view__remove_record(view, target_eid)
                        view__update_component_ptr(view, self, tail_eid, target)
                    } else {
                        view__missed_update_for_member(view, target_eid)
                        view__missed_update_for_member(view, tail_eid)
                    }
                }
            }
        }

        mem.zero(tail, T_size)
        self.len -= 1

        database__remove_component(self.db, target_eid, self.id)

        tiny_table_base__notify_sync_remove(self, target_eid)
        tiny_table_base__notify_excluding_views(self, target_eid)
        tiny_table_base__notify_any_of_views(self, target_eid)

        return
    }

    @(private)
    tiny_table_raw__add_component :: proc(self: ^Tiny_Table_Raw, eid: entity_id, data: rawptr = nil) -> (component: rawptr, err: Error) {
        return tiny_table_raw__add_component_sized(self, eid, self.type_info.size, data)
    }

    @(private)
    tiny_table_raw__add_component_sized :: #force_inline proc(self: ^Tiny_Table_Raw, eid: entity_id, elem_size: int, data: rawptr = nil) -> (component: rawptr, err: Error) {
        component = oc_maps.tt_map__get(&self.eid_to_ptr, eid.ix)

        if component == nil {
            if self.len >= TINY_TABLE__ROW_CAP do return nil, oc.Core_Error.Container_Is_Full

            T_size := elem_size

            component = rawptr(uintptr(&self.rows[0]) + uintptr(self.len) * uintptr(T_size))
            if data != nil do mem.copy(component, data, T_size)

            err = oc_maps.tt_map__add(&self.eid_to_ptr, eid.ix, component)
            if err != nil do return nil, err

            self.rid_to_eid[self.len] = eid

            database__add_component(self.db, eid, self.id)

            tiny_table_base__notify_sync_add(self, eid)
            database__notify_observers(self.db, .Component_Added, eid, table_id = self.id, data = component)

            self.len += 1
        } else {
            if data != nil {
                mem.copy(component, data, elem_size)
                tiny_table_base__mark_touched(self, eid)
                if self.subscribers_count > 0 {
                    slot := tiny_table_base__slot(self)
                    for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
                        view := slot.subscribers[i]
                        if view != nil && !view.suspended && view.filter != nil do view__rerun_filter(view, eid)
                    }
                }
            }
            err = API_Error.Component_Already_Exist
        }

        if self.subscribers_count > 0 {
            slot := tiny_table_base__slot(self)
            for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
                view := slot.subscribers[i]
                if view != nil && !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
            }
        }

        if self.subscribers_any_of_count > 0 {
            slot := tiny_table_base__slot(self)
            for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
                view := slot.subscribers_any_of[i]
                if view != nil && !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
            }
        }

        if self.subscribers_excluding_count > 0 {
            slot := tiny_table_base__slot(self)
            for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
                view := slot.subscribers_excluding[i]
                if view != nil && !view.suspended do view__remove_record(view, eid)
            }
        }

        return
    }

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

    @(private)
    tiny_table_raw__pack :: proc(self: ^Tiny_Table_Raw) -> Error {
        return tiny_table_raw__pack_sized(self, self.type_info.size)
    }

    @(private)
    tiny_table_raw__pack_sized :: #force_inline proc(self: ^Tiny_Table_Raw, elem_size: int) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.holes_count <= 0 {
            self.first_hole_rid = max(int)
            return nil
        }

        T_size := elem_size
        rows := rawptr(&self.rows[0])

        front := self.first_hole_rid
        back := self.len - 1

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
            oc_maps.tt_map__add(&self.eid_to_ptr, moved_eid.ix, dst)
            mem.zero(src, T_size)

            if self.subscribers_count > 0 {
                slot := tiny_table_base__slot(self)
                for i := 0; i < TINY_TABLE__VIEWS_CAP; i += 1 {
                    view := slot.subscribers[i]
                    if view == nil do continue
                    if !view.suspended do view__update_component_ptr(view, self, moved_eid, dst)
                    else do view__missed_update_for_member(view, moved_eid)
                }
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

    tiny_table__is_valid :: proc (self: ^Tiny_Table($T)) -> bool {
        if self == nil do return false 
        if !tiny_table_base__is_valid(&self.base) do return false

        return true
    }

    tiny_table__init :: proc(self: ^Tiny_Table($T), db: ^Database, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(size_of(T) != 0, "component type T must not be zero-sized — use Tag_Table for a marker/tag component that carries no data", loc = loc)
        }

        #assert(offset_of(Tiny_Table(T), rows) == offset_of(Tiny_Table_Raw, rows))

        if size_of(T) == 0 do return API_Error.Component_Size_Cannot_Be_Zero

        self.type_info = type_info_of(typeid_of(T))
        tiny_table_base__init(cast(^Tiny_Table_Base) self, db) or_return
        tiny_table_raw__clear(cast(^Tiny_Table_Raw) self, false) or_return

        return nil
    }

    tiny_table__terminate :: proc(self: ^Tiny_Table($T), loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.type_info.id == typeid_of(T), loc = loc)
            assert(self.db != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
            assert(self.db.state == Object_State.Normal, loc = loc)
        }

        tiny_table_base__terminate(cast(^Tiny_Table_Base) self) or_return

        return nil
    }

    tiny_table__add_component :: proc(self: ^Tiny_Table($T), eid: entity_id) -> (component: ^T, err: Error) {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err = database__is_entity_correct(self.db, eid)
        if err != nil do return nil, err

        c, aerr := tiny_table_raw__add_component_sized(cast(^Tiny_Table_Raw) self, eid, size_of(T))
        return cast(^T) c, aerr
    }

    tiny_table__pack :: proc(self: ^Tiny_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return tiny_table_raw__pack_sized(cast(^Tiny_Table_Raw) self, size_of(T))
    }

    tiny_table__pause_packing :: proc(self: ^Tiny_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return tiny_table_raw__pause_packing(cast(^Tiny_Table_Raw) self)
    }

    tiny_table__resume_packing :: proc(self: ^Tiny_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return tiny_table_raw__resume_packing(cast(^Tiny_Table_Raw) self)
    }

    tiny_table__remove_component :: proc(self: ^Tiny_Table($T), eid: entity_id) -> (err: Error) {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        database__is_entity_correct(self.db, eid) or_return

        return tiny_table_raw__remove_component_sized(cast(^Tiny_Table_Raw) self, eid, size_of(T))
    }

    tiny_table__rerun_views_filters :: proc(self: ^Tiny_Table($T), eid: entity_id) -> Error {
        database__is_entity_correct(self.db, eid) or_return

        if self.subscribers_count > 0 {
            slot := tiny_table_base__slot(cast(^Tiny_Table_Base) self)
            for i:=0; i<TINY_TABLE__VIEWS_CAP; i+=1 {
                view := slot.subscribers[i]
                if view != nil && !view.suspended {
                    view__rerun_filter(view, eid) or_return
                }
            }
        }

        return nil
    }

    @(require_results)
    tiny_table__get_component_by_entity :: proc (self: ^Tiny_Table($T), eid: entity_id) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        return cast(^T) tiny_table_base__get_component_by_entity(self, eid)
    }

    @(require_results)
    tiny_table__get_component_mut :: proc (self: ^Tiny_Table($T), eid: entity_id) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(self.type_info.id == typeid_of(T))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        c := tiny_table_base__get_component_by_entity(self, eid)
        if c == nil do return nil
        tiny_table_base__mark_touched(self, eid)
        return cast(^T) c
    }

    tiny_table__len :: #force_inline proc "contextless" (self: ^Tiny_Table($T)) -> int {
        return tiny_table_base__len(cast(^Tiny_Table_Base) self)
    }

    tiny_table__cap :: #force_inline proc "contextless" (self: ^Tiny_Table($T)) -> int {
        return tiny_table_base__cap(cast(^Tiny_Table_Base) self)
    }

    @(require_results)
    tiny_table__slice :: #force_inline proc "contextless" (self: ^Tiny_Table($T)) -> []T {
        return self.rows[:self.len]
    }

    tiny_table__entities_slice :: #force_inline proc "contextless" (self: ^Tiny_Table($T)) -> []entity_id {
        return self.rid_to_eid[:self.len]
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

    tiny_table__disable_component :: proc(self: ^Tiny_Table($T), eid: entity_id) -> Error {
        return database__disable_component(self.db, eid, self.id)
    }

    tiny_table__enable_component :: proc(self: ^Tiny_Table($T), eid: entity_id) -> Error {
        return database__enable_component(self.db, eid, self.id)
    }

    @(require_results)
    tiny_table__is_component_disabled :: proc(self: ^Tiny_Table($T), eid: entity_id) -> bool {
        return database__is_component_disabled(self.db, eid, self.id)
    }

    tiny_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Tiny_Table($T), #any_int row_number: int) -> entity_id {
        return tiny_table_base__get_entity_by_row_number(self, row_number)
    }

    tiny_table__memory_usage :: proc (self: ^Tiny_Table($T)) -> int {    
        return tiny_table_base__memory_usage(cast(^Tiny_Table_Base) self)
    }

    tiny_table__copy_component :: proc(dest: ^Tiny_Table($T), src: ^Tiny_Table(T), eid: entity_id) -> (dest_component: ^T, src_component: ^T, err: Error) {
        database__is_entity_correct(src.db, eid) or_return
        database__is_entity_correct(dest.db, eid) or_return

        src_component = cast(^T) tiny_table_base__get_component_by_entity(src, eid)
        if src_component == nil do return nil, src_component, oc.Core_Error.Not_Found

        dest_component = cast(^T) tiny_table_base__get_component_by_entity(dest, eid)
        if dest_component == nil {
            c, aerr := tiny_table_raw__add_component(cast(^Tiny_Table_Raw) dest, eid)
            if aerr != nil do return nil, src_component, aerr
            dest_component = cast(^T) c
        }

        dest_component^ = src_component^

        return dest_component, src_component, nil
    }

    tiny_table__move_component :: proc(dest: ^Tiny_Table($T), src: ^Tiny_Table(T), eid: entity_id) -> (dest_component: ^T, err: Error) {
        dest_component, _ = tiny_table__copy_component(dest, src, eid) or_return

        tiny_table__remove_component(src, eid) or_return

        return dest_component, nil
    }

    tiny_table__clear :: proc(self: ^Tiny_Table($T)) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        return tiny_table_raw__clear((^Tiny_Table_Raw)(self), true)
    }


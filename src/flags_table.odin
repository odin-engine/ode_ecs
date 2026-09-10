/*
    2026 (c) Oleh, https://github.com/zm69

    Flags_Table - up to 128 flags (Bits) per entity, stored as a Compact_Table(Bits).
    An entity has a row exactly when it has at least one flag, so `&flags` in a view
    means "has any flag", and entity destroy clears flags through the normal
    component path. Views test specific flags with a Flags term and a Flags_Op.
*/
package ode_ecs

// Base
    import "base:intrinsics"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Types

    Flags_Table :: struct {
        using compact: Compact_Table(Bits),
        flags_subscribers: oc.Dense_Arr(Flags_Subscriber),
        flags_mask: Bits, // union of subscriber masks
    }

    // A view and the bits its Flags terms on this table depend on.
    @(private)
    Flags_Subscriber :: struct {
        view: ^View,
        mask: Bits,
    }

    Flags_Op :: enum u8 {
        And = 0,
        Or,
        Xor,
        Nor,
        Nand,
        Exact,
    }

    Flags :: struct {
        table: ^Flags_Table,
        bits:  Bits,
        op:    Flags_Op,
    }

    Flags_Change :: struct {
        old: Bits,
        new: Bits,
    }

    flags_term :: #force_inline proc "contextless" (table: ^Flags_Table, bits: Bits, op := Flags_Op.And) -> Flags {
        return Flags{table, bits, op}
    }

    @(private)
    flags__bit :: #force_inline proc(v: int) -> int {
        when VALIDATIONS do assert(v >= 0 && v < BIT_SET_VALUES_CAP, "enum value out of flag range 0..<128")
        return v
    }

    flags__of_set :: proc(s: bit_set[$E]) -> (res: Bits) where intrinsics.type_is_enum(E) {
        for v in s do res += {flags__bit(int(v))}
        return
    }

    flags__of_1 :: proc(a: $E) -> Bits where intrinsics.type_is_enum(E) {
        return {flags__bit(int(a))}
    }

    flags__of_2 :: proc(a, b: $E) -> Bits where intrinsics.type_is_enum(E) {
        return {flags__bit(int(a)), flags__bit(int(b))}
    }

    flags__of_3 :: proc(a, b, c: $E) -> Bits where intrinsics.type_is_enum(E) {
        return {flags__bit(int(a)), flags__bit(int(b)), flags__bit(int(c))}
    }

    flags__of_4 :: proc(a, b, c, d: $E) -> Bits where intrinsics.type_is_enum(E) {
        return {flags__bit(int(a)), flags__bit(int(b)), flags__bit(int(c)), flags__bit(int(d))}
    }

    flags__of_5 :: proc(a, b, c, d, e: $E) -> Bits where intrinsics.type_is_enum(E) {
        return {flags__bit(int(a)), flags__bit(int(b)), flags__bit(int(c)), flags__bit(int(d)), flags__bit(int(e))}
    }

    flags__of_6 :: proc(a, b, c, d, e, f: $E) -> Bits where intrinsics.type_is_enum(E) {
        return {flags__bit(int(a)), flags__bit(int(b)), flags__bit(int(c)), flags__bit(int(d)), flags__bit(int(e)), flags__bit(int(f))}
    }

    flags__of_7 :: proc(a, b, c, d, e, f, g: $E) -> Bits where intrinsics.type_is_enum(E) {
        return {flags__bit(int(a)), flags__bit(int(b)), flags__bit(int(c)), flags__bit(int(d)), flags__bit(int(e)), flags__bit(int(f)), flags__bit(int(g))}
    }

    flags__of_8 :: proc(a, b, c, d, e, f, g, h: $E) -> Bits where intrinsics.type_is_enum(E) {
        return {flags__bit(int(a)), flags__bit(int(b)), flags__bit(int(c)), flags__bit(int(d)), flags__bit(int(e)), flags__bit(int(f)), flags__bit(int(g)), flags__bit(int(h))}
    }

    @(private)
    flags__holds :: #force_inline proc "contextless" (e: Bits, m: Bits, op: Flags_Op) -> bool {
        switch op {
        case .And:   return m <= e
        case .Or:    return e & m != {}
        case .Xor:   return card(e & m) == 1
        case .Nor:   return e & m == {}
        case .Nand:  return !(m <= e)
        case .Exact: return e == m
        }
        return false
    }

    @(private)
    flags__implies_row :: #force_inline proc "contextless" (m: Bits, op: Flags_Op) -> bool {
        #partial switch op {
        case .And, .Or, .Xor: return true
        case .Exact:          return m != {}
        }
        return false
    }

///////////////////////////////////////////////////////////////////////////////
// Lifecycle

    flags_table__init :: proc(self: ^Flags_Table, db: ^Database, cap: int, loc := #caller_location) -> Error {
        compact_table__init(&self.compact, db, cap, loc = loc) or_return
        self.type = Table_Type.Flags_Table
        return nil
    }

    flags_table__terminate :: proc(self: ^Flags_Table) -> Error {
        when VALIDATIONS do assert(self != nil)
        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        return flags_table__terminate_raw(self)
    }

    @(private)
    flags_table__terminate_raw :: proc(self: ^Flags_Table) -> Error {
        for sub in self.flags_subscribers.items do sub.view.state = Object_State.Invalid
        if self.flags_subscribers.items != nil do oc.dense_arr__terminate(&self.flags_subscribers, self.db.allocator) or_return
        self.flags_subscribers = {}
        self.flags_mask = {}
        return compact_table_raw__terminate(cast(^Compact_Table_Raw) self)
    }

    flags_table__is_valid :: proc(self: ^Flags_Table) -> bool {
        if self == nil do return false
        if self.type != Table_Type.Flags_Table do return false
        if !compact_table_base__is_valid(&self.base) do return false
        if self.rows == nil do return false
        return oc.dense_arr__is_valid_or_empty(&self.flags_subscribers)
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    flags_table__bits_of :: #force_inline proc "contextless" (self: ^Flags_Table, eid: entity_id) -> Bits #no_bounds_check {
        rid := oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix))
        if rid == oc_maps.RH_MAP32_DELETED do return {}
        return self.rows[rid]
    }

    // The one mutation point: keeps the row iff the bits are non-empty.
    @(private)
    flags_table__change :: proc(self: ^Flags_Table, eid: entity_id, new: Bits) -> Error {
        old := flags_table__bits_of(self, eid)
        if old == new do return nil

        if old == {} {
            new_bits := new
            _, aerr := compact_table_raw__add_component(cast(^Compact_Table_Raw) self, eid, &new_bits)
            if aerr != nil do return aerr
        } else if new == {} {
            compact_table_raw__remove_component(cast(^Compact_Table_Raw) self, eid) or_return
        } else {
            rid := oc_maps.rh_map32__get(&self.eid_to_rid, u32(eid.ix))
            self.rows[rid] = new
            compact_table_base__mark_touched(&self.base, eid)
            for view in self.subscribers_with_filter.items {
                if !view.suspended do view__rerun_filter(view, eid)
            }
        }

        change := Flags_Change{old, new}
        database__notify_observers(self.db, .Flags_Changed, eid, table_id = self.id, data = &change)

        changed := old ~ new
        if changed & self.flags_mask != {} {
            for sub in self.flags_subscribers.items {
                if sub.mask & changed == {} do continue
                if sub.view.suspended {
                    view__missed_update_for_member(sub.view, eid)
                } else {
                    view__reevaluate(sub.view, eid)
                }
            }
        }

        return nil
    }

    // Exact depends on every bit; the other ops only on the term's bits.
    @(private)
    flags__term_mask :: #force_inline proc "contextless" (f: Flags) -> Bits {
        return f.op == Flags_Op.Exact ? ~Bits{} : f.bits
    }

    @(private)
    flags_table__add_raw :: proc(self: ^Flags_Table, eid: entity_id, data: rawptr) -> (component: rawptr, err: Error) {
        if data == nil do return nil, API_Error.Flags_Bits_Cannot_Be_Empty
        bits := (cast(^Bits) data)^
        if bits == {} do return nil, API_Error.Flags_Bits_Cannot_Be_Empty

        existed := flags_table__bits_of(self, eid) != {}
        flags_table__change(self, eid, bits) or_return

        component = compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, eid)
        if existed do err = API_Error.Component_Already_Exist
        return
    }

    @(private)
    flags_table__remove_row :: proc(self: ^Flags_Table, eid: entity_id) -> Error {
        if flags_table__bits_of(self, eid) == {} do return oc.Core_Error.Not_Found
        return flags_table__change(self, eid, {})
    }

///////////////////////////////////////////////////////////////////////////////
// Flags

    flags_table__flag :: proc(self: ^Flags_Table, eid: entity_id, #any_int bit: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(flags_table__is_valid(self), loc = loc)
            assert(bit >= 0 && bit < BIT_SET_VALUES_CAP, "flag bit out of range 0..<128", loc = loc)
        }
        database__is_entity_correct(self.db, eid) or_return

        bits := flags_table__bits_of(self, eid)
        bits += {bit}
        return flags_table__change(self, eid, bits)
    }

    flags_table__flag_enum :: proc(self: ^Flags_Table, eid: entity_id, bit: $E, loc := #caller_location) -> Error where intrinsics.type_is_enum(E) {
        return flags_table__flag(self, eid, int(bit), loc)
    }

    flags_table__unflag :: proc(self: ^Flags_Table, eid: entity_id, #any_int bit: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(flags_table__is_valid(self), loc = loc)
            assert(bit >= 0 && bit < BIT_SET_VALUES_CAP, "flag bit out of range 0..<128", loc = loc)
        }
        database__is_entity_correct(self.db, eid) or_return

        bits := flags_table__bits_of(self, eid)
        bits -= {bit}
        return flags_table__change(self, eid, bits)
    }

    flags_table__unflag_enum :: proc(self: ^Flags_Table, eid: entity_id, bit: $E, loc := #caller_location) -> Error where intrinsics.type_is_enum(E) {
        return flags_table__unflag(self, eid, int(bit), loc)
    }

    @(require_results)
    flags_table__has_flag :: proc(self: ^Flags_Table, eid: entity_id, #any_int bit: int, loc := #caller_location) -> bool {
        when VALIDATIONS do assert(bit >= 0 && bit < BIT_SET_VALUES_CAP, "flag bit out of range 0..<128", loc = loc)
        if database__is_entity_correct(self.db, eid) != nil do return false
        return bit in flags_table__bits_of(self, eid)
    }

    @(require_results)
    flags_table__has_flag_enum :: proc(self: ^Flags_Table, eid: entity_id, bit: $E, loc := #caller_location) -> bool where intrinsics.type_is_enum(E) {
        return flags_table__has_flag(self, eid, int(bit), loc)
    }

    @(require_results)
    flags_table__has_any :: proc(self: ^Flags_Table, eid: entity_id) -> bool {
        if database__is_entity_correct(self.db, eid) != nil do return false
        return flags_table__bits_of(self, eid) != {}
    }

    @(require_results)
    flags_table__has_flags :: proc(self: ^Flags_Table, eid: entity_id, bits: Bits, op := Flags_Op.And) -> bool {
        if database__is_entity_correct(self.db, eid) != nil do return false
        return flags__holds(flags_table__bits_of(self, eid), bits, op)
    }

    @(require_results)
    flags_table__get_flags :: proc(self: ^Flags_Table, eid: entity_id) -> Bits {
        if database__is_entity_correct(self.db, eid) != nil do return {}
        return flags_table__bits_of(self, eid)
    }

    flags_table__set_flags :: proc(self: ^Flags_Table, eid: entity_id, bits: Bits, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(flags_table__is_valid(self), loc = loc)
        database__is_entity_correct(self.db, eid) or_return
        return flags_table__change(self, eid, bits)
    }

    flags_table__clear_flags :: proc(self: ^Flags_Table, eid: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(flags_table__is_valid(self), loc = loc)
        database__is_entity_correct(self.db, eid) or_return
        return flags_table__change(self, eid, {})
    }

///////////////////////////////////////////////////////////////////////////////
// Table

    flags_table__len :: #force_inline proc "contextless" (self: ^Flags_Table) -> int {
        return compact_table_raw__len(cast(^Compact_Table_Raw) self)
    }

    flags_table__cap :: #force_inline proc "contextless" (self: ^Flags_Table) -> int {
        return self.cap
    }

    @(require_results)
    flags_table__slice :: #force_inline proc "contextless" (self: ^Flags_Table) -> []Bits {
        return self.rows
    }

    flags_table__entities_slice :: #force_inline proc "contextless" (self: ^Flags_Table) -> []entity_id {
        return self.rid_to_eid[:flags_table__len(self)]
    }

    flags_table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Flags_Table, #any_int row_number: int) -> entity_id {
        return compact_table_base__get_entity_by_row_number(&self.base, row_number)
    }

    flags_table__memory_usage :: proc(self: ^Flags_Table) -> int {
        return compact_table_base__memory_usage(&self.base) + oc.dense_arr__memory_usage(&self.flags_subscribers)
    }

    // Clears row by row so views, observers and sync all see each entity lose its flags.
    flags_table__clear :: proc(self: ^Flags_Table) -> Error {
        when VALIDATIONS do assert(flags_table__is_valid(self))

        for i := flags_table__len(self) - 1; i >= 0; i -= 1 {
            eid := self.rid_to_eid[i]
            if is_not_set(eid) do continue
            flags_table__change(self, eid, {}) or_return
        }

        return nil
    }

    flags_table__pause_packing :: proc(self: ^Flags_Table) -> Error {
        when VALIDATIONS do assert(flags_table__is_valid(self))
        return compact_table_raw__pause_packing(cast(^Compact_Table_Raw) self)
    }

    flags_table__resume_packing :: proc(self: ^Flags_Table) -> Error {
        when VALIDATIONS do assert(flags_table__is_valid(self))
        return compact_table_raw__resume_packing(cast(^Compact_Table_Raw) self)
    }

    flags_table__pack :: proc(self: ^Flags_Table) -> Error {
        when VALIDATIONS do assert(flags_table__is_valid(self))
        return compact_table_raw__pack(cast(^Compact_Table_Raw) self)
    }

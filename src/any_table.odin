/*
    2026 (c) Oleh, https://github.com/zm69

    Any_Table - a type-erased handle to any table variant (Table, Compact_Table,
    Tiny_Table, Tag_Table, Arch_Table), for tooling that has to work with tables
    it does not know the type of at compile time: data-driven loaders,
    serializers, inspectors, debug dumps.

    It is the public spelling of the ^Shared_Table pointer that group_init takes
    and View_Term (view_init) wraps, so `any_table(&positions)` accepts exactly
    what those accept. Shared_Table itself stays package-private, so an
    Any_Table's fields are not reachable from outside - only the procedures below.
    Any_Table cannot itself be a View_Term variant: a second variant sharing
    ^Shared_Table's underlying type makes every view_init call ambiguous.

    Note this erases the TABLE VARIANT, which costs a switch per call. Table_Raw
    is the different, free erasure: it drops the component type T
    within a variant that is already known. The dispatchers here are built on
    those. Gameplay should keep using ^Table(T) - reach for Any_Table only where
    the type genuinely is not known until runtime.
*/
package ode_ecs

// Base
    import "base:intrinsics"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Any_Table

    Any_Table :: distinct ^Shared_Table

    // Accepts any table variant - they all embed Shared_Table as their first field.
    any_table :: #force_inline proc "contextless" (self: ^Shared_Table) -> Any_Table {
        return Any_Table(self)
    }

    any_table_is_valid :: proc(self: Any_Table) -> bool {
        if self == nil do return false
        return shared_table__is_valid(cast(^Shared_Table) self)
    }

///////////////////////////////////////////////////////////////////////////////
// Metadata

    any_table_id :: #force_inline proc "contextless" (self: Any_Table) -> table_id {
        return (cast(^Shared_Table) self).id
    }

    any_table_type :: #force_inline proc "contextless" (self: Any_Table) -> Table_Type {
        return (cast(^Shared_Table) self).type
    }

    // nil for Tag_Table (no data) and Arch_Table (a row spans several types - use the column procs).
    any_table_component_type :: proc(self: Any_Table) -> typeid {
        ti := shared_table__type_info(cast(^Shared_Table) self)
        return ti.id if ti != nil else nil
    }

    any_table_component_size :: proc(self: Any_Table) -> int {
        ti := shared_table__type_info(cast(^Shared_Table) self)
        return ti.size if ti != nil else 0
    }

    // 0 for Tag_Table, N for Arch_Table, 1 otherwise.
    any_table_column_count :: proc(self: Any_Table) -> int {
        return shared_table__column_count(cast(^Shared_Table) self)
    }

    any_table_column_type :: proc(self: Any_Table, col: int) -> typeid {
        return shared_table__column_type(cast(^Shared_Table) self, col)
    }

    any_table_len :: proc(self: Any_Table) -> int {
        return shared_table__len(cast(^Shared_Table) self)
    }

    any_table_cap :: proc(self: Any_Table) -> int {
        return shared_table__cap(cast(^Shared_Table) self)
    }

    any_table_entities_slice :: proc(self: Any_Table) -> []entity_id {
        return shared_table__rid_to_eid_slice(cast(^Shared_Table) self)
    }

    any_table_get_entity :: proc(self: Any_Table, #any_int row_number: int) -> entity_id {
        return shared_table__get_entity_by_row_number(cast(^Shared_Table) self, row_number)
    }

///////////////////////////////////////////////////////////////////////////////
// Rows
//
// UNSAFE: `data` must match any_table_component_type; tooling only.

    any_table_has_component :: proc(self: Any_Table, eid: entity_id) -> bool {
        return shared_table__has_component(cast(^Shared_Table) self, eid)
    }

    // nil for a Tag_Table or for an entity that has no row here.
    any_table_get_component :: proc(self: Any_Table, eid: entity_id) -> rawptr {
        return shared_table__get_component(cast(^Shared_Table) self, eid)
    }

    any_table_add_component :: proc(self: Any_Table, eid: entity_id, data: rawptr = nil) -> (component: rawptr, err: Error) {
        return shared_table__add_component(cast(^Shared_Table) self, eid, data)
    }

    any_table_remove_component :: proc(self: Any_Table, eid: entity_id) -> Error {
        return shared_table__remove_component(cast(^Shared_Table) self, eid)
    }

    any_table_clear :: proc(self: Any_Table) -> Error {
        return shared_table__clear(cast(^Shared_Table) self)
    }

    any_table_memory_usage :: proc(self: Any_Table) -> int {
        return shared_table__memory_usage(cast(^Shared_Table) self)
    }

///////////////////////////////////////////////////////////////////////////////
// Enumeration
//
// Component tables and tag tables live in two independent registries with
// independent id spaces, so a table_id only identifies a table together with
// its Table_Type.

    // Fills `buf` with every table attached to `db`, component tables first, then tag tables.
    any_tables :: proc(db: ^Database, buf: []Any_Table) -> (res: []Any_Table, err: Error) {
        when VALIDATIONS {
            assert(db != nil)
        }

        n := 0
        for t in db.tables.items {
            if t == nil do continue
            if n >= len(buf) do return buf[:n], oc.Core_Error.Container_Is_Full
            buf[n] = Any_Table(t)
            n += 1
        }

        for t in db.tag_tables.items {
            if t == nil do continue
            if n >= len(buf) do return buf[:n], oc.Core_Error.Container_Is_Full
            buf[n] = Any_Table(cast(^Shared_Table) t)
            n += 1
        }

        return buf[:n], nil
    }

    any_tables_len :: proc(db: ^Database) -> int {
        when VALIDATIONS {
            assert(db != nil)
        }

        n := 0
        for t in db.tables.items do if t != nil do n += 1
        for t in db.tag_tables.items do if t != nil do n += 1
        return n
    }

    any_table_by_id :: proc(db: ^Database, id: table_id, kind: Table_Type) -> (res: Any_Table, ok: bool) {
        when VALIDATIONS {
            assert(db != nil)
        }

        ix := int(id)
        if ix < 0 do return nil, false

        if kind == Table_Type.Tag_Table {
            if ix >= len(db.tag_tables.items) do return nil, false
            t := db.tag_tables.items[ix]
            if t == nil do return nil, false
            return Any_Table(cast(^Shared_Table) t), true
        }

        if ix >= len(db.tables.items) do return nil, false
        t := db.tables.items[ix]
        if t == nil || t.type != kind do return nil, false
        return Any_Table(t), true
    }

///////////////////////////////////////////////////////////////////////////////
// Entity membership

    // Tables `eid` has a row or tag in, disabled components included.
    entity_tables :: proc(db: ^Database, eid: entity_id, buf: []Any_Table) -> (res: []Any_Table, err: Error) #no_bounds_check {
        when VALIDATIONS {
            assert(db != nil)
        }

        database__is_entity_correct(db, eid) or_return

        n := 0

        add :: #force_inline proc(db: ^Database, buf: []Any_Table, n: ^int, id: int, is_tag: bool) -> bool {
            t: ^Shared_Table
            if is_tag {
                tt := db.tag_tables.items[id]
                if tt == nil do return true
                t = cast(^Shared_Table) tt
            } else {
                t = db.tables.items[id]
                if t == nil do return true
            }

            if n^ >= len(buf) do return false
            buf[n^] = Any_Table(t)
            n^ += 1
            return true
        }

        bits := db.eid_to_bits[eid.ix]
        tag_bits: Uni_Bits
        if db.eid_to_tag_bits != nil do tag_bits = db.eid_to_tag_bits[eid.ix]

        when TABLES_MULT == 1 {
            v := transmute(u128) bits
            for v != 0 {
                id := int(intrinsics.count_trailing_zeros(v))
                v &= v - 1
                if !add(db, buf, &n, id, false) do return buf[:n], oc.Core_Error.Container_Is_Full
            }

            tv := transmute(u128) tag_bits
            for tv != 0 {
                id := int(intrinsics.count_trailing_zeros(tv))
                tv &= tv - 1
                if !add(db, buf, &n, id, true) do return buf[:n], oc.Core_Error.Container_Is_Full
            }
        } else {
            for word, wi in bits.value {
                v := transmute(u128) word
                for v != 0 {
                    b := int(intrinsics.count_trailing_zeros(v))
                    v &= v - 1
                    if !add(db, buf, &n, wi * BIT_SET_VALUES_CAP + b, false) do return buf[:n], oc.Core_Error.Container_Is_Full
                }
            }

            for word, wi in tag_bits.value {
                tv := transmute(u128) word
                for tv != 0 {
                    b := int(intrinsics.count_trailing_zeros(tv))
                    tv &= tv - 1
                    if !add(db, buf, &n, wi * BIT_SET_VALUES_CAP + b, true) do return buf[:n], oc.Core_Error.Container_Is_Full
                }
            }
        }

        return buf[:n], nil
    }

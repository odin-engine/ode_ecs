/*
    2026 (c) Oleh, https://github.com/zm69

    clone_component copies a component between two ENTITIES within one table;
    copy_component copies one entity's component between two TABLES. Prototype/prefab
    instantiation wants this direction: materialize an instance from a template entity.

    The value is read out before the destination row is added, because adding a
    row to a Group-owned table can swap rows and move the source.
*/
package ode_ecs

// Core
    import "core:mem"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Typed

    table__clone_component :: proc(self: ^Table($T), src_eid: entity_id, dst_eid: entity_id) -> (component: ^T, err: Error) {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.type_info.id == typeid_of(T))
        }

        database__is_entity_correct(self.db, src_eid) or_return
        database__is_entity_correct(self.db, dst_eid) or_return

        src := cast(^T) table_raw__get_component_by_entity(cast(^Table_Raw) self, src_eid)
        if src == nil do return nil, oc.Core_Error.Not_Found

        if src_eid == dst_eid do return src, nil

        value := src^

        component = cast(^T) table_raw__get_component_by_entity(cast(^Table_Raw) self, dst_eid)
        if component == nil {
            c, aerr := table_raw__add_component(cast(^Table_Raw) self, dst_eid)
            if aerr != nil do return nil, aerr
            component = cast(^T) c
        }

        component^ = value

        return component, nil
    }

    compact_table__clone_component :: proc(self: ^Compact_Table($T), src_eid: entity_id, dst_eid: entity_id) -> (component: ^T, err: Error) {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.type_info.id == typeid_of(T))
        }

        database__is_entity_correct(self.db, src_eid) or_return
        database__is_entity_correct(self.db, dst_eid) or_return

        src := cast(^T) compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, src_eid)
        if src == nil do return nil, oc.Core_Error.Not_Found

        if src_eid == dst_eid do return src, nil

        value := src^

        component = cast(^T) compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, dst_eid)
        if component == nil {
            c, aerr := compact_table_raw__add_component(cast(^Compact_Table_Raw) self, dst_eid)
            if aerr != nil do return nil, aerr
            component = cast(^T) c
        }

        component^ = value

        return component, nil
    }

    tiny_table__clone_component :: proc(self: ^Tiny_Table($T), src_eid: entity_id, dst_eid: entity_id) -> (component: ^T, err: Error) {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.type_info.id == typeid_of(T))
        }

        database__is_entity_correct(self.db, src_eid) or_return
        database__is_entity_correct(self.db, dst_eid) or_return

        src := cast(^T) tiny_table_base__get_component_by_entity(&self.base, src_eid)
        if src == nil do return nil, oc.Core_Error.Not_Found

        if src_eid == dst_eid do return src, nil

        value := src^

        component = cast(^T) tiny_table_base__get_component_by_entity(&self.base, dst_eid)
        if component == nil {
            c, aerr := tiny_table_raw__add_component(cast(^Tiny_Table_Raw) self, dst_eid)
            if aerr != nil do return nil, aerr
            component = cast(^T) c
        }

        component^ = value

        return component, nil
    }

///////////////////////////////////////////////////////////////////////////////
// Type-erased
//
// What a data-driven baker calls: clone every configured component onto a fresh
// instance without knowing any of their types.

    // Tagging dst is the whole job for a Tag_Table; Arch_Table is rejected, its row spans several columns.
    any_table_clone_component :: proc(self: Any_Table, src_eid: entity_id, dst_eid: entity_id) -> Error {
        st := cast(^Shared_Table) self

        when VALIDATIONS {
            assert(st != nil)
        }

        if st.type == Table_Type.Arch_Table do return API_Error.Table_Type_Not_Supported

        database__is_entity_correct(st.db, src_eid) or_return
        database__is_entity_correct(st.db, dst_eid) or_return

        if !shared_table__has_component(st, src_eid) do return oc.Core_Error.Not_Found
        if src_eid == dst_eid do return nil

        if st.type == Table_Type.Tag_Table {
            return tag_table__add_tag(cast(^Tag_Table) st, dst_eid)
        }

        elem_size := shared_table__type_info(st).size

        if !shared_table__has_component(st, dst_eid) {
            _, aerr := shared_table__add_component(st, dst_eid)
            if aerr != nil do return aerr
        }

        // Re-fetch: adding a row can move existing ones in a Group-owned table.
        src := shared_table__get_component(st, src_eid)
        dst := shared_table__get_component(st, dst_eid)
        if src == nil || dst == nil do return API_Error.Unexpected_Error

        mem.copy(dst, src, elem_size)

        return nil
    }

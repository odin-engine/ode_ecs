/*
    2026 (c) Oleh, https://github.com/zm69

    Inherited lookup: walk an entity's Relations_Table parent chain, nearest
    first, and answer with the first ancestor that satisfies something. The
    entity itself is always checked first, so a local value beats an inherited
    one.

    find_up is the primitive; get_component_up/has_tag_up are the two wrappers. 
    All of them take the relations-owning ^Database explicitly
    instead of implying table.db, so the table and the hierarchy may live in
    different Databases that share one Overbase — the
    config/state split an object system typically wants. With no
    Relations_Table on `db` the chain is just the entity itself.
*/
package ode_ecs

///////////////////////////////////////////////////////////////////////////////
// find_up

    // First entity at or above `eid` for which `pred` is true.
    find_up :: proc(db: ^Database, eid: entity_id, user_data: rawptr, pred: proc(eid: entity_id, user_data: rawptr) -> bool) -> (found: entity_id, ok: bool) #no_bounds_check {
        when VALIDATIONS {
            assert(db != nil)
            assert(pred != nil)
        }

        found.ix = DELETED_INDEX

        if database__is_entity_correct(db, eid) != nil do return found, false

        current := eid
        for {
            if pred(current, user_data) do return current, true

            if db.relations == nil || db.relations.state != Object_State.Normal do break

            p := db.relations.parent[current.ix]
            if is_not_set(p) do break
            current = p
        }

        return found, false
    }

///////////////////////////////////////////////////////////////////////////////
// get_component_up

    table__get_component_up :: proc(self: ^Table($T), db: ^Database, eid: entity_id) -> (component: ^T, source: entity_id, ok: bool) #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil)
            assert(db != nil)
            assert(self.type_info.id == typeid_of(T))
        }

        source.ix = DELETED_INDEX

        if database__is_entity_correct(db, eid) != nil do return nil, source, false

        current := eid
        for {
            c := cast(^T) table_raw__get_component_by_entity(cast(^Table_Raw) self, current)
            if c != nil do return c, current, true

            if db.relations == nil || db.relations.state != Object_State.Normal do break

            p := db.relations.parent[current.ix]
            if is_not_set(p) do break
            current = p
        }

        return nil, source, false
    }

    compact_table__get_component_up :: proc(self: ^Compact_Table($T), db: ^Database, eid: entity_id) -> (component: ^T, source: entity_id, ok: bool) #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil)
            assert(db != nil)
            assert(self.type_info.id == typeid_of(T))
        }

        source.ix = DELETED_INDEX

        if database__is_entity_correct(db, eid) != nil do return nil, source, false

        current := eid
        for {
            c := cast(^T) compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, current)
            if c != nil do return c, current, true

            if db.relations == nil || db.relations.state != Object_State.Normal do break

            p := db.relations.parent[current.ix]
            if is_not_set(p) do break
            current = p
        }

        return nil, source, false
    }

    tiny_table__get_component_up :: proc(self: ^Tiny_Table($T), db: ^Database, eid: entity_id) -> (component: ^T, source: entity_id, ok: bool) #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil)
            assert(db != nil)
            assert(self.type_info.id == typeid_of(T))
        }

        source.ix = DELETED_INDEX

        if database__is_entity_correct(db, eid) != nil do return nil, source, false

        current := eid
        for {
            c := cast(^T) tiny_table_base__get_component_by_entity(&self.base, current)
            if c != nil do return c, current, true

            if db.relations == nil || db.relations.state != Object_State.Normal do break

            p := db.relations.parent[current.ix]
            if is_not_set(p) do break
            current = p
        }

        return nil, source, false
    }

///////////////////////////////////////////////////////////////////////////////
// has_tag_up

    tag_table__has_tag_up :: proc(self: ^Tag_Table, db: ^Database, eid: entity_id) -> (source: entity_id, ok: bool) #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil)
            assert(db != nil)
        }

        source.ix = DELETED_INDEX

        if database__is_entity_correct(db, eid) != nil do return source, false

        current := eid
        for {
            if tag_table__has_tag(self, current) do return current, true

            if db.relations == nil || db.relations.state != Object_State.Normal do break

            p := db.relations.parent[current.ix]
            if is_not_set(p) do break
            current = p
        }

        return source, false
    }

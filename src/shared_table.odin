/*
    2025 (c) Oleh, https://github.com/zm69
*/

// Everything is private here
#+private 

package ode_ecs

// Base
    import "base:runtime"

///////////////////////////////////////////////////////////////////////////////
// Shared_Table - data shared between all tables

    Shared_Table :: struct {
        state: Object_State,
        type: Table_Type,
        id: table_id,
        db: ^Database,

        pause_packing: bool,

        owns_memory: bool,
    }

    @(private)
    shared_table__is_valid_internal :: proc(self: ^Shared_Table) -> bool {
        if self == nil do return false 
        if self.state != Object_State.Normal do return false 
        if self.type == Table_Type.Auto do return false 
        if self.id < 0 do return false 
        if self.db == nil do return false 

        return true
    }

    shared_table__init :: proc(self: ^Shared_Table, type: Table_Type, db: ^Database) {

        shared_table__clear_state(self)

        self.type = type
        self.db = db
    }

    shared_table__terminate :: proc(self: ^Shared_Table) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                table_raw__terminate(cast(^Table_Raw)self) or_return
            case Table_Type.Tiny_Table:
                tiny_table_base__terminate(cast(^Tiny_Table_Base)self) or_return
            case Table_Type.Compact_Table:
                compact_table_raw__terminate(cast(^Compact_Table_Raw)self) or_return
            case Table_Type.Tag_Table:
                tag_table__terminate(cast(^Tag_Table)self) or_return
            case Table_Type.Arch_Table:
                arch_table__terminate(cast(^Arch_Table)self) or_return
        }

        return nil
    }

    shared_table__clear_state :: proc(self: ^Shared_Table) {
        self.state = Object_State.Not_Initialized
        self.type = Table_Type.Auto
        self.id  = DELETED_INDEX
        self.db = nil
        self.pause_packing = false
        self.owns_memory = false
    }

    shared_table__is_valid :: proc(self: ^Shared_Table) -> bool {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__is_valid(cast(^Table_Base) self)
            case Table_Type.Tiny_Table:
                return tiny_table_base__is_valid(cast(^Tiny_Table_Base) self)
            case Table_Type.Compact_Table:
                return compact_table_base__is_valid(cast(^Compact_Table_Base) self)
            case Table_Type.Tag_Table:
                return tag_table__is_valid(cast(^Tag_Table)self)
            case Table_Type.Arch_Table:
                return arch_table__is_valid(cast(^Arch_Table)self)
        }

        assert(false)
        return true
    }

    shared_table__memory_usage :: proc(self: ^Shared_Table) -> int {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__memory_usage(cast(^Table_Base) self)
            case Table_Type.Tiny_Table:
                return tiny_table_base__memory_usage(cast(^Tiny_Table_Base) self)
            case Table_Type.Compact_Table:
                return compact_table_base__memory_usage(cast(^Compact_Table_Base) self)
            case Table_Type.Tag_Table:
                return tag_table__memory_usage(cast(^Tag_Table)self)
            case Table_Type.Arch_Table:
                return arch_table__memory_usage(cast(^Arch_Table) self)
        } 

        assert(false)
        return DELETED_INDEX
    }

    shared_table__len :: proc(self: ^Shared_Table) -> int {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_raw__len(cast(^Table_Raw)self)
            case Table_Type.Tiny_Table:
                return tiny_table_base__len(cast(^Tiny_Table_Base) self)
            case Table_Type.Compact_Table:
                return compact_table_raw__len(cast(^Compact_Table_Raw)self)
            case Table_Type.Tag_Table:
                return tag_table__len(cast(^Tag_Table)self)
            case Table_Type.Arch_Table:
                return arch_table__len(cast(^Arch_Table)self)
        } 

        assert(false)
        return DELETED_INDEX
    }

    shared_table__cap :: proc(self: ^Shared_Table) -> int {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__cap(cast(^Table_Base)self)
            case Table_Type.Tiny_Table:
                return tiny_table_base__cap(cast(^Tiny_Table_Base)self)
            case Table_Type.Compact_Table:
                return compact_table_base__cap(cast(^Compact_Table_Base)self)
            case Table_Type.Tag_Table:
                return tag_table__cap(cast(^Tag_Table)self)
            case Table_Type.Arch_Table:
                return arch_table__cap(cast(^Arch_Table)self)
        } 

        assert(false)
        return DELETED_INDEX
    }

    @(private)
    shared_table__rid_to_eid_slice :: proc (self: ^Shared_Table) -> []entity_id {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                t := cast(^Table_Raw) self
                return t.rid_to_eid[:len(t.rows)]
            case Table_Type.Tiny_Table:
                t := cast(^Tiny_Table_Base) self
                return t.rid_to_eid[:t.len]
            case Table_Type.Compact_Table:
                t := cast(^Compact_Table_Raw) self
                return t.rid_to_eid[:len(t.rows)]
            case Table_Type.Tag_Table:
                return (cast(^Tag_Table) self).rows
            case Table_Type.Arch_Table:
                t := cast(^Arch_Table) self
                return t.rid_to_eid[:t.len]
        }

        assert(false)
        return nil
    }

    shared_table__get_entity_by_row_number :: proc (self: ^Shared_Table, #any_int row_number: int) -> entity_id {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__get_entity_by_row_number(cast(^Table_Base) self, row_number)
            case Table_Type.Tiny_Table: 
                return tiny_table_base__get_entity_by_row_number(cast(^Tiny_Table_Base) self, row_number)
            case Table_Type.Compact_Table:
                return compact_table_base__get_entity_by_row_number(cast(^Compact_Table_Base) self, row_number)
            case Table_Type.Tag_Table:
               return tag_table__get_entity_by_row_number(cast(^Tag_Table) self, row_number)
            case Table_Type.Arch_Table:
                return arch_table__get_entity_by_row_number(cast(^Arch_Table) self, row_number)
        } 

        assert(false)
        return entity_id{ix = DELETED_INDEX}
    }

    shared_table__type_info :: proc(self: ^Shared_Table) -> ^runtime.Type_Info {
        #partial switch self.type {
            case Table_Type.Table:
                return (cast(^Table_Base) self).type_info
            case Table_Type.Compact_Table:
                return (cast(^Compact_Table_Base) self).type_info
            case Table_Type.Tiny_Table:
                return (cast(^Tiny_Table_Base) self).type_info
        }
        return nil
    }

    shared_table__get_component :: proc (self: ^Shared_Table, eid: entity_id) -> rawptr {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_raw__get_component_by_entity(cast(^Table_Raw) self, eid)
            case Table_Type.Tiny_Table: 
                return tiny_table_base__get_component_by_entity(cast(^Tiny_Table_Base) self, eid)
            case Table_Type.Compact_Table:
                return compact_table_raw__get_component_by_entity(cast(^Compact_Table_Raw) self, eid)
            case Table_Type.Tag_Table:
                return nil
            case Table_Type.Arch_Table:
                return nil
        }

        assert(false)
        return nil
    } 

    shared_table__add_component :: proc (self: ^Shared_Table, eid: entity_id, data: rawptr = nil) -> (component: rawptr, err: Error) {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_raw__add_component(cast(^Table_Raw) self, eid, data)
            case Table_Type.Tiny_Table:
                return tiny_table_raw__add_component(cast(^Tiny_Table_Raw) self, eid, data)
            case Table_Type.Compact_Table:
                return compact_table_raw__add_component(cast(^Compact_Table_Raw) self, eid, data)
            case Table_Type.Tag_Table:
                return nil, tag_table__add_tag(cast(^Tag_Table) self, eid)
            case Table_Type.Arch_Table:
                return arch_table__add_entity_from_payload(cast(^Arch_Table) self, eid, data)
        }

        assert(false)
        return nil, API_Error.Unexpected_Error
    }

    shared_table__remove_component :: proc (self: ^Shared_Table, eid: entity_id) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_raw__remove_component(cast(^Table_Raw) self, eid)
            case Table_Type.Tiny_Table: 
                return tiny_table_raw__remove_component(cast(^Tiny_Table_Raw) self, eid)
            case Table_Type.Compact_Table:
                return compact_table_raw__remove_component(cast(^Compact_Table_Raw) self, eid)
            case Table_Type.Tag_Table:
                return tag_table__remove_tag(cast(^Tag_Table) self, eid)
            case Table_Type.Arch_Table:
                return arch_table__remove_entity(cast(^Arch_Table) self, eid)
        }

        assert(false)
        return API_Error.Unexpected_Error
    }

    shared_table__pack :: proc (self: ^Shared_Table) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_raw__pack(cast(^Table_Raw) self)
            case Table_Type.Tiny_Table:
                return tiny_table_raw__pack(cast(^Tiny_Table_Raw) self)
            case Table_Type.Compact_Table:
                return compact_table_raw__pack(cast(^Compact_Table_Raw) self)
            case Table_Type.Tag_Table:
                return tag_table__pack(cast(^Tag_Table) self)
            case Table_Type.Arch_Table:
                return arch_table__pack(cast(^Arch_Table) self)
        }

        assert(false)
        return API_Error.Unexpected_Error
    }

    shared_table__is_packing_paused :: #force_inline proc "contextless" (self: ^Shared_Table) -> bool {
        return self.db.tail_swap_paused || self.pause_packing
    }

    shared_table__clear :: proc (self: ^Shared_Table) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_raw__clear(cast(^Table_Raw) self)
            case Table_Type.Tiny_Table: 
                return tiny_table_raw__clear(cast(^Tiny_Table_Raw) self)
            case Table_Type.Compact_Table:
                return compact_table_raw__clear(cast(^Compact_Table_Raw) self)
            case Table_Type.Tag_Table:
                return tag_table__clear(cast(^Tag_Table)self)
            case Table_Type.Arch_Table:
                return arch_table__clear(cast(^Arch_Table) self)
        }

        return API_Error.Unexpected_Error
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    shared_table__attach_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error { 
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__attach_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__attach_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__attach_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__attach_subscriber(cast(^Tag_Table)self, view)
            case Table_Type.Arch_Table:
                return arch_table__attach_subscriber(cast(^Arch_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__detach_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__detach_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__detach_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__detach_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__detach_subscriber(cast(^Tag_Table)self, view)
            case Table_Type.Arch_Table:
                return arch_table__detach_subscriber(cast(^Arch_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__subscribers :: proc(self: ^Shared_Table) -> []^View {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return (cast(^Table_Base) self).subscribers.items
            case Table_Type.Tiny_Table:
                slot := tiny_table_base__slot(cast(^Tiny_Table_Base) self)
                return slot.subscribers[:]
            case Table_Type.Compact_Table:
                return (cast(^Compact_Table_Base) self).subscribers.items
            case Table_Type.Tag_Table:
                return (cast(^Tag_Table) self).subscribers.items
            case Table_Type.Arch_Table:
                return (cast(^Arch_Table) self).subscribers.items
        }

        return nil
    }

    @(private)
    shared_table__attach_exclude_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__attach_exclude_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__attach_exclude_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__attach_exclude_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__attach_exclude_subscriber(cast(^Tag_Table)self, view)
            case Table_Type.Arch_Table:
                return arch_table__attach_exclude_subscriber(cast(^Arch_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__detach_exclude_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__detach_exclude_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__detach_exclude_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__detach_exclude_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__detach_exclude_subscriber(cast(^Tag_Table)self, view)
            case Table_Type.Arch_Table:
                return arch_table__detach_exclude_subscriber(cast(^Arch_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__attach_any_of_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__attach_any_of_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__attach_any_of_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__attach_any_of_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__attach_any_of_subscriber(cast(^Tag_Table)self, view)
            case Table_Type.Arch_Table:
                return arch_table__attach_any_of_subscriber(cast(^Arch_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__detach_any_of_subscriber :: proc(self: ^Shared_Table, view: ^View) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__detach_any_of_subscriber(cast(^Table_Base)self, view)
            case Table_Type.Tiny_Table:
                return tiny_table_base__detach_any_of_subscriber(cast(^Tiny_Table_Base)self, view)
            case Table_Type.Compact_Table:
                return compact_table_base__detach_any_of_subscriber(cast(^Compact_Table_Base)self, view)
            case Table_Type.Tag_Table:
                return tag_table__detach_any_of_subscriber(cast(^Tag_Table)self, view)
            case Table_Type.Arch_Table:
                return arch_table__detach_any_of_subscriber(cast(^Arch_Table)self, view)
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__attach_sync_channel :: proc(self: ^Shared_Table, ch: ^Sync_Channel) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__attach_sync_channel(cast(^Table_Base)self, ch)
            case Table_Type.Tiny_Table:
                return tiny_table_base__attach_sync_channel(cast(^Tiny_Table_Base)self, ch)
            case Table_Type.Compact_Table:
                return compact_table_base__attach_sync_channel(cast(^Compact_Table_Base)self, ch)
            case Table_Type.Tag_Table:
                return tag_table__attach_sync_channel(cast(^Tag_Table)self, ch)
            case Table_Type.Arch_Table:
                return API_Error.Sync_Table_Type_Not_Supported
        }

        return API_Error.Unexpected_Error
    }

    @(private)
    shared_table__detach_sync_channel :: proc(self: ^Shared_Table, ch: ^Sync_Channel) -> Error {
        switch self.type {
            case Table_Type.Auto:
                assert(false, "Shared_Table.type == Auto - this table pointer was never table_init'd (or terminated and never re-init'd), or it points to memory that was zeroed/reused after init. Common causes: the table's table_init call returned a non-nil Error that went unchecked (e.g. a zero-sized component type — table_init/compact_table__init/tiny_table__init all reject those with API_Error.Component_Size_Cannot_Be_Zero; use Tag_Table for a marker/tag component with no data instead), a table declared as a local variable whose scope ended while a View/Group still held a pointer to it, or a frame/temp allocator that freed the table's backing memory.")
            case Table_Type.Table:
                return table_base__detach_sync_channel(cast(^Table_Base)self, ch)
            case Table_Type.Tiny_Table:
                return tiny_table_base__detach_sync_channel(cast(^Tiny_Table_Base)self, ch)
            case Table_Type.Compact_Table:
                return compact_table_base__detach_sync_channel(cast(^Compact_Table_Base)self, ch)
            case Table_Type.Tag_Table:
                return tag_table__detach_sync_channel(cast(^Tag_Table)self, ch)
            case Table_Type.Arch_Table:
                return API_Error.Sync_Table_Type_Not_Supported
        }

        return API_Error.Unexpected_Error
    }


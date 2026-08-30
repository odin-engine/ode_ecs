/*
    2025 (c) Oleh, https://github.com/zm69 
*/
package ode_ecs

// Base
    import "base:runtime"
    import "base:intrinsics"

// Core
    import "core:slice"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Database

    Database :: struct {
        allocator: runtime.Allocator,
        state: Object_State,

        overbase: ^Overbase,
        owns_overbase: bool,
        overbase_storage: Overbase,

        tables: oc.Sparse_Arr(Shared_Table),

        tag_tables: oc.Sparse_Arr(Tag_Table),

        views: oc.Sparse_Arr(View),

        groups: oc.Dense_Arr(^Group),

        eid_to_bits: []Uni_Bits,

        eid_to_disabled_bits: []Uni_Bits,

        eid_to_tag_bits: []Uni_Bits,

        eid_to_tag_disabled_bits: []Uni_Bits,

        has_disabled_components: bool,

        tiny_table_subscriber_slots: []Tiny_Table_Subscriber_Slot,

        relations: ^Relations_Table,

        pair_tables: oc.Sparse_Arr(Pair_Table_Base),

        command_buffers: oc.Sparse_Arr(Command_Buffer),
        observers: oc.Sparse_Arr(Observer),

        tail_swap_paused: bool,

        destroying_eid_ix: int,
    }

    database__is_valid :: proc(self: ^Database) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.overbase == nil do return false
        if !overbase__is_valid(self.overbase) do return false
        if !oc.sparse_arr__is_valid(&self.tables) do return false
        if !oc.sparse_arr__is_valid(&self.tag_tables) do return false
        if !oc.sparse_arr__is_valid(&self.views) do return false
        if !oc.dense_arr__is_valid(&self.groups) do return false
        if !oc.sparse_arr__is_valid(&self.pair_tables) do return false
        if !oc.sparse_arr__is_valid(&self.command_buffers) do return false
        if !oc.sparse_arr__is_valid(&self.observers) do return false
        if self.eid_to_bits == nil do return false
        if self.eid_to_disabled_bits == nil do return false
        if self.eid_to_tag_bits == nil do return false
        if self.eid_to_tag_disabled_bits == nil do return false
        if self.tiny_table_subscriber_slots == nil do return false

        return true
    }

    database__init :: proc(self: ^Database, entities_cap: u32, allocator := context.allocator, tables_cap: int = TABLES_CAP, views_cap: int = VIEWS_CAP, tiny_tables_cap: int = TINY_TABLES_CAP, pair_tables_cap: int = PAIR_TABLES_CAP, command_buffers_cap: int = COMMAND_BUFFERS_CAP, observers_cap: int = OBSERVERS_CAP) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Not_Initialized)
            assert(tables_cap > 1)
            assert(tables_cap <= BIT_SET_VALUES_CAP * TABLES_MULT, "tables_cap cannot exceed BIT_SET_VALUES_CAP * TABLES_MULT (table ids are Uni_Bits bit indices) — increase ECS_TABLES_MULT to raise this ceiling")
            assert(views_cap > 1)
        }

        if entities_cap == 0 do return API_Error.Entities_Cap_Should_Be_Greater_Than_Zero
        if tables_cap > BIT_SET_VALUES_CAP * TABLES_MULT do return API_Error.Tables_Cap_Exceeds_Compile_Time_Limit

        self.tail_swap_paused = false
        self.destroying_eid_ix = DELETED_INDEX
        self.has_disabled_components = false

        self.allocator = allocator

        overbase__init(&self.overbase_storage, entities_cap, databases_cap = 1, allocator = self.allocator) or_return
        self.overbase = &self.overbase_storage
        self.owns_overbase = true
        overbase__attach_database(self.overbase, self) or_return

        oc.sparse_arr__init(&self.tables, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.tag_tables, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.views, views_cap, self.allocator) or_return
        oc.dense_arr__init(&self.groups, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.pair_tables, pair_tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.command_buffers, command_buffers_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.observers, observers_cap, self.allocator) or_return
        self.tiny_table_subscriber_slots = make([]Tiny_Table_Subscriber_Slot, tiny_tables_cap, self.allocator) or_return

        self.eid_to_bits = make([]Uni_Bits, int(entities_cap), self.allocator) or_return
        self.eid_to_disabled_bits = make([]Uni_Bits, int(entities_cap), self.allocator) or_return
        self.eid_to_tag_bits = make([]Uni_Bits, int(entities_cap), self.allocator) or_return
        self.eid_to_tag_disabled_bits = make([]Uni_Bits, int(entities_cap), self.allocator) or_return

        self.state = Object_State.Normal

        assert(database__is_valid(self))

        return nil
    }

    database__init_from_overbase :: proc(self: ^Database, overbase: ^Overbase, allocator: Maybe(runtime.Allocator) = nil, tables_cap: int = TABLES_CAP, views_cap: int = VIEWS_CAP, tiny_tables_cap: int = TINY_TABLES_CAP, pair_tables_cap: int = PAIR_TABLES_CAP, command_buffers_cap: int = COMMAND_BUFFERS_CAP, observers_cap: int = OBSERVERS_CAP) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Not_Initialized)
            assert(overbase != nil)
            assert(overbase__is_valid(overbase))
            assert(tables_cap > 1)
            assert(tables_cap <= BIT_SET_VALUES_CAP * TABLES_MULT, "tables_cap cannot exceed BIT_SET_VALUES_CAP * TABLES_MULT (table ids are Uni_Bits bit indices) — increase ECS_TABLES_MULT to raise this ceiling")
            assert(views_cap > 1)
        }

        if tables_cap > BIT_SET_VALUES_CAP * TABLES_MULT do return API_Error.Tables_Cap_Exceeds_Compile_Time_Limit

        self.tail_swap_paused = false
        self.destroying_eid_ix = DELETED_INDEX
        self.has_disabled_components = false

        self.allocator = allocator.? or_else overbase.allocator
        self.overbase = overbase
        self.owns_overbase = false
        overbase__attach_database(self.overbase, self) or_return

        oc.sparse_arr__init(&self.tables, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.tag_tables, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.views, views_cap, self.allocator) or_return
        oc.dense_arr__init(&self.groups, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.pair_tables, pair_tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.command_buffers, command_buffers_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.observers, observers_cap, self.allocator) or_return
        self.tiny_table_subscriber_slots = make([]Tiny_Table_Subscriber_Slot, tiny_tables_cap, self.allocator) or_return

        self.eid_to_bits = make([]Uni_Bits, self.overbase.id_factory.cap, self.allocator) or_return
        self.eid_to_disabled_bits = make([]Uni_Bits, self.overbase.id_factory.cap, self.allocator) or_return
        self.eid_to_tag_bits = make([]Uni_Bits, self.overbase.id_factory.cap, self.allocator) or_return
        self.eid_to_tag_disabled_bits = make([]Uni_Bits, self.overbase.id_factory.cap, self.allocator) or_return

        self.state = Object_State.Normal

        assert(database__is_valid(self))

        return nil
    }

    database__terminate :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.eid_to_bits != nil {
            delete(self.eid_to_bits, self.allocator) or_return
            self.eid_to_bits = nil
        }

        if self.eid_to_disabled_bits != nil {
            delete(self.eid_to_disabled_bits, self.allocator) or_return
            self.eid_to_disabled_bits = nil
        }

        if self.eid_to_tag_bits != nil {
            delete(self.eid_to_tag_bits, self.allocator) or_return
            self.eid_to_tag_bits = nil
        }

        if self.eid_to_tag_disabled_bits != nil {
            delete(self.eid_to_tag_disabled_bits, self.allocator) or_return
            self.eid_to_tag_disabled_bits = nil
        }

        for view in self.views.items {
            if view == nil do continue
            if view.state == Object_State.Normal || view.state == Object_State.Invalid {
                view_terminate(view) or_return
            }
        }
        oc.sparse_arr__terminate(&self.views, self.allocator) or_return

        for oc.dense_arr__len(&self.groups) > 0 {
            group__terminate(self.groups.items[0]) or_return
        }
        oc.dense_arr__terminate(&self.groups, self.allocator) or_return

        for pt in self.pair_tables.items {
            if pt == nil do continue
            if pt.state == Object_State.Normal do pair_table_base__terminate(pt) or_return
        }
        oc.sparse_arr__terminate(&self.pair_tables, self.allocator) or_return

        for cb in self.command_buffers.items {
            if cb == nil do continue
            if cb.state == Object_State.Normal do command_buffer__terminate(cb) or_return
        }
        oc.sparse_arr__terminate(&self.command_buffers, self.allocator) or_return

        for o in self.observers.items {
            if o == nil do continue
            if o.state == Object_State.Normal do observer__terminate(o) or_return
        }
        oc.sparse_arr__terminate(&self.observers, self.allocator) or_return

        for table in self.tables.items {
            if table == nil do continue
            owns_memory := table.owns_memory
            if table.state == Object_State.Normal {
                shared_table__terminate(table)
            }
            if owns_memory do free(rawptr(table), self.allocator)
        }
        oc.sparse_arr__terminate(&self.tables, self.allocator) or_return

        for tag in self.tag_tables.items {
            if tag == nil do continue
            owns_memory := tag.owns_memory
            if tag.state == Object_State.Normal {
                tag_table__terminate(tag)
            }
            if owns_memory do free(rawptr(tag), self.allocator)
        }
        oc.sparse_arr__terminate(&self.tag_tables, self.allocator) or_return

        if self.tiny_table_subscriber_slots != nil {
            delete(self.tiny_table_subscriber_slots, self.allocator) or_return
            self.tiny_table_subscriber_slots = nil
        }

        if self.relations != nil && self.relations.state == Object_State.Normal {
            relations_table__terminate(self.relations) or_return
        }
        self.relations = nil

        if self.overbase != nil {
            overbase__detach_database(self.overbase, self)
            if self.owns_overbase {
                overbase__terminate(self.overbase) or_return
            }
        }
        self.overbase = nil
        self.owns_overbase = false

        self.state = Object_State.Not_Initialized
        return nil
    }

    database__clear :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.eid_to_bits != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        err: Error

        for view in self.views.items {
            if view == nil do continue
            verr := view__clear(view)
            if err == nil do err = verr
        }

        for table in self.tables.items {
            if table == nil do continue
            terr := shared_table__clear(table)
            if err == nil do err = terr
        }

        for tag in self.tag_tables.items {
            if tag == nil do continue
            terr := tag_table__clear(tag)
            if err == nil do err = terr
        }

        if self.relations != nil {
            rerr := relations_table__clear(self.relations)
            if err == nil do err = rerr
        }

        slice.zero(self.eid_to_bits)
        slice.zero(self.eid_to_disabled_bits)
        slice.zero(self.eid_to_tag_bits)
        slice.zero(self.eid_to_tag_disabled_bits)
        self.has_disabled_components = false

        if self.owns_overbase {
            oc.ix_gen_factory__clear(&self.overbase.id_factory, bump_gen = true)
        }

        self.tail_swap_paused = false

        return err
    }

    @(require_results)
    database__create_entity :: proc(self: ^Database) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }

        eid, err := overbase__create_entity(self.overbase)
        if err == nil do database__notify_observers(self, .Entity_Created, eid)

        return eid, err
    }

    database__destroy_entity :: #force_inline proc(self: ^Database, eid: entity_id, destroy_children := false) -> Error  {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        return overbase__destroy_entity(self.overbase, eid, destroy_children)
    }

    @(private)
    database__destroy_entity_local :: #force_inline proc(self: ^Database, eid: entity_id, destroy_children: bool) -> Error {
        database__notify_observers(self, .Entity_Destroyed, eid)

        rt := self.relations
        if rt != nil && rt.state == Object_State.Normal {
            if destroy_children && rt.children_count[eid.ix] > 0 {
                tail := 0
                #no_bounds_check {
                    c := rt.first_child[eid.ix]
                    for !is_not_set(c) {
                        when VALIDATIONS do assert(tail < len(rt.scratch), "relations links corrupted — descendant count exceeds cap")
                        rt.scratch[tail] = c
                        tail += 1
                        c = rt.next_sibling[c.ix]
                    }

                    for head := 0; head < tail; head += 1 {
                        c = rt.first_child[rt.scratch[head].ix]
                        for !is_not_set(c) {
                            when VALIDATIONS do assert(tail < len(rt.scratch), "relations links corrupted — descendant count exceeds cap")
                            rt.scratch[tail] = c
                            tail += 1
                            c = rt.next_sibling[c.ix]
                        }
                    }
                }

                for i := tail - 1; i >= 0; i -= 1 {
                    overbase__destroy_entity_impl(self.overbase, rt.scratch[i], false, tolerate_expired = true) or_return
                }
            }

            relations_table__unlink_entity(rt, eid)
        }

        bits := self.eid_to_bits[eid.ix]
        tag_bits := self.eid_to_tag_bits[eid.ix]

        self.destroying_eid_ix = eid.ix
        defer self.destroying_eid_ix = DELETED_INDEX

        when TABLES_MULT == 1 {
            v := transmute(u128) bits
            for v != 0 {
                id := int(intrinsics.count_trailing_zeros(v))
                v &= v - 1
                database__remove_component_by_table_id(self, id, eid) or_return
            }

            tv := transmute(u128) tag_bits
            for tv != 0 {
                id := int(intrinsics.count_trailing_zeros(tv))
                tv &= tv - 1
                database__remove_tag_by_bit_id(self, id, eid) or_return
            }
        } else {
            for word, wi in bits.value {
                v := transmute(u128) word
                for v != 0 {
                    b := int(intrinsics.count_trailing_zeros(v))
                    v &= v - 1
                    database__remove_component_by_table_id(self, wi * BIT_SET_VALUES_CAP + b, eid) or_return
                }
            }

            for word, wi in tag_bits.value {
                tv := transmute(u128) word
                for tv != 0 {
                    b := int(intrinsics.count_trailing_zeros(tv))
                    tv &= tv - 1
                    database__remove_tag_by_bit_id(self, wi * BIT_SET_VALUES_CAP + b, eid) or_return
                }
            }
        }

        for pt in self.pair_tables.items {
            if pt == nil || pt.state != Object_State.Normal do continue
            pair_table_base__remove_target(pt, eid) or_return
            pair_table_base__remove_all(pt, eid) or_return
        }

        uni_bits__clear(&self.eid_to_bits[eid.ix])
        uni_bits__clear(&self.eid_to_tag_bits[eid.ix])
        if self.has_disabled_components {
            uni_bits__clear(&self.eid_to_disabled_bits[eid.ix])
            uni_bits__clear(&self.eid_to_tag_disabled_bits[eid.ix])
        }

        return nil
    }

    @(require_results)
    database__get_entity :: #force_inline proc "contextless" (self: ^Database, #any_int index: int, loc := #caller_location) -> entity_id {
        return overbase__get_entity(self.overbase, index, loc)
    }

    @(require_results)
    database__entities_len :: #force_inline proc "contextless" (self: ^Database) -> int {
        return overbase__entities_len(self.overbase)
    }

    @(require_results)
    database__is_entity_expired :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> bool {
        return overbase__is_entity_expired(self.overbase, eid)
    }

    database__pause_packing :: proc(self: ^Database) {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Normal)
        }

        self.tail_swap_paused = true
    }

    database__resume_packing :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Normal)
        }

        self.tail_swap_paused = false

        // Pack all tables even if one reports an error; first error is reported.
        err: Error
        for table in self.tables.items {
            if table == nil || table.state != Object_State.Normal do continue
            terr := shared_table__pack(table)
            if err == nil do err = terr
        }

        for tag in self.tag_tables.items {
            if tag == nil || tag.state != Object_State.Normal do continue
            terr := tag_table__pack(tag)
            if err == nil do err = terr
        }

        for group in self.groups.items {
            if group.state != Object_State.Normal || !group.dirty do continue
            gerr := group__rebuild(group)
            if err == nil do err = gerr
        }

        return err
    }

    database__memory_usage :: proc (self: ^Database) -> int {
        total := size_of(self^)

        if self.owns_overbase do total += overbase__memory_usage(self.overbase)
        for table in self.tables.items {
            if table != nil do total += shared_table__memory_usage(table)
        }

        for tag in self.tag_tables.items {
            if tag != nil do total += tag_table__memory_usage(tag)
        }

        for view in self.views.items {
            if view != nil do total += view__memory_usage(view)
        }

        if self.relations != nil do total += relations_table__memory_usage(self.relations)

        for pt in self.pair_tables.items {
            if pt != nil do total += pair_table_base__memory_usage(pt)
        }

        for cb in self.command_buffers.items {
            if cb != nil do total += command_buffer__memory_usage(cb)
        }

        for o in self.observers.items {
            if o != nil do total += observer__memory_usage(o)
        }

        return total
    }

    //
    // Relations (parent/child) — thin wrappers over the database's Relations_Table (relations_table.odin).
    //

    database__set_parent :: proc(self: ^Database, child: entity_id, parent: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
        }
        if self.relations == nil do return API_Error.Relations_Table_Not_Created
        return relations_table__set_parent(self.relations, child, parent, loc)
    }

    database__remove_parent :: proc(self: ^Database, child: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
        }
        if self.relations == nil do return API_Error.Relations_Table_Not_Created
        return relations_table__remove_parent(self.relations, child, loc)
    }

    database__parent_of :: proc(self: ^Database, eid: entity_id) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return entity_id{ix = DELETED_INDEX}, API_Error.Relations_Table_Not_Created
        return relations_table__parent_of(self.relations, eid)
    }

    database__children_of :: proc(self: ^Database, parent: entity_id) -> ([]entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return nil, API_Error.Relations_Table_Not_Created
        return relations_table__children_of(self.relations, parent)
    }

    database__children_count :: proc(self: ^Database, eid: entity_id) -> (int, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return 0, API_Error.Relations_Table_Not_Created
        return relations_table__children_count(self.relations, eid)
    }

    database__is_child_of :: proc(self: ^Database, a: entity_id, b: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__is_child_of(self.relations, a, b)
    }

    database__is_parent_of :: proc(self: ^Database, a: entity_id, b: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__is_parent_of(self.relations, a, b)
    }

    database__has_relations :: proc(self: ^Database, eid: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__has_relations(self.relations, eid)
    }

    database__is_relation_of :: proc(self: ^Database, target: entity_id, eid: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__is_relation_of(self.relations, target, eid)
    }

    database__is_root :: proc(self: ^Database, eid: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__is_root(self.relations, eid)
    }

    database__roots :: proc(self: ^Database) -> ([]entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return nil, API_Error.Relations_Table_Not_Created
        return relations_table__roots(self.relations)
    }

    database__walk_subtree :: proc(self: ^Database, root: entity_id) -> ([]entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return nil, API_Error.Relations_Table_Not_Created
        return relations_table__walk_subtree(self.relations, root)
    }

    database__walk_hierarchy :: proc(self: ^Database) -> ([]entity_id, []int, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return nil, nil, API_Error.Relations_Table_Not_Created
        return relations_table__walk_hierarchy(self.relations)
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    database__attach_table :: proc(self: ^Database, table: ^Shared_Table) -> (id: table_id, err: Error) {
        raw_id: int
        raw_id, err = oc.sparse_arr__add(&self.tables, table)
        table_id_cap := BIT_SET_VALUES_CAP * TABLES_MULT
        if err == oc.Core_Error.Container_Is_Full && self.tables.cap < table_id_cap {
            new_cap := min(self.tables.cap * 2, table_id_cap)
            oc.sparse_arr__resize(&self.tables, new_cap, self.allocator) or_return
            raw_id, err = oc.sparse_arr__add(&self.tables, table)
        }
        if err != nil do return DELETED_INDEX, err

        return cast(table_id) raw_id, nil
    }

    @(private)
    database__detach_table :: proc(self: ^Database, table: ^Shared_Table) {
        oc.sparse_arr__remove_by_index(&self.tables, cast(int) table.id)
    }

    @(private)
    database__attach_tag :: proc(self: ^Database, table: ^Tag_Table) -> (id: table_id, err: Error) {
        raw_id: int
        raw_id, err = oc.sparse_arr__add(&self.tag_tables, table)
        tag_id_cap := BIT_SET_VALUES_CAP * TABLES_MULT
        if err == oc.Core_Error.Container_Is_Full && self.tag_tables.cap < tag_id_cap {
            new_cap := min(self.tag_tables.cap * 2, tag_id_cap)
            oc.sparse_arr__resize(&self.tag_tables, new_cap, self.allocator) or_return
            raw_id, err = oc.sparse_arr__add(&self.tag_tables, table)
        }
        if err != nil do return DELETED_INDEX, err

        return cast(table_id) raw_id, nil
    }

    @(private)
    database__detach_tag :: proc(self: ^Database, table: ^Tag_Table) {
        oc.sparse_arr__remove_by_index(&self.tag_tables, cast(int) table.id)
    }

    @(private)
    database__attach_tiny_table_subscribers :: proc(self: ^Database) -> (slot_id: int, err: Error) {
        for &slot, i in self.tiny_table_subscriber_slots {
            if !slot.in_use {
                slot.in_use = true
                return i, nil
            }
        }

        return DELETED_INDEX, oc.Core_Error.Container_Is_Full
    }

    @(private)
    database__detach_tiny_table_subscribers :: proc(self: ^Database, #any_int slot_id: int) {
        self.tiny_table_subscriber_slots[slot_id] = {}
    }

    @(private)
    database__attach_group :: proc(self: ^Database, group: ^Group) -> Error {
        _, err := oc.dense_arr__add_growing(&self.groups, group, self.allocator)
        return err
    }

    @(private)
    database__detach_group :: proc(self: ^Database, group: ^Group) {
        oc.dense_arr__remove_by_value(&self.groups, group)
    }

    @(private)
    database__attach_view :: proc(self: ^Database, view: ^View) -> (view_id, Error) {
        id, err := oc.sparse_arr__add_growing(&self.views, view, self.allocator)
        if err != nil do return DELETED_INDEX, err

        return cast(view_id) id, nil
    }

    @(private)
    database__detach_view :: proc(self: ^Database, view: ^View) {
        oc.sparse_arr__remove_by_index(&self.views, cast(int) view.id)
    }

    @(private)
    database__attach_pair_table :: proc(self: ^Database, pt: ^Pair_Table_Base) -> (pair_table_id, Error) {
        id, err := oc.sparse_arr__add_growing(&self.pair_tables, pt, self.allocator)
        if err != nil do return DELETED_INDEX, err

        return cast(pair_table_id) id, nil
    }

    @(private)
    database__detach_pair_table :: proc(self: ^Database, pt: ^Pair_Table_Base) {
        oc.sparse_arr__remove_by_index(&self.pair_tables, cast(int) pt.id)
    }

    @(private)
    database__attach_command_buffer :: proc(self: ^Database, cb: ^Command_Buffer) -> (command_buffer_id, Error) {
        id, err := oc.sparse_arr__add_growing(&self.command_buffers, cb, self.allocator)
        if err != nil do return DELETED_INDEX, err

        return cast(command_buffer_id) id, nil
    }

    @(private)
    database__detach_command_buffer :: proc(self: ^Database, cb: ^Command_Buffer) {
        oc.sparse_arr__remove_by_index(&self.command_buffers, cast(int) cb.id)
    }

    @(private)
    database__remove_component_by_table_id :: #force_inline proc(self: ^Database, #any_int id: int, eid: entity_id) -> Error {
        if id >= len(self.tables.items) do return nil
        table := self.tables.items[id]
        if table == nil do return nil

        terr := shared_table__remove_component(table, eid)
        if terr != nil && terr != oc.Core_Error.Not_Found do return terr

        return nil
    }

    @(private)
    database__remove_tag_by_bit_id :: #force_inline proc(self: ^Database, #any_int id: int, eid: entity_id) -> Error {
        if id >= len(self.tag_tables.items) do return nil
        tt := self.tag_tables.items[id]
        if tt == nil do return nil

        terr := tag_table__remove_tag(tt, eid)
        if terr != nil && terr != oc.Core_Error.Not_Found do return terr

        return nil
    }

    @(private)
    database__add_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) #no_bounds_check {
        uni_bits__add(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    database__remove_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) #no_bounds_check {
        uni_bits__remove(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    database__add_tag_bit :: #force_inline proc(self: ^Database, eid: entity_id, id: table_id) #no_bounds_check {
        uni_bits__add(&self.eid_to_tag_bits[eid.ix], id)
    }

    @(private)
    database__remove_tag_bit :: #force_inline proc(self: ^Database, eid: entity_id, id: table_id) #no_bounds_check {
        uni_bits__remove(&self.eid_to_tag_bits[eid.ix], id)
    }

    @(private)
    database__disable_component :: proc(self: ^Database, eid: entity_id, id: table_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(int(id) < len(self.tables.items), loc = loc)
            assert(self.tables.items[int(id)] != nil, loc = loc)
        }
        database__is_entity_correct(self, eid) or_return

        uni_bits__add(&self.eid_to_disabled_bits[eid.ix], id)
        self.has_disabled_components = true

        database__notify_observers(self, .Component_Disabled, eid, table_id = id)

        table := self.tables.items[int(id)]
        for view in shared_table__subscribers(table) {
            if view == nil do continue
            if !view.suspended && !view__components_match(view, eid) do view__remove_record(view, eid)
        }

        return nil
    }

    @(private)
    database__enable_component :: proc(self: ^Database, eid: entity_id, id: table_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(int(id) < len(self.tables.items), loc = loc)
            assert(self.tables.items[int(id)] != nil, loc = loc)
        }
        database__is_entity_correct(self, eid) or_return

        uni_bits__remove(&self.eid_to_disabled_bits[eid.ix], id)

        database__notify_observers(self, .Component_Enabled, eid, table_id = id)

        table := self.tables.items[int(id)]
        for view in shared_table__subscribers(table) {
            if view == nil do continue
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        return nil
    }

    @(private)
    @(require_results)
    database__is_component_disabled :: #force_inline proc "contextless" (self: ^Database, eid: entity_id, id: table_id) -> bool #no_bounds_check {
        return uni_bits__exists(&self.eid_to_disabled_bits[eid.ix], id)
    }

    @(private)
    database__disable_tag :: proc(self: ^Database, eid: entity_id, tag: ^Tag_Table, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(tag != nil, loc = loc)
        }
        database__is_entity_correct(self, eid) or_return

        uni_bits__add(&self.eid_to_tag_disabled_bits[eid.ix], tag.id)
        self.has_disabled_components = true

        database__notify_observers(self, .Component_Disabled, eid, table_id = tag.id)

        for view in tag.subscribers.items {
            if view == nil do continue
            if !view.suspended && !view__components_match(view, eid) do view__remove_record(view, eid)
        }

        return nil
    }

    @(private)
    database__enable_tag :: proc(self: ^Database, eid: entity_id, tag: ^Tag_Table, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(tag != nil, loc = loc)
        }
        database__is_entity_correct(self, eid) or_return

        uni_bits__remove(&self.eid_to_tag_disabled_bits[eid.ix], tag.id)

        database__notify_observers(self, .Component_Enabled, eid, table_id = tag.id)

        for view in tag.subscribers.items {
            if view == nil do continue
            if !view.suspended && view__components_match(view, eid) do view__add_record(view, eid)
        }

        return nil
    }

    @(private)
    @(require_results)
    database__is_tag_disabled :: #force_inline proc "contextless" (self: ^Database, eid: entity_id, id: table_id) -> bool #no_bounds_check {
        return uni_bits__exists(&self.eid_to_tag_disabled_bits[eid.ix], id)
    }

    @(private)
    database__is_entity_correct :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> Error {
        return overbase__is_entity_correct(self.overbase, eid)
    }
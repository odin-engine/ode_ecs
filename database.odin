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

        // Active entity ID space: overbase_storage (owned) or a shared external
        // Overbase attached via database__init_from_overbase. See overbase.odin.
        overbase: ^Overbase,
        owns_overbase: bool,
        overbase_storage: Overbase,

        tables: oc.Sparse_Arr(Shared_Table),

        views: oc.Sparse_Arr(View),

        // Owned groups (group.odin); each owns >= 1 table exclusively,
        // so there can never be more groups than tables.
        groups: oc.Dense_Arr(^Group),

        eid_to_bits: []Uni_Bits,

        // Set bit = table disabled for this entity — still present in eid_to_bits
        // but excluded from query matching until enable_component. See view__components_match.
        eid_to_disabled_bits: []Uni_Bits,

        // Sticky true once any database__disable_component call has run (reset by
        // database__clear, which also zeroes eid_to_disabled_bits); lets
        // view__components_match skip the eid_to_disabled_bits load+check entirely
        // when the feature was never used — the common case.
        has_disabled_components: bool,

        // Batch-allocated View-subscriber bookkeeping for every Tiny_Table in this
        // Database (tiny_table.odin's Tiny_Table_Subscriber_Slot) — Tiny_Table_Base
        // keeps only an index into this slice, not the arrays themselves.
        tiny_table_subscriber_slots: []Tiny_Table_Subscriber_Slot,

        // Optional parent/child relations, at most one per database.
        relations: ^Relations_Table,

        // When true, component removal clears in place (leaving a hole) instead of
        // tail-swapping, so rows/pointers stay stable while iterating.
        // See database__pause_packing / database__resume_packing.
        tail_swap_paused: bool,

        // eid.ix of the entity inside database__destroy_entity's removal loop,
        // DELETED_INDEX otherwise. Lets *__notify_excluding_views skip a dying
        // entity that would otherwise transiently match an excluding view.
        destroying_eid_ix: int,
    }

    database__is_valid :: proc(self: ^Database) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.overbase == nil do return false
        if !overbase__is_valid(self.overbase) do return false
        if !oc.sparse_arr__is_valid(&self.tables) do return false
        if !oc.sparse_arr__is_valid(&self.views) do return false
        if !oc.dense_arr__is_valid(&self.groups) do return false
        if self.eid_to_bits == nil do return false
        if self.eid_to_disabled_bits == nil do return false
        if self.tiny_table_subscriber_slots == nil do return false

        return true
    }

    database__init :: proc(self: ^Database, entities_cap: u32, allocator := context.allocator, tables_cap: int = TABLES_CAP, views_cap: int = VIEWS_CAP, tiny_tables_cap: int = TINY_TABLES_CAP) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Not_Initialized)
            assert(tables_cap > 1)
            assert(tables_cap <= BIT_SET_VALUES_CAP * TABLES_MULT, "tables_cap cannot exceed BIT_SET_VALUES_CAP * TABLES_MULT (table ids are Uni_Bits bit indices) — increase ECS_TABLES_MULT to raise this ceiling")
            assert(views_cap > 1)
        }

        if entities_cap == 0 do return API_Error.Entities_Cap_Should_Be_Greater_Than_Zero
        if tables_cap > BIT_SET_VALUES_CAP * TABLES_MULT do return API_Error.Tables_Cap_Exceeds_Compile_Time_Limit

        // A re-init'd struct (issue #8) may still be paused from its previous
        // life; terminate does not reset the flag.
        self.tail_swap_paused = false
        self.destroying_eid_ix = DELETED_INDEX
        self.has_disabled_components = false

        self.allocator = allocator

        overbase__init(&self.overbase_storage, entities_cap, databases_cap = 1, allocator = self.allocator) or_return
        self.overbase = &self.overbase_storage
        self.owns_overbase = true
        overbase__attach_database(self.overbase, self) or_return

        oc.sparse_arr__init(&self.tables, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.views, views_cap, self.allocator) or_return
        oc.dense_arr__init(&self.groups, tables_cap, self.allocator) or_return
        self.tiny_table_subscriber_slots = make([]Tiny_Table_Subscriber_Slot, tiny_tables_cap, self.allocator) or_return

        self.eid_to_bits = make([]Uni_Bits, int(entities_cap), self.allocator) or_return
        self.eid_to_disabled_bits = make([]Uni_Bits, int(entities_cap), self.allocator) or_return

        self.state = Object_State.Normal

        assert(database__is_valid(self))

        return nil
    }

    // Attach this Database to a shared, already-initialized Overbase instead of
    // creating its own — entity IDs created/destroyed through this Database, a
    // sibling Database on the same Overbase, or the Overbase itself all refer to
    // the same entity set. If allocator is nil, the Overbase's allocator is used.
    // database__terminate will not terminate a shared Overbase — the caller owns
    // its lifetime (see overbase_terminate).
    database__init_from_overbase :: proc(self: ^Database, overbase: ^Overbase, allocator: Maybe(runtime.Allocator) = nil, tables_cap: int = TABLES_CAP, views_cap: int = VIEWS_CAP, tiny_tables_cap: int = TINY_TABLES_CAP) -> Error {
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
        oc.sparse_arr__init(&self.views, views_cap, self.allocator) or_return
        oc.dense_arr__init(&self.groups, tables_cap, self.allocator) or_return
        self.tiny_table_subscriber_slots = make([]Tiny_Table_Subscriber_Slot, tiny_tables_cap, self.allocator) or_return

        self.eid_to_bits = make([]Uni_Bits, self.overbase.id_factory.cap, self.allocator) or_return
        self.eid_to_disabled_bits = make([]Uni_Bits, self.overbase.id_factory.cap, self.allocator) or_return

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

        // Invalid views (their table was terminated) still own their allocations,
        // so they must be terminated too or they leak.
        for view in self.views.items {
            if view == nil do continue
            if view.state == Object_State.Normal || view.state == Object_State.Invalid {
                view_terminate(view) or_return
            }
        }
        oc.sparse_arr__terminate(&self.views, self.allocator) or_return

        // Before tables: releasing table ownership needs live table structs.
        // group__terminate detaches from self.groups, so drain from the front.
        for oc.dense_arr__len(&self.groups) > 0 {
            group__terminate(self.groups.items[0]) or_return
        }
        oc.dense_arr__terminate(&self.groups, self.allocator) or_return

        // Terminating a Tiny_Table calls database__detach_tiny_table_subscribers,
        // which writes into tiny_table_subscriber_slots — so that slice must stay
        // live here, unlike eid_to_bits (freed early; ranging a nil slice is a
        // harmless no-op, but indexing one is not).
        for table in self.tables.items {
            if table == nil do continue
            if table.state == Object_State.Normal {
                shared_table__terminate(table)
            }
        }
        oc.sparse_arr__terminate(&self.tables, self.allocator) or_return

        if self.tiny_table_subscriber_slots != nil {
            delete(self.tiny_table_subscriber_slots, self.allocator) or_return
            self.tiny_table_subscriber_slots = nil
        }

        // Relations_Table is not in self.tables, terminate it explicitly
        // (sets self.relations = nil).
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

        // Leave the db in Not_Initialized state (not Terminated) so the same
        // struct can be re-init'd without zeroing it first. See issue #8.
        self.state = Object_State.Not_Initialized
        return nil
    }

    database__clear :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.eid_to_bits != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        // Clear everything even if some object errors (e.g. a view invalidated by
        // a terminated table) — a partial clear would leave a torn state. First error wins.
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

        if self.relations != nil {
            rerr := relations_table__clear(self.relations)
            if err == nil do err = rerr
        }

        slice.zero(self.eid_to_bits)
        slice.zero(self.eid_to_disabled_bits)
        self.has_disabled_components = false

        // bump_gen so entity ids held across the clear are detected as expired.
        // Only the Database that owns its Overbase may reset the id space —
        // a shared Overbase's ids stay valid for sibling Databases.
        if self.owns_overbase {
            oc.ix_gen_factory__clear(&self.overbase.id_factory, bump_gen = true)
        }

        // A pause taken before the clear must not leak into the new data.
        self.tail_swap_paused = false

        return err
    }

    @(require_results)
    database__create_entity :: proc(self: ^Database) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }

        return overbase__create_entity(self.overbase)
    }

    // #force_inline: collapses into overbase__destroy_entity_impl directly —
    // see the note on overbase__destroy_entity.
    database__destroy_entity :: #force_inline proc(self: ^Database, eid: entity_id, destroy_children := false) -> Error  {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        return overbase__destroy_entity(self.overbase, eid, destroy_children)
    }

    // Local cleanup only: removes eid's components (and, with destroy_children,
    // its descendants per this Database's own Relations_Table) from `self`. Does
    // NOT validate eid and does NOT free the id — overbase__destroy_entity_impl is
    // the sole caller, once per Database attached to the shared Overbase, and owns
    // id validation + the final free.
    //
    // #force_inline: single call site, so no duplication cost — removes a call/return
    // boundary left over from splitting this out of the old monolithic proc.
    @(private)
    database__destroy_entity_local :: #force_inline proc(self: ^Database, eid: entity_id, destroy_children: bool) -> Error {
        // Without a Relations_Table, destroy_children is a no-op — no entity can have children.
        rt := self.relations
        if rt != nil && rt.state == Object_State.Normal {
            if destroy_children && rt.children_count[eid.ix] > 0 {
                // Collect all descendants into rt.scratch as a flat BFS queue (at most
                // rt.count <= rt.cap entries), then destroy deepest-first: each destroyed
                // entity has no remaining children and a still-alive parent, so every
                // unlink is O(1). No recursion — inner calls take destroy_children == false.
                tail := 0
                #no_bounds_check {
                    c := rt.first_child[eid.ix]
                    for !is_not_set(c) {
                        // Overflowing scratch means the links are corrupted (e.g. a parent
                        // cycle) — fail loudly rather than write OOB.
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

                // Fully destroy each descendant (id freed + cleaned from every Database
                // attached to self.overbase). tolerate_expired: a sibling Database's own
                // relations cascade may have already destroyed one of these.
                for i := tail - 1; i >= 0; i -= 1 {
                    overbase__destroy_entity_impl(self.overbase, rt.scratch[i], false, tolerate_expired = true) or_return
                }
            }

            // Unlink from own parent, orphan remaining children.
            relations_table__unlink_entity(rt, eid)
        }

        bits := self.eid_to_bits[eid.ix]

        // Removals below happen in table-id order, so an excluded component can be
        // removed before an included one — without this guard the dying entity would
        // transiently enter views excluding that table. No save/restore needed:
        // destroy_children recursion already completed above.
        self.destroying_eid_ix = eid.ix
        defer self.destroying_eid_ix = DELETED_INDEX

        // Extract only the entity's set bits via count_trailing_zeros — O(components)
        // work, vs. Odin's `for id in bit_set` testing every position of the full
        // 128-bit (x TABLES_MULT) domain regardless of how many bits are set.
        when TABLES_MULT == 1 {
            v := transmute(u128) bits
            for v != 0 {
                id := int(intrinsics.count_trailing_zeros(v))
                v &= v - 1 // clear lowest set bit
                database__remove_component_by_table_id(self, id, eid) or_return
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
        }

        uni_bits__clear(&self.eid_to_bits[eid.ix])
        uni_bits__clear(&self.eid_to_disabled_bits[eid.ix])

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
        // True when eid.gen doesn't match — the id was deleted and its index reused.
        return overbase__is_entity_expired(self.overbase, eid)
    }

    // Pause tail swapping in all tables. While paused, remove_component/destroy_entity
    // clear the component in place (a hole; get_entity returns ix == DELETED_INDEX)
    // instead of moving another row, so it's safe to remove/destroy while iterating.
    database__pause_packing :: proc(self: ^Database) {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Normal)
        }

        self.tail_swap_paused = true
    }

    // Resume tail swapping and pack every table that accumulated holes.
    // O(tables) when nothing was removed.
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

        // Membership changes were deferred while paused (rows could not move);
        // rebuild dirty groups now that every table is packed.
        for group in self.groups.items {
            if group.state != Object_State.Normal || !group.dirty do continue
            gerr := group__rebuild(group)
            if err == nil do err = gerr
        }

        return err
    }

    database__memory_usage :: proc (self: ^Database) -> int {
        total := size_of(self^)

        // Only the owning Database counts Overbase memory, so a shared Overbase is
        // counted once, not once per attached Database (the pointer field itself
        // is already included in size_of(self^) above).
        if self.owns_overbase do total += overbase__memory_usage(self.overbase)
        for table in self.tables.items {
            if table != nil do total += shared_table__memory_usage(table)
        }

        for view in self.views.items {
            if view != nil do total += view__memory_usage(view)
        }

        if self.relations != nil do total += relations_table__memory_usage(self.relations)

        return total
    }

    //
    // Relations (parent/child) — thin wrappers over the database's Relations_Table
    // (relations_table.odin). All return API_Error.Relations_Table_Not_Created
    // until relations_table__init has been called for this database.
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

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    database__attach_table :: proc(self: ^Database, table: ^Shared_Table) -> (id: table_id, err: Error) {
        raw_id: int
        raw_id, err = oc.sparse_arr__add(&self.tables, table)
        // Table ids double as Uni_Bits bit indices, a compile-time-fixed bit_set sized
        // exactly BIT_SET_VALUES_CAP * TABLES_MULT — growth must never cross that
        // ceiling (NOT TABLES_CAP, which is just this array's default initial size).
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
    // Hands out a slot in tiny_table_subscriber_slots for a newly-init'd Tiny_Table
    // (same "first free slot" idiom as Tiny_Table's own attach_subscriber procs).
    // Slots are always zero-valued on return — fresh from make(), or zeroed by
    // database__detach_tiny_table_subscribers on a previous release.
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
        // Not_Found is fine: double-terminate protection
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
    // Removes entity's component from the table with id `id` during entity destruction.
    // Stale bits (table terminated / id reused) are tolerated.
    database__remove_component_by_table_id :: #force_inline proc(self: ^Database, #any_int id: int, eid: entity_id) -> Error {
        if id >= len(self.tables.items) do return nil // stale bit beyond the attached span
        table := self.tables.items[id]
        if table == nil do return nil // stale bit, table slot freed

        terr := shared_table__remove_component(table, eid)
        if terr != nil && terr != oc.Core_Error.Not_Found do return terr

        return nil
    }

    @(private)
    // #no_bounds_check: callers validate eid via database__is_entity_correct,
    // and len(eid_to_bits) == overbase.id_factory.cap
    database__add_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) #no_bounds_check {
        uni_bits__add(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    // #no_bounds_check: see database__add_component
    database__remove_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) #no_bounds_check {
        uni_bits__remove(&self.eid_to_bits[eid.ix], table_id)
    }

    // Component enable/disable — a soft toggle: the component/row stays put (no data
    // movement, no eid_to_bits change), but a disabled table's bit is excluded from
    // query matching (view__components_match) until re-enabled. Disabling can only evict
    // a view member; enabling can only admit one. Reuses the same subscribers list
    // add_component/remove_component walk instead of a new per-type list.
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
    database__is_entity_correct :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> Error {
        return overbase__is_entity_correct(self.overbase, eid)
    }
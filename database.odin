/*
    2025 (c) Oleh, https://github.com/zm69 
*/
package ode_ecs

// Base
    import "base:runtime"
    
// Core
    import "core:slice"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Database

    Database :: struct {
        allocator: runtime.Allocator,
        state: Object_State, 

        id_factory: oc.Ix_Gen_Factory,
        
        tables: oc.Sparce_Arr(Shared_Table),

        views: oc.Sparce_Arr(View),

        eid_to_bits: []Uni_Bits,

        // When true, removing a component from any Table/Compact_Table/Tiny_Table
        // clears it in place (leaving a hole) instead of tail-swapping, so table
        // rows and component pointers stay stable while iterating.
        // See database__pause_tail_swap / database__resume_tail_swap.
        tail_swap_paused: bool,
    }

    database__is_valid :: proc(self: ^Database) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if !oc.ix_gen_factory__is_valid(&self.id_factory) do return false
        if !oc.sparce_arr__is_valid(&self.tables) do return false 
        if !oc.sparce_arr__is_valid(&self.views) do return false
        if self.eid_to_bits == nil do return false 

        return true
    }

    database__init :: proc(self: ^Database, entities_cap: int, allocator := context.allocator) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Not_Initialized)
            assert(TABLES_CAP > 1)
            assert(VIEWS_CAP > 1)
        }

        if entities_cap <= 0 do return API_Error.Entities_Cap_Should_Be_Greater_Than_Zero
        
        self.allocator = allocator

        oc.ix_gen_factory__init(&self.id_factory, entities_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.tables, TABLES_CAP, self.allocator) or_return
        oc.sparse_arr__init(&self.views, VIEWS_CAP, self.allocator) or_return

        self.eid_to_bits = make([]Uni_Bits, entities_cap, self.allocator) or_return

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

        // Views. Invalid views (their table was terminated) still own their
        // allocations, so they must be terminated too or they leak.
        for view in self.views.items {
            if view == nil do continue
            if view.state == Object_State.Normal || view.state == Object_State.Invalid {
                view_terminate(view) or_return
            }
        }
        oc.sparse_arr__terminate(&self.views, self.allocator) or_return

        // Shared Tables
        for table in self.tables.items {
            if table == nil do continue 
            if table.state == Object_State.Normal {
                shared_table__terminate(table)
            } 
        }
        oc.sparse_arr__terminate(&self.tables, self.allocator) or_return 

        oc.ix_gen_factory__terminate(&self.id_factory, self.allocator) or_return

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

        // Clear everything even if some object reports an error (e.g. a view
        // invalidated by a terminated table) — a partial clear would leave the
        // database in a torn state. The first error is still reported.
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

        slice.zero(self.eid_to_bits)

        // bump_gen so entity ids held across the clear are detected as expired
        oc.ix_gen_factory__clear(&self.id_factory, bump_gen = true)

        return err
    }

    @(require_results)
    database__create_entity :: proc(self: ^Database) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        
        return oc.ix_gen_factory__new_id(&self.id_factory)
    }

    database__destroy_entity :: proc(self: ^Database, eid: entity_id) -> Error  {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }
        
        database__is_entity_correct(self, eid) or_return

        bits := self.eid_to_bits[eid.ix]

        // Iterate only the entity's set bits (the tables it belongs to) instead of
        // scanning every attached table — O(components), not O(TABLES_CAP)
        when TABLES_MULT == 1 {
            for id in bits {
                database__remove_component_by_table_id(self, id, eid) or_return
            }
        } else {
            for word, wi in bits.value {
                for b in word {
                    database__remove_component_by_table_id(self, wi * BIT_SET_VALUES_CAP + b, eid) or_return
                }
            }
        }

        // clean bit_sets
        uni_bits__clear(&self.eid_to_bits[eid.ix])

        oc.ix_gen_factory__free_id(&self.id_factory, eid) or_return

        return nil
    }

    @(require_results)
    database__get_entity :: #force_inline proc "contextless" (self: ^Database, #any_int index: int, loc := #caller_location) -> entity_id {
        return oc.ix_gen_factory__get_id(&self.id_factory, index, loc)
    }

    @(require_results)
    database__entities_len :: #force_inline proc "contextless" (self: ^Database) -> int {
        return oc.ix_gen_factory__len(&self.id_factory)
    }

    @(require_results)
    database__is_entity_expired :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> bool {
        // Happens when eid.gen do not match. It means eid expired (was deleted)
        return oc.ix_gen_factory__is_expired(&self.id_factory, eid)
    }

    // Pause tail swapping in all component tables (Table, Compact_Table, Tiny_Table).
    // While paused, remove_component/destroy_entity clear the component in place —
    // the row becomes a hole (get_entity for it returns ix == DELETED_INDEX), no other
    // component moves, and subscribed views are still notified. This makes it safe to
    // remove components/destroy entities while iterating table rows.
    // Note: Tag_Table stores no component data; its rows keep tail swapping.
    database__pause_tail_swap :: proc(self: ^Database) {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Normal)
        }

        self.tail_swap_paused = true
    }

    // Resume tail swapping and pack every table that accumulated holes, so the
    // normal removal path never encounters a hole. O(tables) when nothing was removed.
    database__resume_tail_swap :: proc(self: ^Database) -> Error {
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

        return err
    }

    database__memory_usage :: proc (self: ^Database) -> int {
        total := size_of(self^)

        total += oc.ix_gen_factory__memory_usage(&self.id_factory)
        for table in self.tables.items {
            if table != nil do total += shared_table__memory_usage(table)
        }

        for view in self.views.items {
            if view != nil do total += view__memory_usage(view)
        }

        return total
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    // Returns index of table in self.tables
    @(private)
    database__attach_table :: proc(self: ^Database, table: ^Shared_Table) -> (table_id, Error) {
        id, err := oc.sparse_arr__add(&self.tables, table)
        if err != oc.Core_Error.None do return DELETED_INDEX, err

        return cast(table_id) id, nil
    }

    @(private)
    database__detach_table :: proc(self: ^Database, table: ^Shared_Table) {
        oc.sparse_arr__remove_by_index(&self.tables, cast(int) table.id)
    }

    @(private)
    database__attach_view :: proc(self: ^Database, view: ^View) -> (view_id, Error) {
        id, err := oc.sparse_arr__add(&self.views, view)
        if err != oc.Core_Error.None do return DELETED_INDEX, err

        return cast(view_id) id, nil
    }

    @(private)
    database__detach_view :: proc(self: ^Database, view: ^View) {
        oc.sparse_arr__remove_by_index(&self.views, cast(int) view.id)
    }

    @(private)
    // Removes entity's component from the table with id `id` during entity
    // destruction. Stale bits (table terminated / id reused) are tolerated.
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
    // and len(eid_to_bits) == id_factory.cap
    database__add_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) #no_bounds_check {
        uni_bits__add(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    // #no_bounds_check: see database__add_component
    database__remove_component :: #force_inline proc(self: ^Database, eid: entity_id, table_id: table_id) #no_bounds_check {
        uni_bits__remove(&self.eid_to_bits[eid.ix], table_id)
    }

    @(private)
    database__is_entity_correct :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> Error {
        if eid.ix < 0 || eid.ix >= self.id_factory.cap do return API_Error.Entity_Id_Out_of_Bounds
        if database__is_entity_expired(self, eid) do return API_Error.Entity_Id_Expired
        return nil
    }
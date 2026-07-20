/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_ecs

// Base
    import "base:runtime"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Overbase — a shareable entity ID space. One or more Databases can attach to
// the same Overbase (via database__init or database__init_from_overbase) so
// that the same entity_id refers to the same logical entity across all of
// them. Entity lifecycle (create_entity/destroy_entity) is fully owned by
// Overbase: destroying an entity removes its components from every attached
// Database before the id is freed for reuse, so a recycled index never
// resurfaces stale data in a Database that wasn't told the entity died.

    Overbase :: struct {
        allocator: runtime.Allocator,
        state: Object_State,

        id_factory: oc.Ix_Gen_Factory,

        // Databases currently attached to this Overbase (own or shared),
        // notified in database__destroy_entity_local order when an entity dies.
        databases: oc.Dense_Arr(^Database),

        // Fast path for the common case (exactly one Database attached, the
        // overwhelming majority of Overbases — every plain ecs.init-created
        // Database has one): mirrors databases.items[0], nil whenever the
        // count isn't exactly 1. Lets destroy_entity skip the Dense_Arr walk
        // (length load + loop) entirely instead of iterating a 1-element slice.
        // Maintained by overbase__attach_database / overbase__detach_database.
        primary_database: ^Database,
    }

    overbase__is_valid :: proc(self: ^Overbase) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if !oc.ix_gen_factory__is_valid(&self.id_factory) do return false
        if !oc.dense_arr__is_valid(&self.databases) do return false

        return true
    }

    overbase__init :: proc(self: ^Overbase, entities_cap: int, databases_cap := 1, allocator := context.allocator) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Not_Initialized)
        }

        if entities_cap <= 0 do return API_Error.Entities_Cap_Should_Be_Greater_Than_Zero

        self.allocator = allocator

        oc.ix_gen_factory__init(&self.id_factory, entities_cap, self.allocator) or_return
        oc.dense_arr__init(&self.databases, databases_cap, self.allocator) or_return

        self.state = Object_State.Normal

        assert(overbase__is_valid(self))

        return nil
    }

    overbase__terminate :: proc(self: ^Overbase) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            // Every Database attached to this Overbase must be terminated
            // (which detaches it) before the Overbase itself is terminated.
            assert(oc.dense_arr__len(&self.databases) == 0)
        }

        oc.dense_arr__terminate(&self.databases, self.allocator) or_return
        oc.ix_gen_factory__terminate(&self.id_factory, self.allocator) or_return

        // Not_Initialized (not Terminated) so the struct can be re-init'd
        // without zeroing it first, matching database__terminate. See issue #8.
        self.state = Object_State.Not_Initialized
        return nil
    }

    @(require_results)
    overbase__create_entity :: proc(self: ^Overbase) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }

        return oc.ix_gen_factory__new_id(&self.id_factory)
    }

    // The canonical entity-destroy implementation. Removes the entity's
    // components from every Database attached to this Overbase (recursively,
    // for descendants when destroy_children is set — see
    // database__destroy_entity_local), then frees the id.
    //
    // #force_inline: this and database__destroy_entity are both thin one-line
    // wrappers around overbase__destroy_entity_impl (which cannot itself be
    // force_inline — it recurses for destroy_children); inlining them collapses
    // the call chain to a single proc. With exactly one Database attached
    // (primary_database != nil), destroy_entity's only added cost over the
    // pre-Overbase implementation is the validity/id-free bookkeeping already
    // done today — the Dense_Arr walk is skipped entirely.
    overbase__destroy_entity :: #force_inline proc(self: ^Overbase, eid: entity_id, destroy_children := false) -> Error {
        return overbase__destroy_entity_impl(self, eid, destroy_children, tolerate_expired = false)
    }

    @(require_results)
    overbase__get_entity :: #force_inline proc "contextless" (self: ^Overbase, #any_int index: int, loc := #caller_location) -> entity_id {
        return oc.ix_gen_factory__get_id(&self.id_factory, index, loc)
    }

    @(require_results)
    overbase__entities_len :: #force_inline proc "contextless" (self: ^Overbase) -> int {
        return oc.ix_gen_factory__len(&self.id_factory)
    }

    @(require_results)
    overbase__is_entity_expired :: #force_inline proc "contextless" (self: ^Overbase, eid: entity_id) -> bool {
        return oc.ix_gen_factory__is_expired(&self.id_factory, eid)
    }

    overbase__memory_usage :: proc(self: ^Overbase) -> int {
        total := size_of(self^)

        total += oc.ix_gen_factory__memory_usage(&self.id_factory)
        total += oc.dense_arr__memory_usage(&self.databases)

        return total
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    // A descendant discovered via one Database's relations table may already
    // have been fully destroyed (id freed + cleaned from every attached
    // Database) by another Database's relations cascade — see
    // database__destroy_entity_local. tolerate_expired turns that harmless
    // race into a no-op instead of propagating Entity_Id_Expired.
    overbase__destroy_entity_impl :: proc(self: ^Overbase, eid: entity_id, destroy_children: bool, tolerate_expired: bool) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        if cerr := overbase__is_entity_correct(self, eid); cerr != nil {
            if tolerate_expired && cerr == API_Error.Entity_Id_Expired do return nil
            return cerr
        }

        err: Error
        if self.primary_database != nil {
            // Fast path: exactly one Database attached — skip the Dense_Arr walk.
            err = database__destroy_entity_local(self.primary_database, eid, destroy_children)
        } else {
            for db in self.databases.items {
                derr := database__destroy_entity_local(db, eid, destroy_children)
                if err == nil do err = derr
            }
        }

        ferr := oc.ix_gen_factory__free_id(&self.id_factory, eid)
        if err == nil do err = ferr

        return err
    }

    @(private)
    overbase__is_entity_correct :: #force_inline proc "contextless" (self: ^Overbase, eid: entity_id) -> Error {
        if eid.ix < 0 || eid.ix >= self.id_factory.cap do return API_Error.Entity_Id_Out_of_Bounds
        if overbase__is_entity_expired(self, eid) do return API_Error.Entity_Id_Expired
        return nil
    }

    @(private)
    overbase__attach_database :: proc(self: ^Overbase, db: ^Database) -> Error {
        // Unwrap: dense_arr__add returns oc.Error (itself a union), and oc.Error
        // is also listed as a variant of ode_ecs.Error — returning it as-is would
        // nest it instead of flattening, so it would no longer compare equal to
        // e.g. oc.Core_Error.Container_Is_Full at the call site.
        _, cerr := oc.dense_arr__add(&self.databases, db)
        switch e in cerr {
            case oc.Core_Error:
                return e
            case runtime.Allocator_Error:
                return e
        }
        self.primary_database = oc.dense_arr__len(&self.databases) == 1 ? db : nil
        return nil
    }

    @(private)
    overbase__detach_database :: proc(self: ^Overbase, db: ^Database) {
        // Not_Found is fine: double-terminate protection
        oc.dense_arr__remove_by_value(&self.databases, db)
        self.primary_database = oc.dense_arr__len(&self.databases) == 1 ? self.databases.items[0] : nil
    }

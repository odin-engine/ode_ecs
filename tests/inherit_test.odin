/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for upward hierarchy traversal (ancestors_of, root_of, depth_of,
    is_ancestor_of, is_descendant_of) and inherited lookup (find_up,
    get_component_up, has_tag_up). See relations_table.odin and inherit.odin.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Fixtures

    Inh_Mass :: struct {
        value: f32,
    }

    // physical <- creature <- human <- guard <- guard42, root first.
    Inh_World :: struct {
        db:        ecs.Database,
        rt:        ecs.Relations_Table,
        masses:    ecs.Table(Inh_Mass),
        rope:      ecs.Tag_Table,
        physical:  ecs.entity_id,
        creature:  ecs.entity_id,
        human:     ecs.entity_id,
        guard:     ecs.entity_id,
        guard42:   ecs.entity_id,
        loner:     ecs.entity_id,
    }

    inh_world__init :: proc(w: ^Inh_World, allocator: mem.Allocator) -> ecs.Error {
        ecs.init(&w.db, entities_cap = 32, allocator = allocator) or_return
        ecs.relations_init(&w.rt, &w.db, cap = 32) or_return
        ecs.table_init(&w.masses, &w.db, 32) or_return
        ecs.tag_table_init(&w.rope, &w.db, 32) or_return

        w.physical, _ = ecs.create_entity(&w.db)
        w.creature, _ = ecs.create_entity(&w.db)
        w.human,    _ = ecs.create_entity(&w.db)
        w.guard,    _ = ecs.create_entity(&w.db)
        w.guard42,  _ = ecs.create_entity(&w.db)
        w.loner,    _ = ecs.create_entity(&w.db)

        ecs.set_parent(&w.db, w.creature, w.physical) or_return
        ecs.set_parent(&w.db, w.human,    w.creature) or_return
        ecs.set_parent(&w.db, w.guard,    w.human) or_return
        ecs.set_parent(&w.db, w.guard42,  w.guard) or_return

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Upward traversal

    @(test)
    relations__ancestors_of__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            w: Inh_World
            defer ecs.terminate(&w.db)
            testing.expect(t, inh_world__init(&w, allocator) == nil)

            anc, err := ecs.ancestors_of(&w.db, w.guard42)
            testing.expect(t, err == nil)
            testing.expect(t, len(anc) == 4)
            testing.expect(t, anc[0] == w.guard)
            testing.expect(t, anc[1] == w.human)
            testing.expect(t, anc[2] == w.creature)
            testing.expect(t, anc[3] == w.physical)

            // A root has no ancestors.
            anc, err = ecs.ancestors_of(&w.db, w.physical)
            testing.expect(t, err == nil)
            testing.expect(t, len(anc) == 0)

            // An entity that never touched relations has none either.
            anc, err = ecs.ancestors_of(&w.db, w.loner)
            testing.expect(t, err == nil)
            testing.expect(t, len(anc) == 0)
    }

    @(test)
    relations__root_and_depth__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            w: Inh_World
            defer ecs.terminate(&w.db)
            testing.expect(t, inh_world__init(&w, allocator) == nil)

            r, err := ecs.root_of(&w.db, w.guard42)
            testing.expect(t, err == nil && r == w.physical)

            r, err = ecs.root_of(&w.db, w.physical)
            testing.expect(t, err == nil && r == w.physical)

            r, err = ecs.root_of(&w.db, w.loner)
            testing.expect(t, err == nil && r == w.loner)

            d, derr := ecs.depth_of(&w.db, w.guard42)
            testing.expect(t, derr == nil && d == 4)

            d, derr = ecs.depth_of(&w.db, w.human)
            testing.expect(t, derr == nil && d == 2)

            d, derr = ecs.depth_of(&w.db, w.physical)
            testing.expect(t, derr == nil && d == 0)

            // depth_of agrees with ancestors_of on every node.
            for eid in ([]ecs.entity_id{ w.physical, w.creature, w.human, w.guard, w.guard42, w.loner }) {
                anc, _ := ecs.ancestors_of(&w.db, eid)
                dd, _  := ecs.depth_of(&w.db, eid)
                testing.expect(t, dd == len(anc))
            }
    }

    @(test)
    relations__is_ancestor_of__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            w: Inh_World
            defer ecs.terminate(&w.db)
            testing.expect(t, inh_world__init(&w, allocator) == nil)

            // Non-adjacent pair: is_child_of is direct-link only, is_ancestor_of is not.
            yes, err := ecs.is_ancestor_of(&w.db, w.physical, w.guard42)
            testing.expect(t, err == nil && yes)

            yes, err = ecs.is_child_of(&w.db, w.guard42, w.physical)
            testing.expect(t, err == nil && !yes)

            // Adjacent pair: both agree.
            yes, err = ecs.is_ancestor_of(&w.db, w.guard, w.guard42)
            testing.expect(t, err == nil && yes)

            // Wrong direction, and self.
            yes, err = ecs.is_ancestor_of(&w.db, w.guard42, w.physical)
            testing.expect(t, err == nil && !yes)

            yes, err = ecs.is_ancestor_of(&w.db, w.guard42, w.guard42)
            testing.expect(t, err == nil && !yes)

            yes, err = ecs.is_ancestor_of(&w.db, w.physical, w.loner)
            testing.expect(t, err == nil && !yes)

            // is_descendant_of is the same question with the arguments swapped.
            yes, err = ecs.is_descendant_of(&w.db, w.guard42, w.physical)
            testing.expect(t, err == nil && yes)

            yes, err = ecs.is_descendant_of(&w.db, w.physical, w.guard42)
            testing.expect(t, err == nil && !yes)
    }

    @(test)
    relations__upward_without_relations_table__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 8, allocator = allocator) == nil)

            eid, _ := ecs.create_entity(&db)

            _, err := ecs.ancestors_of(&db, eid)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)

            _, err = ecs.root_of(&db, eid)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)

            _, err = ecs.depth_of(&db, eid)
            testing.expect(t, err == ecs.API_Error.Relations_Table_Not_Created)
    }

///////////////////////////////////////////////////////////////////////////////
// Inherited lookup

    @(test)
    inherit__get_component_up__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            w: Inh_World
            defer ecs.terminate(&w.db)
            testing.expect(t, inh_world__init(&w, allocator) == nil)

            // Mass lives three levels up, on human.
            m, _ := ecs.add_component(&w.masses, w.human)
            m.value = 80

            c, source, ok := ecs.get_component_up(&w.masses, &w.db, w.guard42)
            testing.expect(t, ok)
            testing.expect(t, source == w.human)
            testing.expect(t, c.value == 80)

            // A local value beats the inherited one.
            local, _ := ecs.add_component(&w.masses, w.guard42)
            local.value = 95

            c, source, ok = ecs.get_component_up(&w.masses, &w.db, w.guard42)
            testing.expect(t, ok)
            testing.expect(t, source == w.guard42)
            testing.expect(t, c.value == 95)

            // Removing it falls back up the chain again.
            ecs.remove_component(&w.masses, w.guard42)
            c, source, ok = ecs.get_component_up(&w.masses, &w.db, w.guard42)
            testing.expect(t, ok && source == w.human && c.value == 80)

            // Nearest ancestor wins over a farther one.
            mid, _ := ecs.add_component(&w.masses, w.guard)
            mid.value = 88
            c, source, ok = ecs.get_component_up(&w.masses, &w.db, w.guard42)
            testing.expect(t, ok && source == w.guard && c.value == 88)

            // Nothing anywhere on the chain.
            _, _, ok = ecs.get_component_up(&w.masses, &w.db, w.loner)
            testing.expect(t, !ok)

            // Above the owner, the answer is still found locally.
            c, source, ok = ecs.get_component_up(&w.masses, &w.db, w.human)
            testing.expect(t, ok && source == w.human)

            // physical is above every mass owner.
            _, _, ok = ecs.get_component_up(&w.masses, &w.db, w.physical)
            testing.expect(t, !ok)
    }

    @(test)
    inherit__has_tag_up__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            w: Inh_World
            defer ecs.terminate(&w.db)
            testing.expect(t, inh_world__init(&w, allocator) == nil)

            testing.expect(t, ecs.add_tag(&w.rope, w.creature) == nil)

            // The tag physically lives on creature, not on guard42.
            testing.expect(t, !ecs.has_tag(&w.rope, w.guard42))

            source, ok := ecs.has_tag_up(&w.rope, &w.db, w.guard42)
            testing.expect(t, ok && source == w.creature)

            source, ok = ecs.has_tag_up(&w.rope, &w.db, w.creature)
            testing.expect(t, ok && source == w.creature)

            // physical is above the tag owner.
            _, ok = ecs.has_tag_up(&w.rope, &w.db, w.physical)
            testing.expect(t, !ok)

            _, ok = ecs.has_tag_up(&w.rope, &w.db, w.loner)
            testing.expect(t, !ok)
    }

    @(test)
    inherit__find_up__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            w: Inh_World
            defer ecs.terminate(&w.db)
            testing.expect(t, inh_world__init(&w, allocator) == nil)

            target := w.human

            is_target :: proc(eid: ecs.entity_id, user_data: rawptr) -> bool {
                return eid == (cast(^ecs.entity_id) user_data)^
            }

            found, ok := ecs.find_up(&w.db, w.guard42, &target, is_target)
            testing.expect(t, ok && found == w.human)

            // Starts at the entity itself.
            self_target := w.guard42
            found, ok = ecs.find_up(&w.db, w.guard42, &self_target, is_target)
            testing.expect(t, ok && found == w.guard42)

            // Not on the chain.
            off_target := w.loner
            _, ok = ecs.find_up(&w.db, w.guard42, &off_target, is_target)
            testing.expect(t, !ok)
    }

    @(test)
    inherit__no_relations_table_checks_self_only__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 8, allocator = allocator) == nil)

            masses: ecs.Table(Inh_Mass)
            testing.expect(t, ecs.table_init(&masses, &db, 8) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)

            m, _ := ecs.add_component(&masses, a)
            m.value = 12

            // With no Relations_Table the chain is just the entity itself.
            c, source, ok := ecs.get_component_up(&masses, &db, a)
            testing.expect(t, ok && source == a && c.value == 12)

            _, _, ok = ecs.get_component_up(&masses, &db, b)
            testing.expect(t, !ok)
    }

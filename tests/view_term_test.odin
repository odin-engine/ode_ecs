/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for View_Term: passing a Pair_Table directly to view_init's
    includes / excludes / any_of, where it stands for "has at least one pair".
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"
    import "core:slice"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// View_Term

    Vt_Pos :: struct {
        x, y: f32,
    }

    Vt_Link :: struct {
        weight: int,
    }

    @(test)
    view_term__pair_in_includes__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            positions: ecs.Table(Vt_Pos)
            likes: ecs.Pair_Table(Vt_Link)
            view: ecs.View
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&likes)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap = 8, pairs_cap = 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions, &likes}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.add_component(&positions, b)

            testing.expect(t, ecs.view_len(&view) == 0)

            ecs.pair_add(&likes, a, c, Vt_Link{ weight = 1 })
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, slice.contains(ecs.entities_slice(&view), a))

            ecs.pair_add(&likes, a, b, Vt_Link{ weight = 2 })
            testing.expect(t, ecs.view_len(&view) == 1)

            testing.expect(t, ecs.pair_remove(&likes, a, b) == nil)
            testing.expect(t, ecs.view_len(&view) == 1)

            testing.expect(t, ecs.pair_remove(&likes, a, c) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)

            ecs.pair_add(&likes, a, c, Vt_Link{ weight = 3 })
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, ecs.destroy_entity(&db, c) == nil)
            testing.expect(t, ecs.view_len(&view) == 0)
    }

    @(test)
    view_term__pair_in_excludes__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            positions: ecs.Table(Vt_Pos)
            likes: ecs.Pair_Table(Vt_Link)
            view: ecs.View
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&likes)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap = 8, pairs_cap = 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions}, excludes = {&likes}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.add_component(&positions, b)

            testing.expect(t, ecs.view_len(&view) == 2)

            ecs.pair_add(&likes, a, c, Vt_Link{ weight = 1 })
            testing.expect(t, ecs.view_len(&view) == 1)
            testing.expect(t, !slice.contains(ecs.entities_slice(&view), a))

            testing.expect(t, ecs.pair_remove(&likes, a, c) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)
    }

    @(test)
    view_term__pair_in_any_of__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            positions: ecs.Table(Vt_Pos)
            stunned: ecs.Tag_Table
            likes: ecs.Pair_Table(Vt_Link)
            view: ecs.View
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&likes)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.tag_table_init(&stunned, &db, 16) == nil)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap = 8, pairs_cap = 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions}, any_of = {&likes, &stunned}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            d, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.add_component(&positions, b)
            ecs.add_component(&positions, c)

            testing.expect(t, ecs.view_len(&view) == 0)

            ecs.pair_add(&likes, a, d, Vt_Link{ weight = 1 })
            testing.expect(t, ecs.view_len(&view) == 1)

            testing.expect(t, ecs.add_tag(&stunned, b) == nil)
            testing.expect(t, ecs.view_len(&view) == 2)
            testing.expect(t, !slice.contains(ecs.entities_slice(&view), c))
    }

    @(test)
    view_term__pair_and_presence_collapse__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            positions: ecs.Table(Vt_Pos)
            likes: ecs.Pair_Table(Vt_Link)
            view: ecs.View
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&likes)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap = 8, pairs_cap = 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions, &likes, &likes.presence}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)
            ecs.pair_add(&likes, a, b, Vt_Link{ weight = 1 })

            testing.expect(t, ecs.view_len(&view) == 1)
    }

    @(test)
    view_term__pair_included_and_excluded__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            positions: ecs.Table(Vt_Pos)
            likes: ecs.Pair_Table(Vt_Link)
            v1, v2: ecs.View
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&likes)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.pair_init(&likes, &db, holders_cap = 8, pairs_cap = 16) == nil)

            testing.expect(t, ecs.view_init(&v1, &db, {&positions, &likes}, excludes = {&likes}) == ecs.API_Error.Table_Cannot_Be_Included_And_Excluded)
            testing.expect(t, ecs.view_init(&v2, &db, {&positions, &likes}, excludes = {&likes.presence}) == ecs.API_Error.Table_Cannot_Be_Included_And_Excluded)
    }

    @(test)
    view_term__tag_only_pair__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            positions: ecs.Table(Vt_Pos)
            friends: ecs.Pair_Table(struct{})
            view: ecs.View
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&friends)

            testing.expect(t, ecs.init(&db, entities_cap = 16, allocator = allocator) == nil)
            testing.expect(t, ecs.table_init(&positions, &db, 16) == nil)
            testing.expect(t, ecs.pair_init(&friends, &db, holders_cap = 8, pairs_cap = 16) == nil)
            testing.expect(t, ecs.view_init(&view, &db, {&positions, &friends}) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            ecs.add_component(&positions, a)

            testing.expect(t, ecs.view_len(&view) == 0)
            ecs.pair_add(&friends, a, b, struct{}{})
            testing.expect(t, ecs.view_len(&view) == 1)
    }

package ode_ecs__tests

import "core:testing"
import "core:log"
import "core:mem"

import ecs ".."

@(test)
table__slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    tbl: ecs.Table(Position)
    defer ecs.table_terminate(&tbl)
    testing.expect(t, ecs.table_init(&tbl, &db, 5) == nil)

    testing.expect(t, len(ecs.slice(&tbl)) == 0)

    e0, _ := ecs.create_entity(&db)
    e1, _ := ecs.create_entity(&db)
    e2, _ := ecs.create_entity(&db)

    p0, _ := ecs.add_component(&tbl, e0)
    p0.x = 10
    p1, _ := ecs.add_component(&tbl, e1)
    p1.x = 20
    p2, _ := ecs.add_component(&tbl, e2)
    p2.x = 30

    s := ecs.slice(&tbl)
    testing.expect(t, len(s) == 3)
    testing.expect(t, s[0].x == 10)
    testing.expect(t, s[1].x == 20)
    testing.expect(t, s[2].x == 30)

    testing.expect(t, ecs.remove_component(&tbl, e1) == nil)
    s = ecs.slice(&tbl)
    testing.expect(t, len(s) == 2)
    found_10, found_30 := false, false
    for row in s {
        if row.x == 10 do found_10 = true
        if row.x == 30 do found_30 = true
    }
    testing.expect(t, found_10 && found_30)
}

@(test)
compact_table__slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    ais: ecs.Compact_Table(AI)
    defer ecs.compact_table__terminate(&ais)
    testing.expect(t, ecs.compact_table__init(&ais, &db, 5) == nil)

    testing.expect(t, len(ecs.slice(&ais)) == 0)

    e0, _ := ecs.create_entity(&db)
    e1, _ := ecs.create_entity(&db)
    e2, _ := ecs.create_entity(&db)

    a0, _ := ecs.add_component(&ais, e0)
    a0.neurons_count = 1
    a1, _ := ecs.add_component(&ais, e1)
    a1.neurons_count = 2
    a2, _ := ecs.add_component(&ais, e2)
    a2.neurons_count = 3

    s := ecs.slice(&ais)
    testing.expect(t, len(s) == 3)
    testing.expect(t, s[0].neurons_count == 1)
    testing.expect(t, s[1].neurons_count == 2)
    testing.expect(t, s[2].neurons_count == 3)

    testing.expect(t, ecs.remove_component(&ais, e0) == nil)
    s = ecs.slice(&ais)
    testing.expect(t, len(s) == 2)
    found_2, found_3 := false, false
    for row in s {
        if row.neurons_count == 2 do found_2 = true
        if row.neurons_count == 3 do found_3 = true
    }
    testing.expect(t, found_2 && found_3)
}

@(test)
tiny_table__slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    positions: ecs.Tiny_Table(Position)
    defer ecs.tiny_table__terminate(&positions)
    testing.expect(t, ecs.tiny_table__init(&positions, &db) == nil)

    testing.expect(t, len(ecs.slice(&positions)) == 0)

    e0, _ := ecs.create_entity(&db)
    e1, _ := ecs.create_entity(&db)
    e2, _ := ecs.create_entity(&db)

    p0, _ := ecs.add_component(&positions, e0)
    p0.x = 100
    p1, _ := ecs.add_component(&positions, e1)
    p1.x = 200
    p2, _ := ecs.add_component(&positions, e2)
    p2.x = 300

    s := ecs.slice(&positions)
    testing.expect(t, len(s) == 3)
    testing.expect(t, s[0].x == 100)
    testing.expect(t, s[1].x == 200)
    testing.expect(t, s[2].x == 300)

    testing.expect(t, ecs.remove_component(&positions, e2) == nil)
    s = ecs.slice(&positions)
    testing.expect(t, len(s) == 2)
    found_100, found_200 := false, false
    for row in s {
        if row.x == 100 do found_100 = true
        if row.x == 200 do found_200 = true
    }
    testing.expect(t, found_100 && found_200)
}

@(test)
tag_table__slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    is_alive: ecs.Tag_Table
    defer ecs.tag_table__terminate(&is_alive)
    testing.expect(t, ecs.tag_table__init(&is_alive, &db, 5) == nil)

    testing.expect(t, len(ecs.slice(&is_alive)) == 0)

    e0, _ := ecs.create_entity(&db)
    e1, _ := ecs.create_entity(&db)
    e2, _ := ecs.create_entity(&db)

    ecs.tag(&is_alive, e0)
    ecs.tag(&is_alive, e1)
    ecs.tag(&is_alive, e2)

    s := ecs.slice(&is_alive)
    testing.expect(t, len(s) == 3)
    testing.expect(t, s[0] == e0)
    testing.expect(t, s[1] == e1)
    testing.expect(t, s[2] == e2)

    es := ecs.entities_slice(&is_alive)
    testing.expect(t, len(es) == len(s))
    testing.expect(t, es[0] == s[0])
    testing.expect(t, es[1] == s[1])
    testing.expect(t, es[2] == s[2])

    testing.expect(t, ecs.untag(&is_alive, e1) == nil)
    s = ecs.slice(&is_alive)
    testing.expect(t, len(s) == 2)
    found_e0, found_e2 := false, false
    for eid in s {
        if eid == e0 do found_e0 = true
        if eid == e2 do found_e2 = true
    }
    testing.expect(t, found_e0 && found_e2)

    es = ecs.entities_slice(&is_alive)
    testing.expect(t, len(es) == len(s))
    testing.expect(t, es[0] == s[0])
    testing.expect(t, es[1] == s[1])
}

@(test)
arch_table__slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    at: ecs.Arch_Table
    defer ecs.arch_table__terminate(&at)
    testing.expect(t, ecs.arch_table__init(&at, &db, 5, {Position, AI}) == nil)

    testing.expect(t, len(ecs.slice(&at)) == 0)
    testing.expect(t, len(ecs.slice(&at, Position)) == 0)

    e0, _ := ecs.create_entity(&at)
    ecs.get_component(&at, e0, Position).x = 11
    ecs.get_component(&at, e0, AI).neurons_count = 111

    e1, _ := ecs.create_entity(&at)
    ecs.get_component(&at, e1, Position).x = 22
    ecs.get_component(&at, e1, AI).neurons_count = 222

    eids := ecs.slice(&at)
    pos_col := ecs.slice(&at, Position)
    ai_col := ecs.slice(&at, AI)

    testing.expect(t, len(eids) == 2)
    testing.expect(t, len(pos_col) == 2)
    testing.expect(t, len(ai_col) == 2)

    testing.expect(t, eids[0] == e0)
    testing.expect(t, eids[1] == e1)
    testing.expect(t, pos_col[0].x == 11)
    testing.expect(t, pos_col[1].x == 22)
    testing.expect(t, ai_col[0].neurons_count == 111)
    testing.expect(t, ai_col[1].neurons_count == 222)
}

@(test)
table__entities_slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    tbl: ecs.Table(Position)
    defer ecs.table_terminate(&tbl)
    testing.expect(t, ecs.table_init(&tbl, &db, 5) == nil)

    testing.expect(t, len(ecs.entities_slice(&tbl)) == 0)

    e0, _ := ecs.create_entity(&db)
    e1, _ := ecs.create_entity(&db)
    e2, _ := ecs.create_entity(&db)

    _, _ = ecs.add_component(&tbl, e0)
    _, _ = ecs.add_component(&tbl, e1)
    _, _ = ecs.add_component(&tbl, e2)

    dense := ecs.slice(&tbl)
    entities := ecs.entities_slice(&tbl)
    testing.expect(t, len(entities) == len(dense))
    testing.expect(t, entities[0] == e0)
    testing.expect(t, entities[1] == e1)
    testing.expect(t, entities[2] == e2)

    testing.expect(t, ecs.remove_component(&tbl, e0) == nil)
    dense = ecs.slice(&tbl)
    entities = ecs.entities_slice(&tbl)
    testing.expect(t, len(entities) == len(dense))
    testing.expect(t, len(entities) == 2)
    for i in 0..<len(entities) {
        testing.expect(t, ecs.get_component(&tbl, entities[i]) == &dense[i])
    }
}

@(test)
compact_table__entities_slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    ais: ecs.Compact_Table(AI)
    defer ecs.compact_table__terminate(&ais)
    testing.expect(t, ecs.compact_table__init(&ais, &db, 5) == nil)

    testing.expect(t, len(ecs.entities_slice(&ais)) == 0)

    e0, _ := ecs.create_entity(&db)
    e1, _ := ecs.create_entity(&db)
    e2, _ := ecs.create_entity(&db)

    _, _ = ecs.add_component(&ais, e0)
    _, _ = ecs.add_component(&ais, e1)
    _, _ = ecs.add_component(&ais, e2)

    dense := ecs.slice(&ais)
    entities := ecs.entities_slice(&ais)
    testing.expect(t, len(entities) == len(dense))
    testing.expect(t, entities[0] == e0)
    testing.expect(t, entities[1] == e1)
    testing.expect(t, entities[2] == e2)

    testing.expect(t, ecs.remove_component(&ais, e1) == nil)
    dense = ecs.slice(&ais)
    entities = ecs.entities_slice(&ais)
    testing.expect(t, len(entities) == len(dense))
    testing.expect(t, len(entities) == 2)
    for i in 0..<len(entities) {
        testing.expect(t, ecs.get_component(&ais, entities[i]) == &dense[i])
    }
}

@(test)
tiny_table__entities_slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    positions: ecs.Tiny_Table(Position)
    defer ecs.tiny_table__terminate(&positions)
    testing.expect(t, ecs.tiny_table__init(&positions, &db) == nil)

    testing.expect(t, len(ecs.entities_slice(&positions)) == 0)

    e0, _ := ecs.create_entity(&db)
    e1, _ := ecs.create_entity(&db)
    e2, _ := ecs.create_entity(&db)

    _, _ = ecs.add_component(&positions, e0)
    _, _ = ecs.add_component(&positions, e1)
    _, _ = ecs.add_component(&positions, e2)

    dense := ecs.slice(&positions)
    entities := ecs.entities_slice(&positions)
    testing.expect(t, len(entities) == len(dense))
    testing.expect(t, entities[0] == e0)
    testing.expect(t, entities[1] == e1)
    testing.expect(t, entities[2] == e2)

    testing.expect(t, ecs.remove_component(&positions, e2) == nil)
    dense = ecs.slice(&positions)
    entities = ecs.entities_slice(&positions)
    testing.expect(t, len(entities) == len(dense))
    testing.expect(t, len(entities) == 2)
    for i in 0..<len(entities) {
        testing.expect(t, ecs.get_component(&positions, entities[i]) == &dense[i])
    }
}

@(test)
group__entities_slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    pos: ecs.Table(Group_Pos)
    vel: ecs.Table(Group_Vel)
    group: ecs.Group
    testing.expect(t, ecs.table_init(&pos, &db, 10) == nil)
    testing.expect(t, ecs.table_init(&vel, &db, 10) == nil)
    testing.expect(t, ecs.group_init(&group, &db, {&pos, &vel}) == nil)

    testing.expect(t, len(ecs.entities_slice(&group)) == 0)

    e0, _ := ecs.create_entity(&db)
    e1, _ := ecs.create_entity(&db)
    e2, _ := ecs.create_entity(&db)

    _, _ = ecs.add_component(&pos, e0); _, _ = ecs.add_component(&vel, e0)
    _, _ = ecs.add_component(&pos, e1); _, _ = ecs.add_component(&vel, e1)
    _, _ = ecs.add_component(&pos, e2); _, _ = ecs.add_component(&vel, e2)

    pos_dense := ecs.slice(&group, &pos)
    group_entities := ecs.entities_slice(&group)
    testing.expect(t, len(group_entities) == len(pos_dense))
    testing.expect(t, group_entities[0] == e0)
    testing.expect(t, group_entities[1] == e1)
    testing.expect(t, group_entities[2] == e2)
    for i in 0..<len(group_entities) {
        testing.expect(t, ecs.get_entity(&pos, i) == group_entities[i])
        testing.expect(t, ecs.get_entity(&vel, i) == group_entities[i])
    }

    testing.expect(t, ecs.remove_component(&vel, e0) == nil)
    pos_dense = ecs.slice(&group, &pos)
    group_entities = ecs.entities_slice(&group)
    testing.expect(t, len(group_entities) == len(pos_dense))
    testing.expect(t, len(group_entities) == 2)
    for i in 0..<len(group_entities) {
        testing.expect(t, ecs.get_entity(&pos, i) == group_entities[i])
        testing.expect(t, ecs.get_entity(&vel, i) == group_entities[i])
    }
}

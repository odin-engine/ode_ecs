/*
    2026 (c) Oleh, https://github.com/zm69

    Command_Buffer — deferred structural operations.

    Records destroy_entity / add_component / remove_component / add_tag /
    remove_tag / set_parent / remove_parent / pair_add / pair_remove WITHOUT touching the database,
    and applies them later, in recorded order, with command_buffer__replay. This makes any iteration
    mutation-safe (tables, views, dense slices, groups): nothing structural
    happens until the replay sync point, so nothing can move or grow under an
    iterator. It also gives frame coherence — every system in a phase sees the
    same world, and spawns/despawns become visible at the sync point, not
    mid-loop.

    create_entity is NOT deferred on purpose: it is already safe during
    iteration (pure id allocation, no table/view effects). Create the entity
    immediately and record component commands against the real entity_id.

    Everything is preallocated at init (commands_cap records + payload_cap
    bytes of component data) — recording and replaying never allocate.

    Threading: recording only writes to the buffer's own memory, so use one
    Command_Buffer per thread (or per system) and record concurrently without
    locks; replay mutates the database and must run single-threaded at the
    sync point, one buffer after another (cross-buffer ordering is the order
    you replay them in). init/terminate write into the Database's shared
    command_buffers registry, so — like every other attach/detach in this
    library — they are not safe to call concurrently from multiple threads on
    buffers attached to the same Database; do all init/terminate calls on the
    main/owning thread before/after the concurrent recording phase.

    database__terminate auto-terminates any Command_Buffer still attached, so
    an explicit command_buffer__terminate call is optional (but still safe —
    it just detaches and frees a bit earlier). Table structs referenced by
    recorded commands must outlive the replay (they normally do — table
    structs are user-owned and live for the whole game).
*/
package ode_ecs

// Core
    import "core:mem"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Command_Buffer

    @(private)
    Command_Kind :: enum u8 {
        Destroy_Entity,
        Add_Component,
        Remove_Component,
        Add_Tag,
        Remove_Tag,
        Set_Parent,
        Remove_Parent,
        Arch_Add_Entity,
        Add_Pair,
        Remove_Pair,
    }

    @(private)
    Command :: struct {
        kind: Command_Kind,
        destroy_children: bool,
        eid: entity_id,
        parent: entity_id,
        target: entity_id,
        table: ^Shared_Table,
        table_id: table_id,
        pair_table: ^Pair_Table_Base,
        pair_table_id: pair_table_id,
        payload_offset: int,
        payload_size: int,
    }

    Command_Buffer :: struct {
        state: Object_State,
        db: ^Database,
        id: command_buffer_id,

        commands: []Command,
        count: int,

        payload: []byte,
        payload_used: int,

        replaying: bool,
    }

    command_buffer__is_valid :: proc(self: ^Command_Buffer) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if self.commands == nil do return false
        if self.payload == nil do return false

        return true
    }

    command_buffer__init :: proc(self: ^Command_Buffer, db: ^Database, commands_cap: int, payload_cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(commands_cap > 0, loc = loc)
            assert(payload_cap > 0, loc = loc)
        }

        self.count = 0
        self.payload_used = 0
        self.replaying = false

        self.db = db

        self.commands = make([]Command, commands_cap, db.allocator) or_return
        self.payload = make([]byte, payload_cap, db.allocator) or_return

        self.id = database__attach_command_buffer(db, self) or_return

        self.state = Object_State.Normal

        return nil
    }

    command_buffer__terminate :: proc(self: ^Command_Buffer) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.commands != nil {
            delete(self.commands, self.db.allocator) or_return
            self.commands = nil
        }
        if self.payload != nil {
            delete(self.payload, self.db.allocator) or_return
            self.payload = nil
        }

        self.count = 0
        self.payload_used = 0
        self.replaying = false

        database__detach_command_buffer(self.db, self)
        self.db = nil

        self.state = Object_State.Not_Initialized

        return nil
    }

    command_buffer__clear :: proc(self: ^Command_Buffer) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.count = 0
        self.payload_used = 0

        return nil
    }

    command_buffer__len :: #force_inline proc "contextless" (self: ^Command_Buffer) -> int {
        return self.count
    }

    command_buffer__cap :: #force_inline proc "contextless" (self: ^Command_Buffer) -> int {
        return len(self.commands)
    }

    command_buffer__memory_usage :: proc(self: ^Command_Buffer) -> int {
        total := size_of(self^)

        if self.commands != nil do total += size_of(self.commands[0]) * len(self.commands)
        if self.payload != nil do total += len(self.payload)

        return total
    }

///////////////////////////////////////////////////////////////////////////////
// Recording

    command_buffer__destroy_entity :: proc(self: ^Command_Buffer, eid: entity_id, destroy_children := false, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(eid.ix >= 0, loc = loc)
        }

        return command_buffer__append(self, Command{
            kind = Command_Kind.Destroy_Entity,
            destroy_children = destroy_children,
            eid = eid,
        })
    }

    command_buffer__add_component_for_table :: proc(self: ^Command_Buffer, table: ^Table($T), eid: entity_id, value: T, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(table__is_valid(table), loc = loc)
            assert(table.type_info.id == typeid_of(T), loc = loc)
        }
        value := value
        return command_buffer__record_add(self, cast(^Shared_Table) table, eid, &value, size_of(T), align_of(T), loc)
    }

    command_buffer__add_component_for_compact_table :: proc(self: ^Command_Buffer, table: ^Compact_Table($T), eid: entity_id, value: T, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(compact_table__is_valid(table), loc = loc)
            assert(table.type_info.id == typeid_of(T), loc = loc)
        }
        value := value
        return command_buffer__record_add(self, cast(^Shared_Table) table, eid, &value, size_of(T), align_of(T), loc)
    }

    command_buffer__add_component_for_tiny_table :: proc(self: ^Command_Buffer, table: ^Tiny_Table($T), eid: entity_id, value: T, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(tiny_table__is_valid(table), loc = loc)
            assert(table.type_info.id == typeid_of(T), loc = loc)
        }
        value := value
        return command_buffer__record_add(self, cast(^Shared_Table) table, eid, &value, size_of(T), align_of(T), loc)
    }

    command_buffer__remove_component_for_table :: proc(self: ^Command_Buffer, table: ^Table($T), eid: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(table__is_valid(table), loc = loc)
        }
        return command_buffer__record_simple(self, Command_Kind.Remove_Component, cast(^Shared_Table) table, eid, loc)
    }

    command_buffer__remove_component_for_compact_table :: proc(self: ^Command_Buffer, table: ^Compact_Table($T), eid: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(compact_table__is_valid(table), loc = loc)
        }
        return command_buffer__record_simple(self, Command_Kind.Remove_Component, cast(^Shared_Table) table, eid, loc)
    }

    command_buffer__remove_component_for_tiny_table :: proc(self: ^Command_Buffer, table: ^Tiny_Table($T), eid: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(tiny_table__is_valid(table), loc = loc)
        }
        return command_buffer__record_simple(self, Command_Kind.Remove_Component, cast(^Shared_Table) table, eid, loc)
    }

    command_buffer__arch_add_entity1 :: proc(self: ^Command_Buffer, arch: ^Arch_Table, eid: entity_id, v1: $T1, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(arch_table__is_valid(arch), loc = loc)
            assert(len(arch.columns) == 1, "Arch_Table does not have exactly 1 column", loc = loc)
            assert(arch.columns[0].type_info.id == typeid_of(T1), "component type/order does not match arch_table__init", loc = loc)
        }

        offset, cmd := command_buffer__record_arch_add_header(self, arch, eid, loc) or_return
        v1 := v1
        command_buffer__write_arch_payload_column(self, arch, offset, 0, &v1, size_of(T1))
        return command_buffer__append(self, cmd)
    }

    command_buffer__arch_add_entity2 :: proc(self: ^Command_Buffer, arch: ^Arch_Table, eid: entity_id, v1: $T1, v2: $T2, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(arch_table__is_valid(arch), loc = loc)
            assert(len(arch.columns) == 2, "Arch_Table does not have exactly 2 columns", loc = loc)
            assert(arch.columns[0].type_info.id == typeid_of(T1), "component type/order does not match arch_table__init", loc = loc)
            assert(arch.columns[1].type_info.id == typeid_of(T2), "component type/order does not match arch_table__init", loc = loc)
        }

        offset, cmd := command_buffer__record_arch_add_header(self, arch, eid, loc) or_return
        v1, v2 := v1, v2
        command_buffer__write_arch_payload_column(self, arch, offset, 0, &v1, size_of(T1))
        command_buffer__write_arch_payload_column(self, arch, offset, 1, &v2, size_of(T2))
        return command_buffer__append(self, cmd)
    }

    command_buffer__arch_add_entity3 :: proc(self: ^Command_Buffer, arch: ^Arch_Table, eid: entity_id, v1: $T1, v2: $T2, v3: $T3, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(arch_table__is_valid(arch), loc = loc)
            assert(len(arch.columns) == 3, "Arch_Table does not have exactly 3 columns", loc = loc)
            assert(arch.columns[0].type_info.id == typeid_of(T1), "component type/order does not match arch_table__init", loc = loc)
            assert(arch.columns[1].type_info.id == typeid_of(T2), "component type/order does not match arch_table__init", loc = loc)
            assert(arch.columns[2].type_info.id == typeid_of(T3), "component type/order does not match arch_table__init", loc = loc)
        }

        offset, cmd := command_buffer__record_arch_add_header(self, arch, eid, loc) or_return
        v1, v2, v3 := v1, v2, v3
        command_buffer__write_arch_payload_column(self, arch, offset, 0, &v1, size_of(T1))
        command_buffer__write_arch_payload_column(self, arch, offset, 1, &v2, size_of(T2))
        command_buffer__write_arch_payload_column(self, arch, offset, 2, &v3, size_of(T3))
        return command_buffer__append(self, cmd)
    }

    command_buffer__arch_add_entity4 :: proc(self: ^Command_Buffer, arch: ^Arch_Table, eid: entity_id, v1: $T1, v2: $T2, v3: $T3, v4: $T4, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(arch_table__is_valid(arch), loc = loc)
            assert(len(arch.columns) == 4, "Arch_Table does not have exactly 4 columns", loc = loc)
            assert(arch.columns[0].type_info.id == typeid_of(T1), "component type/order does not match arch_table__init", loc = loc)
            assert(arch.columns[1].type_info.id == typeid_of(T2), "component type/order does not match arch_table__init", loc = loc)
            assert(arch.columns[2].type_info.id == typeid_of(T3), "component type/order does not match arch_table__init", loc = loc)
            assert(arch.columns[3].type_info.id == typeid_of(T4), "component type/order does not match arch_table__init", loc = loc)
        }

        offset, cmd := command_buffer__record_arch_add_header(self, arch, eid, loc) or_return
        v1, v2, v3, v4 := v1, v2, v3, v4
        command_buffer__write_arch_payload_column(self, arch, offset, 0, &v1, size_of(T1))
        command_buffer__write_arch_payload_column(self, arch, offset, 1, &v2, size_of(T2))
        command_buffer__write_arch_payload_column(self, arch, offset, 2, &v3, size_of(T3))
        command_buffer__write_arch_payload_column(self, arch, offset, 3, &v4, size_of(T4))
        return command_buffer__append(self, cmd)
    }

    command_buffer__remove_entity_for_arch_table :: proc(self: ^Command_Buffer, table: ^Arch_Table, eid: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(arch_table__is_valid(table), loc = loc)
        }
        return command_buffer__record_simple(self, Command_Kind.Remove_Component, cast(^Shared_Table) table, eid, loc)
    }

    command_buffer__add_tag :: proc(self: ^Command_Buffer, table: ^Tag_Table, eid: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(tag_table__is_valid(table), loc = loc)
        }
        return command_buffer__record_simple(self, Command_Kind.Add_Tag, cast(^Shared_Table) table, eid, loc)
    }

    command_buffer__remove_tag :: proc(self: ^Command_Buffer, table: ^Tag_Table, eid: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(tag_table__is_valid(table), loc = loc)
        }
        return command_buffer__record_simple(self, Command_Kind.Remove_Tag, cast(^Shared_Table) table, eid, loc)
    }

    command_buffer__set_parent :: proc(self: ^Command_Buffer, child: entity_id, parent: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(child.ix >= 0, loc = loc)
            assert(parent.ix >= 0, loc = loc)
        }

        return command_buffer__append(self, Command{
            kind = Command_Kind.Set_Parent,
            eid = child,
            parent = parent,
        })
    }

    command_buffer__remove_parent :: proc(self: ^Command_Buffer, child: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(child.ix >= 0, loc = loc)
        }

        return command_buffer__append(self, Command{
            kind = Command_Kind.Remove_Parent,
            eid = child,
        })
    }

    command_buffer__pair_add :: proc(self: ^Command_Buffer, pt: ^Pair_Table($T), holder: entity_id, target: entity_id, data: T, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(pair_table__is_valid(pt), loc = loc)
            assert(pt.data_type_info.id == typeid_of(T), loc = loc)
        }
        value := data
        return command_buffer__record_pair_add(self, &pt.base, holder, target, &value, size_of(T), align_of(T), loc)
    }

    command_buffer__pair_remove :: proc(self: ^Command_Buffer, pt: ^Pair_Table($T), holder: entity_id, target: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(pair_table__is_valid(pt), loc = loc)
            assert(pt.db == self.db, loc = loc)
            assert(holder.ix >= 0, loc = loc)
        }

        return command_buffer__append(self, Command{
            kind = Command_Kind.Remove_Pair,
            eid = holder,
            target = target,
            pair_table = &pt.base,
            pair_table_id = pt.id,
        })
    }

///////////////////////////////////////////////////////////////////////////////
// Replay
    command_buffer__replay :: proc(self: ^Command_Buffer, loc := #caller_location) -> (skipped: int, err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(!self.replaying, loc = loc)
        }

        if self.state != Object_State.Normal do return 0, API_Error.Object_Invalid
        if !database__is_valid(self.db) do return 0, API_Error.Object_Invalid

        self.replaying = true
        defer self.replaying = false

        defer {
            self.count = 0
            self.payload_used = 0
        }

        for i := 0; i < self.count; i += 1 {
            cmd := &self.commands[i]

            if database__is_entity_correct(self.db, cmd.eid) != nil {
                skipped += 1
                continue
            }

            switch cmd.kind {
                case Command_Kind.Destroy_Entity:
                    derr := database__destroy_entity(self.db, cmd.eid, cmd.destroy_children)
                    if derr != nil && err == nil do err = derr

                case Command_Kind.Add_Component:
                    if !command__table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    data := rawptr(uintptr(raw_data(self.payload)) + uintptr(cmd.payload_offset))
                    _, aerr := shared_table__add_component(cmd.table, cmd.eid, data)
                    if aerr == API_Error.Component_Already_Exist do aerr = nil
                    if aerr != nil && err == nil do err = aerr

                case Command_Kind.Arch_Add_Entity:
                    if !command__table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    data := rawptr(uintptr(raw_data(self.payload)) + uintptr(cmd.payload_offset))
                    _, aerr := shared_table__add_component(cmd.table, cmd.eid, data)
                    if aerr == API_Error.Component_Already_Exist do aerr = nil
                    if aerr != nil && err == nil do err = aerr

                case Command_Kind.Remove_Component, Command_Kind.Remove_Tag:
                    if !command__table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    rerr := shared_table__remove_component(cmd.table, cmd.eid)
                    if rerr == oc.Core_Error.Not_Found {
                        skipped += 1
                        continue
                    }
                    if rerr != nil && err == nil do err = rerr

                case Command_Kind.Add_Tag:
                    if !command__table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    terr := tag_table__add_tag(cast(^Tag_Table) cmd.table, cmd.eid)
                    if terr != nil && err == nil do err = terr

                case Command_Kind.Set_Parent:
                    if database__is_entity_correct(self.db, cmd.parent) != nil {
                        skipped += 1
                        continue
                    }
                    serr := database__set_parent(self.db, cmd.eid, cmd.parent)
                    if serr != nil && err == nil do err = serr

                case Command_Kind.Remove_Parent:
                    perr := database__remove_parent(self.db, cmd.eid)
                    if perr == oc.Core_Error.Not_Found {
                        skipped += 1
                        continue
                    }
                    if perr != nil && err == nil do err = perr

                case Command_Kind.Add_Pair:
                    if database__is_entity_correct(self.db, cmd.target) != nil {
                        skipped += 1
                        continue
                    }
                    if !command__pair_table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    data := rawptr(uintptr(raw_data(self.payload)) + uintptr(cmd.payload_offset))
                    _, paerr := pair_table_base__add_raw(cmd.pair_table, cmd.eid, cmd.target, data)
                    if paerr != nil && err == nil do err = paerr

                case Command_Kind.Remove_Pair:
                    if database__is_entity_correct(self.db, cmd.target) != nil {
                        skipped += 1
                        continue
                    }
                    if !command__pair_table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    prerr := pair_table_base__remove(cmd.pair_table, cmd.eid, cmd.target)
                    if prerr == oc.Core_Error.Not_Found {
                        skipped += 1
                        continue
                    }
                    if prerr != nil && err == nil do err = prerr
            }
        }

        return
    }

///////////////////////////////////////////////////////////////////////////////
// Private
    @(private)
    command_buffer__append :: proc(self: ^Command_Buffer, cmd: Command) -> Error {
        if self.count >= len(self.commands) do return oc.Core_Error.Container_Is_Full

        self.commands[self.count] = cmd
        self.count += 1

        return nil
    }

    @(private)
    command_buffer__record_simple :: proc(self: ^Command_Buffer, kind: Command_Kind, table: ^Shared_Table, eid: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(table.db == self.db, loc = loc)
            assert(eid.ix >= 0, loc = loc)
        }

        return command_buffer__append(self, Command{
            kind = kind,
            eid = eid,
            table = table,
            table_id = table.id,
        })
    }

    @(private)
    command_buffer__record_add :: proc(self: ^Command_Buffer, table: ^Shared_Table, eid: entity_id, data: rawptr, size: int, align: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(table.db == self.db, loc = loc)
            assert(eid.ix >= 0, loc = loc)
        }

        if self.count >= len(self.commands) do return oc.Core_Error.Container_Is_Full

        base := uintptr(raw_data(self.payload))
        aligned := mem.align_forward_uintptr(base + uintptr(self.payload_used), uintptr(align))
        offset := int(aligned - base)
        if offset + size > len(self.payload) do return oc.Core_Error.Container_Is_Full

        mem.copy(rawptr(aligned), data, size)
        self.payload_used = offset + size

        self.commands[self.count] = Command{
            kind = Command_Kind.Add_Component,
            eid = eid,
            table = table,
            table_id = table.id,
            payload_offset = offset,
            payload_size = size,
        }
        self.count += 1

        return nil
    }

    @(private)
    command_buffer__record_pair_add :: proc(self: ^Command_Buffer, pt: ^Pair_Table_Base, holder: entity_id, target: entity_id, data: rawptr, size: int, align: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(pt.db == self.db, loc = loc)
            assert(holder.ix >= 0, loc = loc)
        }

        if self.count >= len(self.commands) do return oc.Core_Error.Container_Is_Full

        base := uintptr(raw_data(self.payload))
        aligned := mem.align_forward_uintptr(base + uintptr(self.payload_used), uintptr(align))
        offset := int(aligned - base)
        if offset + size > len(self.payload) do return oc.Core_Error.Container_Is_Full

        mem.copy(rawptr(aligned), data, size)
        self.payload_used = offset + size

        self.commands[self.count] = Command{
            kind = Command_Kind.Add_Pair,
            eid = holder,
            target = target,
            pair_table = pt,
            pair_table_id = pt.id,
            payload_offset = offset,
            payload_size = size,
        }
        self.count += 1

        return nil
    }

    @(private)
    command_buffer__record_arch_add_header :: proc(self: ^Command_Buffer, arch: ^Arch_Table, eid: entity_id, loc := #caller_location) -> (offset: int, cmd: Command, err: Error) {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(arch.db == self.db, loc = loc)
            assert(eid.ix >= 0, loc = loc)
        }

        if self.count >= len(self.commands) do return 0, Command{}, oc.Core_Error.Container_Is_Full

        max_align := 1
        for col in arch.columns {
            if col.type_info.align > max_align do max_align = col.type_info.align
        }

        base := uintptr(raw_data(self.payload))
        aligned := mem.align_forward_uintptr(base + uintptr(self.payload_used), uintptr(max_align))
        off := int(aligned - base)
        if off + arch.payload_size > len(self.payload) do return 0, Command{}, oc.Core_Error.Container_Is_Full

        self.payload_used = off + arch.payload_size

        cmd = Command{
            kind = Command_Kind.Arch_Add_Entity,
            eid = eid,
            table = cast(^Shared_Table) arch,
            table_id = arch.id,
            payload_offset = off,
            payload_size = arch.payload_size,
        }

        return off, cmd, nil
    }

    @(private)
    command_buffer__write_arch_payload_column :: #force_inline proc(self: ^Command_Buffer, arch: ^Arch_Table, offset: int, col_index: int, value: rawptr, size: int) {
        base := uintptr(raw_data(self.payload)) + uintptr(offset)
        dst := rawptr(base + uintptr(arch.col_payload_offsets[col_index]))
        mem.copy(dst, value, size)
    }

    @(private)
    command__table_matches :: proc(cmd: ^Command) -> bool {
        t := cmd.table
        if t == nil do return false
        if t.state != Object_State.Normal do return false
        if t.type == Table_Type.Auto do return false
        if t.id != cmd.table_id do return false

        if cmd.kind == Command_Kind.Add_Component {
            ti := shared_table__type_info(t)
            if ti == nil || ti.size != cmd.payload_size do return false
        }

        if cmd.kind == Command_Kind.Arch_Add_Entity {
            if t.type != Table_Type.Arch_Table do return false
            if (cast(^Arch_Table) t).payload_size != cmd.payload_size do return false
        }

        return true
    }

    @(private)
    command__pair_table_matches :: proc(cmd: ^Command) -> bool {
        pt := cmd.pair_table
        if pt == nil do return false
        if pt.state != Object_State.Normal do return false
        if pt.id != cmd.pair_table_id do return false

        if cmd.kind == Command_Kind.Add_Pair && pt.data_type_info.size != cmd.payload_size do return false

        return true
    }

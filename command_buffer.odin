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
        Add_Component,      // Table / Compact_Table / Tiny_Table; value in payload
        Remove_Component,   // Table / Compact_Table / Tiny_Table / Arch_Table (whole row)
        Add_Tag,
        Remove_Tag,
        Set_Parent,         // requires a Relations_Table on the database
        Remove_Parent,
        Arch_Add_Entity,    // Arch_Table; packed multi-column row value in payload
        Add_Pair,           // Pair_Table(T); value in payload
        Remove_Pair,
    }

    @(private)
    Command :: struct {
        kind: Command_Kind,
        destroy_children: bool,     // Destroy_Entity only
        eid: entity_id,             // the child for Set_Parent/Remove_Parent, the holder for Add_Pair/Remove_Pair
        parent: entity_id,          // Set_Parent only
        target: entity_id,          // Add_Pair / Remove_Pair only — a dedicated field rather than
                                     // reusing `parent`, which already has its own meaning for Set_Parent
        table: ^Shared_Table,       // nil for Destroy_Entity / Set_Parent / Remove_Parent / Add_Pair / Remove_Pair
        table_id: table_id,         // id at record time — stale-table guard at replay
        pair_table: ^Pair_Table_Base, // Add_Pair / Remove_Pair only — nil otherwise
        pair_table_id: pair_table_id, // id at record time — stale-registry guard at replay, mirrors table_id
        payload_offset: int,        // Add_Component / Add_Pair only
        payload_size: int,          // Add_Component / Add_Pair only, == size_of(T) at record time
    }

    Command_Buffer :: struct {
        state: Object_State,
        db: ^Database,
        id: command_buffer_id,      // Database.command_buffers registry index

        commands: []Command,
        count: int,

        payload: []byte,            // component values for Add_Component commands
        payload_used: int,

        // Recording into a buffer that is being replayed is forbidden: view filters
        // run during replay, and one recording into the same buffer would mutate it mid-loop.
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

        // A re-init'd struct (issue #8) may carry counters from its previous life.
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

        // Leave the buffer in Not_Initialized state (not Terminated) so the same
        // struct can be re-init'd without zeroing it first. 
        self.state = Object_State.Not_Initialized

        return nil
    }

    // Drop all recorded commands without applying them.
    command_buffer__clear :: proc(self: ^Command_Buffer) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.count = 0
        self.payload_used = 0

        return nil
    }

    // Number of recorded (not yet replayed) commands
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
// Recording — never touches the database, only appends to the buffer. A full
// buffer returns Container_Is_Full and records nothing. Entity ids are not
// validated here — replay skips whatever expired by the time it applies.

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

    // Record: add an entity's row to an Arch_Table (values copied into the buffer
    // now, written at replay; overwrites an existing row — "last write wins". 
    // Values must match column declaration order.
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

    // Record: remove an entity's whole row from an Arch_Table. Reuses
    // Command_Kind.Remove_Component — its Arch_Table case already does whole-row removal.
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

    // Record: make `parent` the parent of `child` (applied via database__set_parent
    // at replay) — a missing Relations_Table surfaces then as Relations_Table_Not_Created.
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

    // Record: remove `child`'s parent link (applied by replay through
    // database__remove_parent; a child that has no parent by then is a skip).
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

    // Record: add (holder -> target) with payload `data` to a Pair_Table.
    // Unlike cmd_add_component's last-write-wins overwrite semantics.
    command_buffer__pair_add :: proc(self: ^Command_Buffer, pt: ^Pair_Table($T), holder: entity_id, target: entity_id, data: T, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(pair_table__is_valid(pt), loc = loc)
            assert(pt.data_type_info.id == typeid_of(T), loc = loc)
        }
        value := data
        return command_buffer__record_pair_add(self, &pt.base, holder, target, &value, size_of(T), align_of(T), loc)
    }

    // Record: remove one (holder, target) pair (applied via pair_table_base__remove
    // at replay — a pair no longer present by then is a skip, same as cmd_remove_component).
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
    // Applies all recorded commands in order, then clears the buffer (even on
    // failure — a half-replayed buffer must not replay again).
    //
    // `skipped` counts commands dropped harmlessly: expired entity id (destroy/remove
    // become idempotent, dead-entity adds no-ops), component/tag already absent,
    // recorded table terminated/re-init'd since record time, or a Set_Parent/Remove_Parent
    // whose parent/child link no longer applies. Adding an already-existing component is
    // NOT a skip — the recorded value overwrites it (last write wins).
    //
    // Real errors (e.g. a full table) don't abort replay: remaining commands still run
    // and the first error is returned. Replaying while packing is paused is allowed; 
    // holes don't free capacity until packed.
    command_buffer__replay :: proc(self: ^Command_Buffer, loc := #caller_location) -> (skipped: int, err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(!self.replaying, loc = loc)
        }

        if self.state != Object_State.Normal do return 0, API_Error.Object_Invalid
        if !database__is_valid(self.db) do return 0, API_Error.Object_Invalid

        self.replaying = true
        defer self.replaying = false

        // Clear even on error — a half-applied buffer must not replay again.
        defer {
            self.count = 0
            self.payload_used = 0
        }

        for i := 0; i < self.count; i += 1 {
            cmd := &self.commands[i]

            // Entity gone by the time this command applies — skip.
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
                    if aerr == API_Error.Component_Already_Exist do aerr = nil // overwrite: last write wins
                    if aerr != nil && err == nil do err = aerr

                case Command_Kind.Arch_Add_Entity:
                    if !command__table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    data := rawptr(uintptr(raw_data(self.payload)) + uintptr(cmd.payload_offset))
                    _, aerr := shared_table__add_component(cmd.table, cmd.eid, data)
                    if aerr == API_Error.Component_Already_Exist do aerr = nil // overwrite: last write wins
                    if aerr != nil && err == nil do err = aerr

                case Command_Kind.Remove_Component, Command_Kind.Remove_Tag:
                    if !command__table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    rerr := shared_table__remove_component(cmd.table, cmd.eid)
                    if rerr == oc.Core_Error.Not_Found { // already absent — idempotent
                        skipped += 1
                        continue
                    }
                    if rerr != nil && err == nil do err = rerr

                case Command_Kind.Add_Tag:
                    if !command__table_matches(cmd) {
                        skipped += 1
                        continue
                    }
                    terr := tag_table__add_tag(cast(^Tag_Table) cmd.table, cmd.eid) // idempotent
                    if terr != nil && err == nil do err = terr

                case Command_Kind.Set_Parent:
                    // Parent gone by the time this applies — the link is moot,
                    // the child (alive, checked above) just stays as it is.
                    if database__is_entity_correct(self.db, cmd.parent) != nil {
                        skipped += 1
                        continue
                    }
                    serr := database__set_parent(self.db, cmd.eid, cmd.parent)
                    if serr != nil && err == nil do err = serr

                case Command_Kind.Remove_Parent:
                    perr := database__remove_parent(self.db, cmd.eid)
                    if perr == oc.Core_Error.Not_Found { // no parent — idempotent
                        skipped += 1
                        continue
                    }
                    if perr != nil && err == nil do err = perr

                case Command_Kind.Add_Pair:
                    // Target gone by the time this applies — same treatment as
                    // Set_Parent's parent check (cmd.eid, the holder, is already
                    // checked above).
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
                    if prerr == oc.Core_Error.Not_Found { // already absent — idempotent
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

        // Command capacity first — a payload bump for a command that never lands would leak arena space.
        if self.count >= len(self.commands) do return oc.Core_Error.Container_Is_Full

        // Reserve an aligned payload slot. Absolute-address alignment, so the
        // slot is reinterpretable as ^T regardless of the arena base address.
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

        // Command capacity first — a payload bump for a command that never lands would leak arena space.
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
    // Reserves a payload_size-byte slot (aligned to the widest column) and returns
    // the ready-to-append Command header; callers write each column via
    // command_buffer__write_arch_payload_column, then command_buffer__append it.
    command_buffer__record_arch_add_header :: proc(self: ^Command_Buffer, arch: ^Arch_Table, eid: entity_id, loc := #caller_location) -> (offset: int, cmd: Command, err: Error) {
        when VALIDATIONS {
            assert(command_buffer__is_valid(self), loc = loc)
            assert(!self.replaying, loc = loc)
            assert(arch.db == self.db, loc = loc)
            assert(eid.ix >= 0, loc = loc)
        }

        // Command capacity first — a payload bump for a command that never lands would leak arena space.
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
    // Is the recorded table still the one it was at record time? Terminate/re-init
    // changes id or state; an Add whose component size changed is also rejected.
    // Undetectable: the table struct itself freed between record and replay (documented lifetime requirement).
    command__table_matches :: proc(cmd: ^Command) -> bool {
        t := cmd.table
        if t == nil do return false
        if t.state != Object_State.Normal do return false
        if t.type == Table_Type.Unknown do return false
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
    // Is the recorded Pair_Table still the one it was at record time? Mirrors
    // command__table_matches exactly (state + id), using pair_table_id — a
    // Pair_Table isn't a Shared_Table, so it has no separate generation
    // counter; the registry id already changes on re-init the same way table_id does.
    command__pair_table_matches :: proc(cmd: ^Command) -> bool {
        pt := cmd.pair_table
        if pt == nil do return false
        if pt.state != Object_State.Normal do return false
        if pt.id != cmd.pair_table_id do return false

        if cmd.kind == Command_Kind.Add_Pair && pt.data_type_info.size != cmd.payload_size do return false

        return true
    }

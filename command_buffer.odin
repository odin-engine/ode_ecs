/*
    2026 (c) Oleh, https://github.com/zm69

    Command_Buffer — deferred structural operations.

    Records destroy_entity / add_component / remove_component / add_tag /
    remove_tag WITHOUT touching the database, and applies them later, in
    recorded order, with command_buffer__replay. This makes any iteration
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
    you replay them in).

    The Database does not track command buffers: database__terminate does not
    free them — terminate each buffer yourself. Table structs referenced by
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
        Remove_Component,   // Table / Compact_Table / Tiny_Table
        Add_Tag,
        Remove_Tag,
    }

    @(private)
    Command :: struct {
        kind: Command_Kind,
        destroy_children: bool,     // Destroy_Entity only
        eid: entity_id,
        table: ^Shared_Table,       // nil for Destroy_Entity
        table_id: table_id,         // id at record time — stale-table guard at replay
        payload_offset: int,        // Add_Component only
        payload_size: int,          // Add_Component only, == size_of(T) at record time
    }

    Command_Buffer :: struct {
        state: Object_State,
        db: ^Database,

        commands: []Command,
        count: int,

        payload: []byte,            // component values for Add_Component commands
        payload_used: int,

        // Recording into a buffer that is being replayed is forbidden: view
        // filters run during replay, and a filter recording into the same
        // buffer would mutate it mid-loop.
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
            assert(self.state == Object_State.Not_Initialized, loc = loc) // should be NOT_INITIALIZED
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

        self.state = Object_State.Normal

        return nil
    }

    command_buffer__terminate :: proc(self: ^Command_Buffer) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

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
        self.db = nil

        // Leave the buffer in Not_Initialized state (not Terminated) so the same
        // struct can be re-init'd without zeroing it first. See issue #8.
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
// Recording — never touches the database, only appends to the buffer.
// A full buffer (commands or payload) returns Container_Is_Full and records
// nothing. Entity ids are NOT validated here: an id that is valid now may
// legitimately be destroyed by an earlier command in this same buffer —
// replay skips whatever expired by the time it applies.

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

///////////////////////////////////////////////////////////////////////////////
// Replay

    // Applies all recorded commands in order, then clears the buffer (even
    // when a command failed — a half-replayed buffer must not replay again).
    //
    // `skipped` counts commands that were dropped harmlessly:
    //   - the entity id expired before the command applied (destroyed by an
    //     earlier command, another buffer, or user code) — this makes
    //     destroy/remove idempotent and dead-entity adds no-ops;
    //   - the component/tag to remove was already absent;
    //   - the recorded table was terminated (or re-init'd as a different
    //     table) between record and replay.
    // Adding a component that already exists is NOT a skip: the recorded
    // value overwrites the existing one (last write wins).
    //
    // Real errors (e.g. a full table) do not abort the replay: the remaining
    // commands still run and the first error is returned (same policy as
    // database__clear). Replaying while packing is paused is allowed — adds
    // append past the holes and removes take the hole path; note that holes
    // do not free capacity until packed.
    command_buffer__replay :: proc(self: ^Command_Buffer, loc := #caller_location) -> (skipped: int, err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(!self.replaying, loc = loc)
        }

        if self.state != Object_State.Normal do return 0, API_Error.Object_Invalid
        if !database__is_valid(self.db) do return 0, API_Error.Object_Invalid

        self.replaying = true
        defer self.replaying = false

        // Clear even when a command errored: replaying a half-applied buffer
        // again would double-apply the commands that succeeded.
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

        // Command capacity first: a payload bump for a command that never
        // lands would leak arena space.
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
    // Is the recorded table still the table it was at record time?
    // shared_table__clear_state (terminate) resets state/type/id, and a
    // terminate + re-init as a different table changes id; an Add whose
    // component size changed is also rejected. Undetectable: the table struct
    // itself being freed between record and replay (documented lifetime
    // requirement).
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

        return true
    }

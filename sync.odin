/*
    2026 (c) Oleh, https://github.com/zm69

    WARNING: This feature is in experimental stage and is not yet considered stable. 
             The API may change in future releases.

    Off by default — build with -define:ECS_SYNC_ENABLED=true to compile it in
    (see SYNC_ENABLED's doc comment in ecs.odin). This file's own @(test) procs
    below require the flag to mean anything; run them with
    `odin test . -define:ECS_SYNC_ENABLED=true` (mirrors -define:maps_testing=true
    for the maps package).

    Sync — delta-change replication, built for sending over an unreliable
    transport (UDP) with minimal traffic: collect_delta emits only the bytes
    of the FIELDS that actually changed within a component, for only the
    entities that were touched, since the last collect. Reliability (acks,
    retries, sequencing) is deliberately NOT this file's job — a Sync_Channel
    only answers "what changed since I last asked", and a Sync_Decoder only
    answers "apply these bytes"; the caller owns the socket and the delivery
    guarantees. For a full one-shot dump of the whole Database (e.g. a
    client's very first sync on join), use serialization.odin's
    database__serialize/deserialize instead — sync_channel__resync makes the
    two compose correctly (see its doc comment).

    Scope (v1 alpha): Table, Compact_Table, Tiny_Table (field-level diff) and
    Tag_Table (structural presence only, no component data) are supported.
    Arch_Table is not yet — registering one returns
    API_Error.Sync_Table_Type_Not_Supported (see arch_table.odin's own history
    of landing features in later phases for the same reason: this is a
    deliberately smaller first cut, not an oversight).

    Design notes:
      - Touched-marking (table__get_component_mut and friends) and the
        per-(channel,table) shadow buffer are both keyed by entity_id.ix, NOT
        by row id. `rid` moves under tail-swap/group-swap/pack; entity_id
        does not. A rid-keyed shadow would let a removed entity's leftover
        shadow bytes silently mask a *different* entity that later reuses
        that rid (if the new entity's true value happens to byte-match the
        stale shadow, that field would wrongly look "unchanged" and never be
        sent) — a real, silent, data-dependent under-sync bug. Keying by
        eid.ix avoids it entirely, and as a bonus means table_raw__swap_rows/
        pack need no sync hooks at all — only add_component/remove_component do.
      - A structural "added" event also marks the entity touched (see the
        table-type add_component hooks) — otherwise a component populated via
        add_component(eid, &data) and never subsequently written through
        get_component_mut would have a structural event but its initial
        field values would never actually be transmitted.
      - A structural "removed" event zeros that entity's shadow slot — so if
        the same eid.ix gets the component back later (same entity, or a
        different one reusing the index), the diff starts from zero, not
        from stale bytes.
      - Field layout ({offset, size} per top-level struct field) is computed
        once at registration via reflection (same runtime.Type_Info_Struct
        walk snapshot__type_is_pod already uses) and cached — never
        re-derived per tick. Byte comparison uses runtime.memory_equal (a
        bool fast-path, cheaper than an ordering compare).
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:testing"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Wire format — tight, unpadded (every byte matters for UDP, unlike the
// 8-byte-aligned snapshot format in serialization.odin).
//
//   Header (12B): magic u32, version u8, _pad u8, structural_count u16, table_section_count u16, _pad2 u16
//   Structural section: structural_count x { entity_id 8B, table_id u16, added u8 }              = 11B/event
//   Table sections: table_section_count x {
//       section header: table_id u32, entity_count u32                                           = 8B
//       entity_count x { entity_id 8B, field_mask u32, <changed field bytes, in field order> }    = 12B + changed bytes
//   }
//
// entity_id is sent in full (8 bytes) in v1 — correctness over squeezing
// bytes; a compact app-level id remap is a documented future optimization.

    @(private)
    SYNC_MAGIC :: u32(0x5345_444F) // "ODES" as little-endian bytes

    @(private)
    SYNC_VERSION :: u8(1)

    @(private)
    Sync_Header :: struct #packed {
        magic:                u32,
        version:              u8,
        _pad:                 u8,
        structural_count:     u16,
        table_section_count:  u16,
        _pad2:                u16,
    }

    @(private)
    Sync_Structural_Wire :: struct #packed {
        eid:      entity_id,
        table_id: u16,
        added:    u8,
    }

    @(private)
    Sync_Table_Section_Header :: struct #packed {
        table_id:     u32,
        entity_count: u32,
    }

///////////////////////////////////////////////////////////////////////////////
// Shared field-layout reflection (sender registration + receiver registration
// both need "top-level {offset, size} per field of this component type").

    @(private)
    Sync_Field :: struct {
        offset: u32,
        size:   u32,
    }

    @(private)
    // Top-level fields only — a nested struct/array field is treated as one
    // opaque blob (its own offset+size), not recursed into. Covers a
    // named-struct component (the common case), a bare-struct component, and
    // (falls through to "one field, the whole thing") a non-struct component
    // like a plain int/float/bool. Returns ok=false if the component has more
    // top-level fields than SYNC_MAX_FIELDS (the field-changed mask is one
    // bit per field).
    sync__compute_fields :: proc(ti: ^runtime.Type_Info, out: ^[SYNC_MAX_FIELDS]Sync_Field) -> (count: int, ok: bool) {
        base := ti
        if named, is_named := base.variant.(runtime.Type_Info_Named); is_named {
            base = named.base
        }

        #partial switch v in base.variant {
        case runtime.Type_Info_Struct:
            if int(v.field_count) > SYNC_MAX_FIELDS do return 0, false
            for i in 0..<int(v.field_count) {
                out[i] = Sync_Field{ offset = u32(v.offsets[i]), size = u32(v.types[i].size) }
            }
            return int(v.field_count), true
        case:
            out[0] = Sync_Field{ offset = 0, size = u32(ti.size) }
            return 1, true
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Sync_Channel — sender side. Tracks touched entities + a per-entity shadow
// of the last-collected bytes per registered table, and turns that into a
// tight delta buffer on demand.

    @(private)
    Sync_Table_Entry :: struct {
        table:      ^Shared_Table, // nil once the table has been terminated (see sync_channel__on_table_terminated)
        table_id:   table_id,
        comp_size:  int,
        fields:     [SYNC_MAX_FIELDS]Sync_Field,
        field_count: int,
        is_tag:     bool, // Tag_Table: structural-only, no shadow/fields

        shadow:         []byte,           // entities_cap * comp_size, keyed by eid.ix; nil for a tag
        touched:        oc.Dense_Arr(entity_id), // cap == entities_cap (see doc comment on sizing below)
        touched_bitset: []u64,            // ceil(entities_cap/64), O(1) dedup for `touched`
    }

    @(private)
    Sync_Structural_Event :: struct {
        eid:      entity_id,
        table_id: table_id,
        added:    bool,
    }

    Sync_Channel :: struct {
        state: Object_State,
        db:    ^Database,

        table_id_to_entry: []int, // len == TABLES_CAP, DELETED_INDEX when that table_id isn't registered
        entries:            []Sync_Table_Entry, // preallocated, len == tables_cap passed to init
        entries_count:      int,

        structural_events: oc.Dense_Arr(Sync_Structural_Event),
    }

    sync_channel__is_valid :: proc(self: ^Sync_Channel) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if self.table_id_to_entry == nil do return false
        if self.entries == nil do return false
        if !oc.dense_arr__is_valid(&self.structural_events) do return false

        return true
    }

    // tables_cap: max number of tables this channel can have registered at
    // once. structural_events_cap: max pending structural (add/remove) events
    // buffered between collects — a fixed, small cap (unlike touched/shadow,
    // this is NOT entities_cap-sized); if it fills up, further structural
    // events are dropped (the receiver just stays behind on that one change
    // until the next full resync — the same loss-tolerance a UDP packet drop
    // already implies).
    sync_channel__init :: proc(self: ^Sync_Channel, db: ^Database, tables_cap: int, structural_events_cap: int = 256, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(tables_cap > 0, loc = loc)
            assert(structural_events_cap > 0, loc = loc)
        }

        self.db = db
        self.entries_count = 0

        self.table_id_to_entry = make([]int, TABLES_CAP, db.allocator) or_return
        for i in 0..<len(self.table_id_to_entry) do self.table_id_to_entry[i] = DELETED_INDEX

        self.entries = make([]Sync_Table_Entry, tables_cap, db.allocator) or_return

        oc.dense_arr__init(&self.structural_events, structural_events_cap, db.allocator) or_return

        self.state = Object_State.Normal
        return nil
    }

    sync_channel__terminate :: proc(self: ^Sync_Channel) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.table != nil {
                derr := shared_table__detach_sync_channel(e.table, self)
                if derr != nil && derr != oc.Core_Error.Not_Found do return derr
            }
            if e.shadow != nil do delete(e.shadow, self.db.allocator) or_return
            oc.dense_arr__terminate(&e.touched, self.db.allocator) or_return
            if e.touched_bitset != nil do delete(e.touched_bitset, self.db.allocator) or_return
        }

        delete(self.entries, self.db.allocator) or_return
        delete(self.table_id_to_entry, self.db.allocator) or_return
        oc.dense_arr__terminate(&self.structural_events, self.db.allocator) or_return

        self.entries = nil
        self.table_id_to_entry = nil
        self.entries_count = 0
        self.db = nil

        self.state = Object_State.Not_Initialized
        return nil
    }

    sync_channel__clear :: proc(self: ^Sync_Channel) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.shadow != nil do mem.zero(raw_data(e.shadow), len(e.shadow))
            oc.dense_arr__zero(&e.touched)
            if e.touched_bitset != nil do mem.zero(raw_data(e.touched_bitset), len(e.touched_bitset) * size_of(u64))
        }
        oc.dense_arr__zero(&self.structural_events)

        return nil
    }

    sync_channel__memory_usage :: proc(self: ^Sync_Channel) -> int {
        total := size_of(self^)
        total += size_of(int) * len(self.table_id_to_entry)
        total += size_of(Sync_Table_Entry) * len(self.entries)
        for i in 0..<self.entries_count {
            e := &self.entries[i]
            total += len(e.shadow)
            total += oc.dense_arr__memory_usage(&e.touched)
            total += size_of(u64) * len(e.touched_bitset)
        }
        total += oc.dense_arr__memory_usage(&self.structural_events)
        return total
    }

    @(private)
    sync_channel__register_common :: proc(self: ^Sync_Channel, table: ^Shared_Table, ti: ^runtime.Type_Info, is_tag: bool, allow_non_pod: bool, loc := #caller_location) -> Error {
        when !SYNC_ENABLED {
            return API_Error.Sync_Feature_Disabled
        }

        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_channel__is_valid(self), loc = loc)
            assert(shared_table__is_valid(table), loc = loc)
            assert(table.db == self.db, loc = loc)
        }

        if table.type == Table_Type.Arch_Table do return API_Error.Sync_Table_Type_Not_Supported
        if self.table_id_to_entry[table.id] != DELETED_INDEX do return API_Error.Sync_Table_Already_Registered
        if self.entries_count >= len(self.entries) do return oc.Core_Error.Container_Is_Full

        fields: [SYNC_MAX_FIELDS]Sync_Field
        field_count := 0
        comp_size := 0

        if !is_tag {
            if !allow_non_pod && !snapshot__type_is_pod(ti) do return API_Error.Snapshot_Component_Not_POD
            comp_size = ti.size
            ok: bool
            field_count, ok = sync__compute_fields(ti, &fields)
            if !ok do return API_Error.Sync_Too_Many_Fields
        }

        entities_cap := self.db.overbase.id_factory.cap

        idx := self.entries_count
        e := &self.entries[idx]
        e.table = table
        e.table_id = table.id
        e.comp_size = comp_size
        e.fields = fields
        e.field_count = field_count
        e.is_tag = is_tag

        if !is_tag {
            shadow, serr := make([]byte, entities_cap * comp_size, self.db.allocator)
            if serr != nil do return serr
            e.shadow = shadow
        } else {
            e.shadow = nil
        }

        // touched is entities_cap-sized (NOT table.cap-sized): between two
        // collects, more than table.cap DISTINCT entities can plausibly have
        // been touched (e.g. add, remove, add-a-different-entity, repeat,
        // all before the next collect runs) even though at most table.cap
        // can be LIVE at any one instant. entities_cap is the only bound that
        // can never be exceeded, since touched_bitset dedups by eid.ix.
        terr := oc.dense_arr__init(&e.touched, entities_cap, self.db.allocator)
        if terr != nil {
            if e.shadow != nil do delete(e.shadow, self.db.allocator)
            return terr
        }

        bitset, berr := make([]u64, (entities_cap + 63) / 64, self.db.allocator)
        if berr != nil {
            if e.shadow != nil do delete(e.shadow, self.db.allocator)
            oc.dense_arr__terminate(&e.touched, self.db.allocator)
            return berr
        }
        e.touched_bitset = bitset

        aerr := shared_table__attach_sync_channel(table, self)
        if aerr != nil {
            if e.shadow != nil do delete(e.shadow, self.db.allocator)
            oc.dense_arr__terminate(&e.touched, self.db.allocator)
            delete(e.touched_bitset, self.db.allocator)
            e.table = nil
            return aerr
        }

        self.table_id_to_entry[table.id] = idx
        self.entries_count += 1

        return nil
    }

    sync_channel__register_table :: proc(self: ^Sync_Channel, table: ^Table($T), allow_non_pod := false, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(table__is_valid(table), loc = loc)
        return sync_channel__register_common(self, cast(^Shared_Table) table, type_info_of(typeid_of(T)), false, allow_non_pod, loc)
    }

    sync_channel__register_compact_table :: proc(self: ^Sync_Channel, table: ^Compact_Table($T), allow_non_pod := false, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(compact_table__is_valid(table), loc = loc)
        return sync_channel__register_common(self, cast(^Shared_Table) table, type_info_of(typeid_of(T)), false, allow_non_pod, loc)
    }

    sync_channel__register_tiny_table :: proc(self: ^Sync_Channel, table: ^Tiny_Table($T), allow_non_pod := false, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(tiny_table__is_valid(table), loc = loc)
        return sync_channel__register_common(self, cast(^Shared_Table) table, type_info_of(typeid_of(T)), false, allow_non_pod, loc)
    }

    sync_channel__register_tag_table :: proc(self: ^Sync_Channel, table: ^Tag_Table, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(tag_table__is_valid(table), loc = loc)
        return sync_channel__register_common(self, cast(^Shared_Table) table, nil, true, false, loc)
    }

    // Arch_Table is not yet supported (see this file's header comment) — this
    // overload exists purely so ecs.sync_register(&channel, &an_arch_table)
    // is a valid call that returns a clear, documented Error instead of
    // failing to compile (Arch_Table isn't a Table($T), so without this stub
    // no overload in the sync_register proc group would match it at all).
    sync_channel__register_arch_table :: proc(self: ^Sync_Channel, table: ^Arch_Table, allow_non_pod := false) -> Error {
        return API_Error.Sync_Table_Type_Not_Supported
    }

    sync_channel__unregister_table :: proc(self: ^Sync_Channel, table: ^Shared_Table, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_channel__is_valid(self), loc = loc)
        }

        if int(table.id) >= len(self.table_id_to_entry) do return oc.Core_Error.Not_Found
        idx := self.table_id_to_entry[table.id]
        if idx == DELETED_INDEX do return oc.Core_Error.Not_Found

        e := &self.entries[idx]
        derr := shared_table__detach_sync_channel(table, self)

        if e.shadow != nil do delete(e.shadow, self.db.allocator) or_return
        oc.dense_arr__terminate(&e.touched, self.db.allocator) or_return
        if e.touched_bitset != nil do delete(e.touched_bitset, self.db.allocator) or_return

        // swap-remove the entry; entries[0, entries_count) must stay dense
        last := self.entries_count - 1
        self.table_id_to_entry[table.id] = DELETED_INDEX
        if idx != last {
            self.entries[idx] = self.entries[last]
            self.table_id_to_entry[self.entries[idx].table_id] = idx
        }
        self.entries_count -= 1

        if derr != nil && derr != oc.Core_Error.Not_Found do return derr
        return nil
    }

    // Sets every registered table's shadow to its CURRENT live values and
    // drops all pending touched/structural queues. Call this right after
    // sending a full database__serialize snapshot to a (re)joining observer —
    // without it, the next collect_delta would re-send everything as if it
    // had all just changed, since the shadow would still be at its pre-snapshot
    // (usually all-zero) state.
    sync_channel__resync :: proc(self: ^Sync_Channel, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_channel__is_valid(self), loc = loc)
        }

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.table == nil do continue

            oc.dense_arr__zero(&e.touched)
            if e.touched_bitset != nil do mem.zero(raw_data(e.touched_bitset), len(e.touched_bitset) * size_of(u64))

            if e.is_tag do continue

            mem.zero(raw_data(e.shadow), len(e.shadow))
            n := shared_table__len(e.table)
            for rid in 0..<n {
                eid := shared_table__get_entity_by_row_number(e.table, rid)
                if is_not_set(eid) do continue // hole (mid-pause removal)
                c := shared_table__get_component(e.table, eid)
                if c == nil do continue
                off := eid.ix * e.comp_size
                mem.copy(&e.shadow[off], c, e.comp_size)
            }
        }

        oc.dense_arr__zero(&self.structural_events)
        return nil
    }

    // A cheap O(registered tables) WORST-CASE upper bound (assumes every
    // touched entity changed every field) — not an exact dry-run diff, which
    // would cost the same as collecting. Size a buffer to this and one
    // sync_collect_delta call is guaranteed to fully flush every pending change.
    sync_delta_max_size :: proc(self: ^Sync_Channel) -> int {
        size := size_of(Sync_Header)
        size += len(self.structural_events.items) * size_of(Sync_Structural_Wire)

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.table == nil || e.is_tag do continue
            n := len(e.touched.items)
            if n == 0 do continue
            size += size_of(Sync_Table_Section_Header)
            size += n * (size_of(entity_id) + size_of(u32) + e.comp_size)
        }

        return size
    }

    @(private)
    sync__untouch :: #force_inline proc(e: ^Sync_Table_Entry, eid: entity_id) {
        word := eid.ix / 64
        bit := u64(1) << uint(eid.ix % 64)
        e.touched_bitset[word] &~= bit
    }

    // Writes as much of the pending delta (structural events, then touched
    // component fields table-by-table) as fits into buf, and consumes exactly
    // what was written from the pending queues — nothing already flushed is
    // re-sent by a later call, nothing not-yet-flushed is lost. Stops entirely
    // (does not try to pack smaller later records into the remaining space)
    // on the first record that doesn't fit; whatever's left stays queued for
    // the next call. Only errors if buf can't even hold the fixed header.
    sync_collect_delta :: proc(self: ^Sync_Channel, buf: []byte, loc := #caller_location) -> (written: int, err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_channel__is_valid(self), loc = loc)
        }

        if len(buf) < size_of(Sync_Header) do return 0, API_Error.Sync_Buffer_Too_Small

        offset := size_of(Sync_Header)
        stop := false

        // Structural events: small fixed-size records, popped tail-backward
        // (Dense_Arr.remove_by_index at the last index is a pure truncation,
        // no swap-reorder — see ode_core/dense_arr.odin — so this never loses,
        // duplicates, or reorders whatever's left in the queue on a partial flush).
        structural_written := 0
        {
            i := len(self.structural_events.items) - 1
            for i >= 0 {
                if offset + size_of(Sync_Structural_Wire) > len(buf) {
                    stop = true
                    break
                }
                ev := self.structural_events.items[i]
                wire := Sync_Structural_Wire{ eid = ev.eid, table_id = u16(ev.table_id), added = ev.added ? u8(1) : u8(0) }
                mem.copy(&buf[offset], &wire, size_of(wire))
                offset += size_of(wire)
                structural_written += 1
                oc.dense_arr__remove_by_index(&self.structural_events, i)
                i -= 1
            }
        }

        table_sections_written := 0

        if !stop {
            for ei in 0..<self.entries_count {
                if stop do break

                e := &self.entries[ei]
                if e.table == nil || e.is_tag do continue
                if len(e.touched.items) == 0 do continue

                if offset + size_of(Sync_Table_Section_Header) > len(buf) {
                    stop = true
                    break
                }
                section_header_offset := offset
                offset += size_of(Sync_Table_Section_Header)

                section_entity_count := 0
                i := len(e.touched.items) - 1
                for i >= 0 {
                    eid := e.touched.items[i]

                    // Re-resolve fresh: the entity may have lost this
                    // component since being marked touched. Nothing to diff —
                    // the removal already produced its own structural event
                    // (and zeroed the shadow) via table_base__notify_sync_remove.
                    c := shared_table__get_component(e.table, eid)
                    if c == nil {
                        sync__untouch(e, eid)
                        oc.dense_arr__remove_by_index(&e.touched, i)
                        i -= 1
                        continue
                    }

                    max_record_size := size_of(entity_id) + size_of(u32) + e.comp_size
                    if offset + max_record_size > len(buf) {
                        stop = true
                        break
                    }

                    shadow_ptr := &e.shadow[eid.ix * e.comp_size]

                    mask: u32 = 0
                    write_cursor := offset + size_of(entity_id) + size_of(u32)
                    for fi in 0..<e.field_count {
                        f := e.fields[fi]
                        live_field := rawptr(uintptr(c) + uintptr(f.offset))
                        shadow_field := rawptr(uintptr(shadow_ptr) + uintptr(f.offset))
                        if !runtime.memory_equal(live_field, shadow_field, int(f.size)) {
                            mask |= u32(1) << uint(fi)
                            mem.copy(&buf[write_cursor], live_field, int(f.size))
                            write_cursor += int(f.size)
                        }
                    }

                    // Resync the shadow regardless of whether anything
                    // actually differed (a touch with no real edit — e.g.
                    // get_component_mut called but nothing written — is
                    // normal and costs nothing extra since c is already read).
                    mem.copy(shadow_ptr, c, e.comp_size)

                    if mask != 0 {
                        eid_copy := eid
                        mem.copy(&buf[offset], &eid_copy, size_of(entity_id))
                        mem.copy(&buf[offset + size_of(entity_id)], &mask, size_of(u32))
                        offset = write_cursor
                        section_entity_count += 1
                    }

                    sync__untouch(e, eid)
                    oc.dense_arr__remove_by_index(&e.touched, i)
                    i -= 1
                }

                if section_entity_count == 0 {
                    offset = section_header_offset // reclaim: nothing from this table made it in
                } else {
                    sh := Sync_Table_Section_Header{ table_id = u32(e.table_id), entity_count = u32(section_entity_count) }
                    mem.copy(&buf[section_header_offset], &sh, size_of(sh))
                    table_sections_written += 1
                }
            }
        }

        hdr := Sync_Header{
            magic                = SYNC_MAGIC,
            version              = SYNC_VERSION,
            structural_count     = u16(structural_written),
            table_section_count  = u16(table_sections_written),
        }
        mem.copy(&buf[0], &hdr, size_of(hdr))

        return offset, nil
    }

    @(private)
    // Called by every supported table type's terminate path (mirrors how a
    // View gets marked Invalid there). The table is being torn down out from
    // under this channel — don't touch its (already-terminating) Dense_Arr,
    // just forget the table pointer so collect_delta/unregister_table treat
    // this entry as dead. Its own shadow/touched/touched_bitset allocations
    // are freed later, unconditionally, by sync_channel__terminate.
    sync_channel__on_table_terminated :: proc(self: ^Sync_Channel, tid: table_id) {
        if self == nil || self.state != Object_State.Normal do return
        if int(tid) >= len(self.table_id_to_entry) do return
        idx := self.table_id_to_entry[tid]
        if idx == DELETED_INDEX do return
        self.entries[idx].table = nil
    }

    @(private)
    sync_channel__mark_touched :: proc(self: ^Sync_Channel, tid: table_id, eid: entity_id) {
        if self == nil || self.state != Object_State.Normal do return
        if int(tid) >= len(self.table_id_to_entry) do return
        idx := self.table_id_to_entry[tid]
        if idx == DELETED_INDEX do return
        e := &self.entries[idx]
        if e.table == nil || e.is_tag do return

        word := eid.ix / 64
        bit := u64(1) << uint(eid.ix % 64)
        if e.touched_bitset[word] & bit != 0 do return // already pending, dedup

        e.touched_bitset[word] |= bit
        _, err := oc.dense_arr__add(&e.touched, eid)
        when VALIDATIONS {
            assert(err == nil, "sync touched list overflow — should be impossible, touched.cap == entities_cap and entries are bitset-deduped")
        }
    }

    @(private)
    sync_channel__notify_structural :: proc(self: ^Sync_Channel, tid: table_id, eid: entity_id, added: bool) {
        if self == nil || self.state != Object_State.Normal do return
        if int(tid) >= len(self.table_id_to_entry) do return
        idx := self.table_id_to_entry[tid]
        if idx == DELETED_INDEX do return
        e := &self.entries[idx]
        if e.table == nil do return

        if !added && !e.is_tag {
            // See this file's header note on why the shadow is entity-indexed
            // and must not leak a departed entity's bytes to whoever reuses eid.ix.
            off := eid.ix * e.comp_size
            mem.zero(&e.shadow[off], e.comp_size)
        }

        // structural_events has a small fixed cap (not entities_cap-sized) —
        // silently drop on overflow rather than error; the receiver just
        // stays behind on this one change until the next resync, same
        // tolerance a dropped UDP packet already implies.
        _, _ = oc.dense_arr__add(&self.structural_events, Sync_Structural_Event{ eid = eid, table_id = tid, added = added })
    }

///////////////////////////////////////////////////////////////////////////////
// Sync_Decoder — receiver side. Lighter than Sync_Channel: no shadow, no
// touched tracking, no watcher registration on the table — just enough
// per-table field-layout info to decode collect_delta's wire format and
// apply it. Uses the exact same field-layout reflection as the sender, so a
// sender/receiver pair registered with matching schemas always agree on how
// to slice a component's bytes.

    @(private)
    Sync_Decoder_Entry :: struct {
        table:       ^Shared_Table,
        table_id:    table_id,
        comp_size:   int,
        fields:      [SYNC_MAX_FIELDS]Sync_Field,
        field_count: int,
        is_tag:      bool,
    }

    Sync_Decoder :: struct {
        state: Object_State,
        db:    ^Database,

        table_id_to_entry: []int,
        entries:            []Sync_Decoder_Entry,
        entries_count:      int,
    }

    sync_decoder__is_valid :: proc(self: ^Sync_Decoder) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if self.table_id_to_entry == nil do return false
        if self.entries == nil do return false

        return true
    }

    sync_decoder__init :: proc(self: ^Sync_Decoder, db: ^Database, tables_cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(tables_cap > 0, loc = loc)
        }

        self.db = db
        self.entries_count = 0

        self.table_id_to_entry = make([]int, TABLES_CAP, db.allocator) or_return
        for i in 0..<len(self.table_id_to_entry) do self.table_id_to_entry[i] = DELETED_INDEX

        self.entries = make([]Sync_Decoder_Entry, tables_cap, db.allocator) or_return

        self.state = Object_State.Normal
        return nil
    }

    sync_decoder__terminate :: proc(self: ^Sync_Decoder) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        delete(self.entries, self.db.allocator) or_return
        delete(self.table_id_to_entry, self.db.allocator) or_return

        self.entries = nil
        self.table_id_to_entry = nil
        self.entries_count = 0
        self.db = nil

        self.state = Object_State.Not_Initialized
        return nil
    }

    sync_decoder__memory_usage :: proc(self: ^Sync_Decoder) -> int {
        total := size_of(self^)
        total += size_of(int) * len(self.table_id_to_entry)
        total += size_of(Sync_Decoder_Entry) * len(self.entries)
        return total
    }

    @(private)
    sync_decoder__register_common :: proc(self: ^Sync_Decoder, table: ^Shared_Table, ti: ^runtime.Type_Info, is_tag: bool, allow_non_pod: bool, loc := #caller_location) -> Error {
        when !SYNC_ENABLED {
            return API_Error.Sync_Feature_Disabled
        }

        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_decoder__is_valid(self), loc = loc)
            assert(shared_table__is_valid(table), loc = loc)
            assert(table.db == self.db, loc = loc)
        }

        if table.type == Table_Type.Arch_Table do return API_Error.Sync_Table_Type_Not_Supported
        if self.table_id_to_entry[table.id] != DELETED_INDEX do return API_Error.Sync_Table_Already_Registered
        if self.entries_count >= len(self.entries) do return oc.Core_Error.Container_Is_Full

        fields: [SYNC_MAX_FIELDS]Sync_Field
        field_count := 0
        comp_size := 0

        if !is_tag {
            if !allow_non_pod && !snapshot__type_is_pod(ti) do return API_Error.Snapshot_Component_Not_POD
            comp_size = ti.size
            ok: bool
            field_count, ok = sync__compute_fields(ti, &fields)
            if !ok do return API_Error.Sync_Too_Many_Fields
        }

        idx := self.entries_count
        self.entries[idx] = Sync_Decoder_Entry{
            table = table, table_id = table.id, comp_size = comp_size,
            fields = fields, field_count = field_count, is_tag = is_tag,
        }
        self.table_id_to_entry[table.id] = idx
        self.entries_count += 1

        return nil
    }

    sync_decoder__register_table :: proc(self: ^Sync_Decoder, table: ^Table($T), allow_non_pod := false, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(table__is_valid(table), loc = loc)
        return sync_decoder__register_common(self, cast(^Shared_Table) table, type_info_of(typeid_of(T)), false, allow_non_pod, loc)
    }

    sync_decoder__register_compact_table :: proc(self: ^Sync_Decoder, table: ^Compact_Table($T), allow_non_pod := false, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(compact_table__is_valid(table), loc = loc)
        return sync_decoder__register_common(self, cast(^Shared_Table) table, type_info_of(typeid_of(T)), false, allow_non_pod, loc)
    }

    sync_decoder__register_tiny_table :: proc(self: ^Sync_Decoder, table: ^Tiny_Table($T), allow_non_pod := false, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(tiny_table__is_valid(table), loc = loc)
        return sync_decoder__register_common(self, cast(^Shared_Table) table, type_info_of(typeid_of(T)), false, allow_non_pod, loc)
    }

    sync_decoder__register_tag_table :: proc(self: ^Sync_Decoder, table: ^Tag_Table, loc := #caller_location) -> Error {
        when VALIDATIONS do assert(tag_table__is_valid(table), loc = loc)
        return sync_decoder__register_common(self, cast(^Shared_Table) table, nil, true, false, loc)
    }

    // See sync_channel__register_arch_table's doc comment.
    sync_decoder__register_arch_table :: proc(self: ^Sync_Decoder, table: ^Arch_Table, allow_non_pod := false) -> Error {
        return API_Error.Sync_Table_Type_Not_Supported
    }

    // Parses and applies one collect_delta buffer. Tolerates (silently skips)
    // an unknown/expired entity_id — normal for a receiver that's briefly
    // behind the sender. A table_id the decoder never registered is treated
    // as a schema mismatch (Snapshot_Schema_Mismatch) rather than skipped:
    // unlike an unknown entity, there is no way to know how many payload
    // bytes to skip past without knowing that table's field layout, so the
    // rest of the buffer can't be safely parsed either — this can only
    // happen if the sender/receiver schemas disagree, which isn't something
    // to silently recover from. Already-applied effects from earlier in the
    // same buffer are NOT rolled back in that case (each collected delta is
    // an incremental tick, not an atomic snapshot — see serialization.odin's
    // database__deserialize for the fully-atomic alternative).
    sync_apply_delta :: proc(self: ^Sync_Decoder, data: []byte, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_decoder__is_valid(self), loc = loc)
        }

        if len(data) < size_of(Sync_Header) do return API_Error.Snapshot_Invalid

        hdr: Sync_Header
        mem.copy(&hdr, raw_data(data), size_of(hdr))
        if hdr.magic != SYNC_MAGIC do return API_Error.Snapshot_Invalid
        if hdr.version != SYNC_VERSION do return API_Error.Snapshot_Version_Mismatch

        offset := size_of(Sync_Header)

        for _ in 0..<int(hdr.structural_count) {
            if offset + size_of(Sync_Structural_Wire) > len(data) do return API_Error.Snapshot_Invalid
            wire: Sync_Structural_Wire
            mem.copy(&wire, &data[offset], size_of(wire))
            offset += size_of(wire)

            eid := wire.eid
            tid := table_id(wire.table_id)

            if database__is_entity_correct(self.db, eid) != nil do continue // tolerated: unknown/expired
            if int(tid) >= len(self.table_id_to_entry) do continue
            idx := self.table_id_to_entry[tid]
            if idx == DELETED_INDEX do continue // not registered on this decoder — tolerated skip
            e := &self.entries[idx]
            if e.table == nil do continue

            if wire.added != 0 {
                _, _ = shared_table__add_component(e.table, eid, nil) // Already_Exist tolerated (idempotent)
            } else {
                _ = shared_table__remove_component(e.table, eid) // Not_Found tolerated (idempotent)
            }
        }

        for _ in 0..<int(hdr.table_section_count) {
            if offset + size_of(Sync_Table_Section_Header) > len(data) do return API_Error.Snapshot_Invalid
            sh: Sync_Table_Section_Header
            mem.copy(&sh, &data[offset], size_of(sh))
            offset += size_of(sh)

            tid := table_id(sh.table_id)
            idx := DELETED_INDEX
            if int(tid) < len(self.table_id_to_entry) do idx = self.table_id_to_entry[tid]

            e: ^Sync_Decoder_Entry
            if idx != DELETED_INDEX do e = &self.entries[idx]
            if e == nil || e.table == nil do return API_Error.Snapshot_Schema_Mismatch

            for _ in 0..<int(sh.entity_count) {
                if offset + size_of(entity_id) + size_of(u32) > len(data) do return API_Error.Snapshot_Invalid
                eid: entity_id
                mem.copy(&eid, &data[offset], size_of(entity_id))
                offset += size_of(entity_id)
                mask: u32
                mem.copy(&mask, &data[offset], size_of(u32))
                offset += size_of(u32)

                comp: rawptr
                if database__is_entity_correct(self.db, eid) == nil {
                    comp = shared_table__get_component(e.table, eid)
                }

                for fi in 0..<e.field_count {
                    if mask & (u32(1) << uint(fi)) == 0 do continue
                    f := e.fields[fi]
                    if offset + int(f.size) > len(data) do return API_Error.Snapshot_Invalid
                    if comp != nil {
                        mem.copy(rawptr(uintptr(comp) + uintptr(f.offset)), &data[offset], int(f.size))
                    }
                    offset += int(f.size)
                }
            }
        }

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Tests — only exist when the feature is actually compiled in (see this
// file's header comment): with SYNC_ENABLED off, sync_register always
// returns Sync_Feature_Disabled, so these tests' assumptions (registration
// succeeding, entries[0] existing, etc.) don't hold and blow up in ways that
// range from a normal assertion failure to a bounds-check panic — cleaner to
// just not compile them in at all, mirroring how the maps package's tests
// require -define:maps_testing=true to exist rather than to pass.

when SYNC_ENABLED {

    @(private="file")
    Sync_XY :: struct { x: int, y: int }

    // A structural "add" already marks the entity touched (see
    // table_base__notify_sync_add) — a subsequent get_component_mut on the
    // same entity, called any number of times before the next collect, must
    // not add a second, duplicate touched entry.
    @(test)
    sync__mark_touched_dedup__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        tbl: Table(Sync_XY)
        ch: Sync_Channel
        defer database__terminate(&db)
        defer sync_channel__terminate(&ch)

        testing.expect(t, database__init(&db, 10, allocator) == nil)
        testing.expect(t, table__init(&tbl, &db, 10) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &tbl) == nil)

        eid_a, aerr := database__create_entity(&db)
        testing.expect(t, aerr == nil)
        ca, caerr := table__add_component(&tbl, eid_a)
        testing.expect(t, caerr == nil)
        ca.x = 1
        ca.y = 2

        _ = table__get_component_mut(&tbl, eid_a)
        _ = table__get_component_mut(&tbl, eid_a)
        _ = table__get_component_mut(&tbl, eid_a)

        testing.expect(t, len(ch.entries[0].touched.items) == 1)
        testing.expect(t, ch.entries[0].touched.items[0] == eid_a)

        eid_b, berr := database__create_entity(&db)
        testing.expect(t, berr == nil)
        _, cberr := table__add_component(&tbl, eid_b)
        testing.expect(t, cberr == nil)

        testing.expect(t, len(ch.entries[0].touched.items) == 2) // a genuinely different entity DOES add a second entry
    }

    // Only the bytes of fields that actually changed go on the wire — verified
    // by exact byte-count rather than by decoding, so this doubles as a check
    // that collect_delta's format matches this file's own header doc comment.
    @(test)
    sync__field_mask_single_field_change__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        tbl: Table(Sync_XY)
        ch: Sync_Channel
        defer database__terminate(&db)
        defer sync_channel__terminate(&ch)

        testing.expect(t, database__init(&db, 10, allocator) == nil)
        testing.expect(t, table__init(&tbl, &db, 10) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &tbl) == nil)

        eid, eerr := database__create_entity(&db)
        testing.expect(t, eerr == nil)
        c, cerr := table__add_component(&tbl, eid)
        testing.expect(t, cerr == nil)
        c.x = 1
        c.y = 2

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        // brand new entity: both fields differ from the zeroed shadow, plus
        // the structural "added" event add_component itself queued
        written1, werr1 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr1 == nil)
        expected1 := size_of(Sync_Header) + size_of(Sync_Structural_Wire) + size_of(Sync_Table_Section_Header) + size_of(entity_id) + size_of(u32) + 2 * size_of(int)
        testing.expect(t, written1 == expected1, "expected both fields on the wire for a brand new component")

        // mutate only x
        mc := table__get_component_mut(&tbl, eid)
        mc.x = 100

        written2, werr2 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr2 == nil)
        expected2 := size_of(Sync_Header) + size_of(Sync_Table_Section_Header) + size_of(entity_id) + size_of(u32) + 1 * size_of(int)
        testing.expect(t, written2 == expected2, "expected exactly one field's bytes on the wire")

        // nothing touched since -> header only
        written3, werr3 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr3 == nil)
        testing.expect(t, written3 == size_of(Sync_Header))
    }

    // Regression test for the shadow-indexing bug caught during design: the
    // shadow must be keyed by entity_id.ix (never leaking a departed entity's
    // bytes to whichever entity reuses that index later), not by row id.
    // entities_cap=1 forces the SAME ix to be reused by a second, distinct
    // entity; that entity writes the exact same byte pattern the first one
    // had, and must still be reported as "changed" (a brand new entity the
    // receiver has never seen must never be silently skipped).
    @(test)
    sync__shadow_not_leaked_across_reused_entity_id__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        tbl: Table(Sync_XY)
        ch: Sync_Channel
        defer database__terminate(&db)
        defer sync_channel__terminate(&ch)

        testing.expect(t, database__init(&db, 1, allocator) == nil) // cap 1: forces ix reuse
        testing.expect(t, table__init(&tbl, &db, 1) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &tbl) == nil)

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        eid_a, aerr := database__create_entity(&db)
        testing.expect(t, aerr == nil)
        ca, caerr := table__add_component(&tbl, eid_a)
        testing.expect(t, caerr == nil)
        ca.x = 5
        ca.y = 5

        _, cerr1 := sync_collect_delta(&ch, buf) // shadow[eid_a.ix] := {5, 5}
        testing.expect(t, cerr1 == nil)

        testing.expect(t, database__destroy_entity(&db, eid_a) == nil) // removes the component -> zeroes the shadow slot

        eid_z, zerr := database__create_entity(&db) // reuses the same ix, bumped generation
        testing.expect(t, zerr == nil)
        testing.expect(t, eid_z.ix == eid_a.ix)
        testing.expect(t, eid_z != eid_a)

        cz, czerr := table__add_component(&tbl, eid_z)
        testing.expect(t, czerr == nil)
        cz.x = 5 // identical bytes to what A had
        cz.y = 5

        written, werr := sync_collect_delta(&ch, buf)
        testing.expect(t, werr == nil)
        // 2 structural events pending (A's removal, Z's add) plus Z's value record
        expected := size_of(Sync_Header) + 2 * size_of(Sync_Structural_Wire) + size_of(Sync_Table_Section_Header) + size_of(entity_id) + size_of(u32) + 2 * size_of(int)
        testing.expect(t, written == expected, "a reused entity id's matching-old-bytes value must still be reported as changed")
    }

    // An undersized buffer must flush exactly as much as fits, in order, and
    // leave the rest correctly queued for the next call — nothing lost,
    // duplicated, or reordered.
    @(test)
    sync__partial_collect_undersized_buffer__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        tbl: Table(Sync_XY)
        ch: Sync_Channel
        defer database__terminate(&db)
        defer sync_channel__terminate(&ch)

        testing.expect(t, database__init(&db, 10, allocator) == nil)
        testing.expect(t, table__init(&tbl, &db, 10) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &tbl) == nil)

        big_buf := make([]byte, 4096, allocator)
        defer delete(big_buf, allocator)

        eids: [3]entity_id
        for i in 0..<3 {
            eid, eerr := database__create_entity(&db)
            testing.expect(t, eerr == nil)
            eids[i] = eid
            c, cerr := table__add_component(&tbl, eid)
            testing.expect(t, cerr == nil)
            c.x = i + 1
            c.y = i + 1
        }

        // drain the 3 structural-add events + their initial values first, so
        // the partial-collect phase below deals with pure value records only
        _, derr := sync_collect_delta(&ch, big_buf)
        testing.expect(t, derr == nil)
        testing.expect(t, len(ch.entries[0].touched.items) == 0)
        testing.expect(t, len(ch.structural_events.items) == 0)

        // mutate BOTH fields: collect_delta's partial-fit check is a
        // conservative worst-case (offset + entity_id + mask + comp_size,
        // not the actual changed-byte count — see its own doc comment), so
        // sizing small_buf to fit exactly one record only lines up with
        // reality when the record's actual size equals that worst case.
        for i in 0..<3 {
            mc := table__get_component_mut(&tbl, eids[i])
            mc.x = 100 + i
            mc.y = 100 + i
        }
        testing.expect(t, len(ch.entries[0].touched.items) == 3)

        record_size := size_of(entity_id) + size_of(u32) + 2 * size_of(int)
        small_buf := make([]byte, size_of(Sync_Header) + size_of(Sync_Table_Section_Header) + record_size, allocator)
        defer delete(small_buf, allocator)

        written1, werr1 := sync_collect_delta(&ch, small_buf)
        testing.expect(t, werr1 == nil)
        testing.expect(t, written1 == len(small_buf), "exactly one record should have fit")
        testing.expect(t, len(ch.entries[0].touched.items) == 2, "the other two must remain queued")

        written2, werr2 := sync_collect_delta(&ch, big_buf)
        testing.expect(t, werr2 == nil)
        expected2 := size_of(Sync_Header) + size_of(Sync_Table_Section_Header) + 2 * record_size
        testing.expect(t, written2 == expected2, "the second call must flush exactly the remaining two")
        testing.expect(t, len(ch.entries[0].touched.items) == 0)
    }

    // Structural add/remove round-trips through a Sync_Decoder onto a
    // separate mirrored Database sharing the same Overbase (so entity ids are
    // valid on both sides, mirroring how a real sender/receiver pair agrees
    // on entity identity). Also covers the "unknown/expired entity_id on
    // apply is a tolerated skip" contract via a hand-crafted buffer.
    @(test)
    sync__structural_roundtrip_and_tolerated_skip__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        ob: Overbase
        db_send: Database
        db_recv: Database
        tag_send: Tag_Table
        tag_recv: Tag_Table
        ch: Sync_Channel
        dec: Sync_Decoder
        defer overbase__terminate(&ob)
        defer database__terminate(&db_send)
        defer database__terminate(&db_recv)
        defer sync_channel__terminate(&ch)
        defer sync_decoder__terminate(&dec)

        testing.expect(t, overbase__init(&ob, 10, 2, allocator) == nil)
        testing.expect(t, database__init_from_overbase(&db_send, &ob) == nil)
        testing.expect(t, database__init_from_overbase(&db_recv, &ob) == nil)

        testing.expect(t, tag_table__init(&tag_send, &db_send, 10) == nil)
        testing.expect(t, tag_table__init(&tag_recv, &db_recv, 10) == nil)

        testing.expect(t, sync_channel__init(&ch, &db_send, 4) == nil)
        testing.expect(t, sync_channel__register_tag_table(&ch, &tag_send) == nil)
        testing.expect(t, sync_decoder__init(&dec, &db_recv, 4) == nil)
        testing.expect(t, sync_decoder__register_tag_table(&dec, &tag_recv) == nil)

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        eid, eerr := overbase__create_entity(&ob)
        testing.expect(t, eerr == nil)

        testing.expect(t, tag_table__add_tag(&tag_send, eid) == nil)

        written, werr := sync_collect_delta(&ch, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, sync_apply_delta(&dec, buf[:written]) == nil)
        testing.expect(t, tag_table__has_tag(&tag_recv, eid))

        // tolerated skip: a structural event naming an entity the receiver
        // doesn't (yet) recognize as live must not error
        bogus := entity_id{ ix = 9999 }
        testing.expect(t, database__is_entity_correct(&db_recv, bogus) != nil) // sanity: really is invalid

        hdr := Sync_Header{ magic = SYNC_MAGIC, version = SYNC_VERSION, structural_count = 1 }
        mem.copy(&buf[0], &hdr, size_of(hdr))
        wire := Sync_Structural_Wire{ eid = bogus, table_id = u16(tag_send.id), added = 1 }
        mem.copy(&buf[size_of(Sync_Header)], &wire, size_of(wire))
        testing.expect(t, sync_apply_delta(&dec, buf[:size_of(Sync_Header) + size_of(Sync_Structural_Wire)]) == nil)

        testing.expect(t, tag_table__remove_tag(&tag_send, eid) == nil)
        written2, werr2 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr2 == nil)
        testing.expect(t, sync_apply_delta(&dec, buf[:written2]) == nil)
        testing.expect(t, !tag_table__has_tag(&tag_recv, eid))
    }

    // Arch_Table is out of scope for v1 — registering one must return a
    // clear, documented error on both the sender and receiver side, not
    // silently do nothing (and not fail to compile — see the two stub procs'
    // own doc comments for why they exist at all).
    @(test)
    sync__arch_table_registration_rejected__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: Database
        arch: Arch_Table
        ch: Sync_Channel
        dec: Sync_Decoder
        defer database__terminate(&db)
        defer arch_table__terminate(&arch)
        defer sync_channel__terminate(&ch)
        defer sync_decoder__terminate(&dec)

        testing.expect(t, database__init(&db, 10, allocator) == nil)
        testing.expect(t, arch_table__init(&arch, &db, 10, {Sync_XY}) == nil)
        testing.expect(t, sync_channel__init(&ch, &db, 4) == nil)
        testing.expect(t, sync_decoder__init(&dec, &db, 4) == nil)

        testing.expect(t, sync_channel__register_arch_table(&ch, &arch) == API_Error.Sync_Table_Type_Not_Supported)
        testing.expect(t, sync_decoder__register_arch_table(&dec, &arch) == API_Error.Sync_Table_Type_Not_Supported)
    }

} // when SYNC_ENABLED

/*
    2026 (c) Oleh, https://github.com/zm69

    Binary snapshot serialization of a whole Database: entities (with their
    generations, so saved entity_ids stay valid after load), components, tags
    and relations round-trip; views and groups are derived data and are rebuilt
    on load instead of being stored.

    Scope (v2): components must be POD — no pointers, slices, strings, maps or
    dynamic arrays inside them (their rows are copied as raw bytes). serialize
    rejects non-POD component types unless allow_non_pod = true is passed.
    Per-table user serialize/deserialize callbacks for non-POD components are
    deliberately left for a future version.

    Loading requires an already-initialized Database with a matching schema:
    the same tables initialized in the same order (and with the same
    init/terminate history, so table ids coincide), same component types, and
    capacities no smaller than the saved data. Deserialization is all-or-nothing:
    the whole buffer is validated before anything is mutated.

    Entity-id ownership (v2): a Database that owns its Overbase (the common,
    plain ecs.init case) still snapshots the entity-id space (generations,
    freed list) together with its tables, exactly as v1 did. A Database
    attached to a *shared* Overbase (ecs.init_from_overbase) instead omits
    that section — deserialize never touches shared id-space state a sibling
    Database also depends on. Row entity_ids are validated against the
    snapshot's own recorded id state when this Database owns the section, or
    against the live Overbase otherwise (see snapshot__validate_row_eid). To
    save/restore the shared id-space itself, use Overbase's own
    overbase_serialize/overbase_deserialize (overbase_serialization.odin).
    See docs/overbase.md.

    The wire format depends on the Table_Type enum values and on the ix_gen
    bit_field packing (ix:56/gen:8) — changing either requires bumping
    SNAPSHOT_VERSION.
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:os"
    import "core:slice"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

///////////////////////////////////////////////////////////////////////////////
// Format

    @(private)
    SNAPSHOT_MAGIC :: u64(0x4244_5343_4545_444F) // "ODEECSDB" as little-endian bytes

    @(private)
    SNAPSHOT_VERSION :: u32(2)

    // Written and compared as a raw u32: a snapshot produced on a machine with
    // different endianness reads back as a different value and is rejected.
    @(private)
    SNAPSHOT_ENDIAN_CHECK :: u32(0x0A0B0C0D)

    @(private)
    SNAPSHOT_FLAG__HAS_RELATIONS :: u32(1 << 0)

    // Set when the entity-id section (items/freed blob right after the
    // header) is present in the buffer. Written iff the saving Database owns
    // its Overbase — see the entity-id ownership note at the top of this file.
    @(private)
    SNAPSHOT_FLAG__HAS_ENTITY_ID_SECTION :: u32(1 << 1)

    @(private)
    Snapshot_Header :: struct #packed {
        magic:         u64,
        version:       u32,
        endian_check:  u32,
        flags:         u32,
        _reserved:     u32,
        entities_cap:  i64, // saved db.overbase.id_factory.cap
        created_count: i64, // factory state
        freed_count:   i64,
        section_count: i64, // number of table sections that follow
    }

    @(private)
    Snap_Table_Header :: struct #packed {
        table_id:   i64,
        table_type: i32, // Table_Type
        _pad:       i32,
        comp_size:  i64, // 0 for Tag_Table
        comp_align: i64, // 0 for Tag_Table
        cap:        i64, // informational; load only requires len <= target cap
        len:        i64,
        name_len:   i64, // "pkg.Name" of the component type; 0 for Tag_Table/unnamed
    }

    @(private)
    Snap_Relations_Header :: struct #packed {
        cap:   i64, // informational; load only requires count <= target cap
        count: i64,
    }

    // Every variable-length blob is followed by zero padding up to an 8-byte
    // boundary, so all headers and entity_id/int blobs stay 8-aligned within
    // the buffer.
    @(private)
    snap__align8 :: #force_inline proc "contextless" (offset: int) -> int {
        return (offset + 7) &~ 7
    }

///////////////////////////////////////////////////////////////////////////////
// Writer / Reader — cursors over a []byte buffer

    @(private)
    Snap_Writer :: struct {
        buf: []byte,
        offset: int,
    }

    @(private)
    snap_writer__write :: proc(self: ^Snap_Writer, src: rawptr, #any_int size: int) {
        if size <= 0 do return
        assert(self.offset + size <= len(self.buf))
        mem.copy(&self.buf[self.offset], src, size)
        self.offset += size
    }

    @(private)
    // Zero (not skip) the padding so serializing the same state twice yields
    // byte-identical buffers.
    snap_writer__pad8 :: proc(self: ^Snap_Writer) {
        aligned := snap__align8(self.offset)
        for self.offset < aligned {
            self.buf[self.offset] = 0
            self.offset += 1
        }
    }

    @(private)
    Snap_Reader :: struct {
        data: []byte,
        offset: int,
    }

    @(private)
    snap_reader__bytes :: proc(self: ^Snap_Reader, #any_int size: int) -> ([]byte, Error) {
        if size < 0 || self.offset + size > len(self.data) do return nil, API_Error.Snapshot_Invalid
        res := self.data[self.offset : self.offset + size]
        self.offset += size
        return res, nil
    }

    @(private)
    snap_reader__read :: proc(self: ^Snap_Reader, dst: rawptr, #any_int size: int) -> Error {
        b := snap_reader__bytes(self, size) or_return
        mem.copy(dst, raw_data(b), size)
        return nil
    }

    @(private)
    snap_reader__pad8 :: proc(self: ^Snap_Reader) -> Error {
        _ = snap_reader__bytes(self, snap__align8(self.offset) - self.offset) or_return
        return nil
    }

    @(private)
    snap_reader__entity_ids :: proc(self: ^Snap_Reader, #any_int count: int) -> (res: []entity_id, err: Error) {
        b := snap_reader__bytes(self, count * size_of(entity_id)) or_return
        return slice.reinterpret([]entity_id, b), nil
    }

///////////////////////////////////////////////////////////////////////////////
// Component type helpers

    @(private)
    // A type is POD (safe to blob-copy) when it contains no pointers, strings,
    // slices, dynamic arrays, maps, anys, typeids or procedures at any depth.
    snapshot__type_is_pod :: proc(ti: ^runtime.Type_Info) -> bool {
        if ti == nil do return false

        #partial switch v in ti.variant {
            case runtime.Type_Info_Named:
                return snapshot__type_is_pod(v.base)
            case runtime.Type_Info_Integer, runtime.Type_Info_Rune, runtime.Type_Info_Float,
                 runtime.Type_Info_Complex, runtime.Type_Info_Quaternion, runtime.Type_Info_Boolean,
                 runtime.Type_Info_Enum, runtime.Type_Info_Bit_Set, runtime.Type_Info_Bit_Field:
                return true
            case runtime.Type_Info_Array:
                return snapshot__type_is_pod(v.elem)
            case runtime.Type_Info_Enumerated_Array:
                return snapshot__type_is_pod(v.elem)
            case runtime.Type_Info_Matrix:
                return snapshot__type_is_pod(v.elem)
            case runtime.Type_Info_Simd_Vector:
                return snapshot__type_is_pod(v.elem)
            case runtime.Type_Info_Struct:
                for i in 0..<v.field_count {
                    if !snapshot__type_is_pod(v.types[i]) do return false
                }
                return true
            case runtime.Type_Info_Union:
                for variant in v.variants {
                    if !snapshot__type_is_pod(variant) do return false
                }
                return true
        }

        // pointers, multi-pointers, strings, slices, dynamic arrays, maps,
        // any, typeid, procedures, soa pointers, ...
        return false
    }

    @(private)
    // Length of the "pkg.Name" identity string written for a component type;
    // 0 when the type is not a named type.
    snapshot__name_len :: proc(ti: ^runtime.Type_Info) -> int {
        if ti == nil do return 0
        named, ok := ti.variant.(runtime.Type_Info_Named)
        if !ok || len(named.name) == 0 do return 0

        n := len(named.name)
        if len(named.pkg) > 0 do n += len(named.pkg) + 1
        return n
    }

    @(private)
    snap_writer__write_name :: proc(self: ^Snap_Writer, ti: ^runtime.Type_Info) {
        named, ok := ti.variant.(runtime.Type_Info_Named)
        if !ok || len(named.name) == 0 do return

        if len(named.pkg) > 0 {
            snap_writer__write(self, raw_data(named.pkg), len(named.pkg))
            dot: byte = '.'
            snap_writer__write(self, &dot, 1)
        }
        snap_writer__write(self, raw_data(named.name), len(named.name))
    }

    @(private)
    // Either side without a name (name_len == 0 / unnamed target type) skips
    // the check — size/align matching still applies.
    snapshot__name_matches :: proc(ti: ^runtime.Type_Info, name_bytes: []byte) -> bool {
        expected := snapshot__name_len(ti)
        if expected == 0 || len(name_bytes) == 0 do return true
        if expected != len(name_bytes) do return false

        named, _ := ti.variant.(runtime.Type_Info_Named)
        idx := 0
        if len(named.pkg) > 0 {
            if string(name_bytes[:len(named.pkg)]) != named.pkg do return false
            if name_bytes[len(named.pkg)] != '.' do return false
            idx = len(named.pkg) + 1
        }
        return string(name_bytes[idx:]) == named.name
    }

///////////////////////////////////////////////////////////////////////////////
// Table dispatch helpers


    @(private)
    shared_table__snapshot_holes_count :: proc(table: ^Shared_Table) -> int {
        switch table.type {
            case Table_Type.Unknown:
                return 0
            case Table_Type.Table:
                return (cast(^Table_Base) table).holes_count
            case Table_Type.Compact_Table:
                return (cast(^Compact_Table_Base) table).holes_count
            case Table_Type.Tiny_Table:
                return (cast(^Tiny_Table_Base) table).holes_count
            case Table_Type.Tag_Table:
                return (cast(^Tag_Table) table).holes_count
        }
        return 0
    }

    @(private)
    // Row count for the snapshot payload. For Tag_Table this is the rows slice
    // length (== map count while there are no holes, which serialize enforces).
    shared_table__snapshot_len :: proc(table: ^Shared_Table) -> int {
        if table.type == Table_Type.Tag_Table {
            return (^runtime.Raw_Slice)(&(cast(^Tag_Table) table).rows).len
        }
        return shared_table__len(table)
    }

    @(private)
    // A snapshot must capture a packed database: no deferred packing in flight
    // and (for save) no holes in any table. Holes would put dead rows into the
    // rows blob; call resume_packing/pack first.
    database__snapshot_check_not_paused :: proc(self: ^Database, check_holes: bool) -> Error {
        if self.tail_swap_paused do return API_Error.Cannot_Serialize_While_Packing_Paused

        for table in self.tables.items {
            if table == nil || table.state != Object_State.Normal do continue
            if table.pause_packing do return API_Error.Cannot_Serialize_While_Packing_Paused
            if check_holes && shared_table__snapshot_holes_count(table) > 0 {
                return API_Error.Cannot_Serialize_While_Packing_Paused
            }
        }

        for group in self.groups.items {
            if group == nil || group.state != Object_State.Normal do continue
            if group.pause_packing do return API_Error.Cannot_Serialize_While_Packing_Paused
            if check_holes && group.dirty do return API_Error.Cannot_Serialize_While_Packing_Paused
        }

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Size

    // Exact number of bytes database__serialize will produce for the current
    // state. Allocation-free; call it to size the buffer.
    database__serialized_size :: proc(self: ^Database) -> (size: int, err: Error) {
        if !database__is_valid(self) do return 0, API_Error.Object_Invalid

        size = size_of(Snapshot_Header)
        if self.owns_overbase {
            size += self.overbase.id_factory.cap * size_of(oc.ix_gen)
            size += self.overbase.id_factory.freed_count * size_of(int)
            size = snap__align8(size)
        }

        for table in self.tables.items {
            if table == nil do continue

            size += size_of(Snap_Table_Header)

            n := shared_table__snapshot_len(table)

            ti := shared_table__type_info(table)
            if ti != nil {
                size = snap__align8(size + snapshot__name_len(ti))
                size += n * size_of(entity_id)          // rid_to_eid
                size = snap__align8(size + n * ti.size) // rows
            } else {
                // Tag_Table: rows are the entity ids themselves
                size += n * size_of(entity_id)
            }
        }

        if self.relations != nil && self.relations.state == Object_State.Normal {
            entities_cap := self.overbase.id_factory.cap
            size += size_of(Snap_Relations_Header)
            size += 4 * entities_cap * size_of(entity_id) // parent/first_child/next_sibling/prev_sibling
            size = snap__align8(size + entities_cap * size_of(i32)) // children_count
        }

        return size, nil
    }

///////////////////////////////////////////////////////////////////////////////
// Serialize

    // Writes a snapshot of the whole database into buf (sized via
    // database__serialized_size). Zero allocations. Errors:
    //   Cannot_Serialize_While_Packing_Paused — packing paused or holes present,
    //     call resume_packing/pack first;
    //   Snapshot_Component_Not_POD — a component type contains pointers/slices/
    //     strings/etc (pass allow_non_pod = true to blob-copy it anyway);
    //   Serialize_Buffer_Too_Small.
    database__serialize :: proc(self: ^Database, buf: []byte, allow_non_pod := false) -> (written: int, err: Error) {
        if !database__is_valid(self) do return 0, API_Error.Object_Invalid
        database__snapshot_check_not_paused(self, check_holes = true) or_return

        if !allow_non_pod {
            for table in self.tables.items {
                if table == nil do continue
                ti := shared_table__type_info(table)
                if ti != nil && !snapshot__type_is_pod(ti) do return 0, API_Error.Snapshot_Component_Not_POD
            }
        }

        total := database__serialized_size(self) or_return
        if len(buf) < total do return 0, API_Error.Serialize_Buffer_Too_Small

        section_count: i64 = 0
        for table in self.tables.items {
            if table != nil do section_count += 1
        }

        has_relations := self.relations != nil && self.relations.state == Object_State.Normal
        flags: u32 = 0
        if has_relations do flags |= SNAPSHOT_FLAG__HAS_RELATIONS
        if self.owns_overbase do flags |= SNAPSHOT_FLAG__HAS_ENTITY_ID_SECTION

        w := Snap_Writer{ buf = buf }

        hdr := Snapshot_Header{
            magic         = SNAPSHOT_MAGIC,
            version       = SNAPSHOT_VERSION,
            endian_check  = SNAPSHOT_ENDIAN_CHECK,
            flags         = flags,
            entities_cap  = i64(self.overbase.id_factory.cap),
            created_count = i64(self.overbase.id_factory.created_count),
            freed_count   = i64(self.overbase.id_factory.freed_count),
            section_count = section_count,
        }
        snap_writer__write(&w, &hdr, size_of(hdr))

        // Id factory. The WHOLE items array: generations of freed and
        // never-recreated slots drive expired-id detection and must round-trip.
        // The freed list order matters too (LIFO reuse). Only written when this
        // Database owns its Overbase — a shared Overbase's id-space is saved/
        // restored independently via overbase_serialize/overbase_deserialize,
        // so this Database's own snapshot never carries (and never overwrites)
        // state a sibling Database also depends on.
        if self.owns_overbase {
            snap_writer__write(&w, raw_data(self.overbase.id_factory.items), self.overbase.id_factory.cap * size_of(oc.ix_gen))
            snap_writer__write(&w, raw_data(self.overbase.id_factory.freed), self.overbase.id_factory.freed_count * size_of(int))
            snap_writer__pad8(&w)
        }

        for table in self.tables.items {
            if table == nil do continue
            shared_table__snapshot_write(table, &w)
        }

        if has_relations do relations_table__snapshot_write(self.relations, &w)

        assert(w.offset == total)
        return w.offset, nil
    }

    @(private)
    shared_table__snapshot_write :: proc(table: ^Shared_Table, w: ^Snap_Writer) {
        n := shared_table__snapshot_len(table)
        ti := shared_table__type_info(table)

        th := Snap_Table_Header{
            table_id   = i64(table.id),
            table_type = i32(table.type),
            cap        = i64(shared_table__cap(table)),
            len        = i64(n),
        }
        if ti != nil {
            th.comp_size = i64(ti.size)
            th.comp_align = i64(ti.align)
            th.name_len = i64(snapshot__name_len(ti))
        }
        snap_writer__write(w, &th, size_of(th))

        switch table.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                raw := cast(^Table_Raw) table
                snap_writer__write_name(w, ti)
                snap_writer__pad8(w)
                snap_writer__write(w, raw_data(raw.rid_to_eid), n * size_of(entity_id))
                snap_writer__write(w, raw_data(raw.rows), n * ti.size)
                snap_writer__pad8(w)
            case Table_Type.Compact_Table:
                raw := cast(^Compact_Table_Raw) table
                snap_writer__write_name(w, ti)
                snap_writer__pad8(w)
                snap_writer__write(w, raw_data(raw.rid_to_eid), n * size_of(entity_id))
                snap_writer__write(w, raw_data(raw.rows), n * ti.size)
                snap_writer__pad8(w)
            case Table_Type.Tiny_Table:
                raw := cast(^Tiny_Table_Raw) table
                snap_writer__write_name(w, ti)
                snap_writer__pad8(w)
                snap_writer__write(w, &raw.rid_to_eid[0], n * size_of(entity_id))
                snap_writer__write(w, &raw.rows[0], n * ti.size)
                snap_writer__pad8(w)
            case Table_Type.Tag_Table:
                tt := cast(^Tag_Table) table
                snap_writer__write(w, raw_data(tt.rows), n * size_of(entity_id))
        }
    }

    @(private)
    relations_table__snapshot_write :: proc(self: ^Relations_Table, w: ^Snap_Writer) {
        rh := Snap_Relations_Header{
            cap   = i64(self.cap),
            count = i64(self.count),
        }
        snap_writer__write(w, &rh, size_of(rh))

        entities_cap := len(self.parent)
        snap_writer__write(w, raw_data(self.parent),         entities_cap * size_of(entity_id))
        snap_writer__write(w, raw_data(self.first_child),    entities_cap * size_of(entity_id))
        snap_writer__write(w, raw_data(self.next_sibling),   entities_cap * size_of(entity_id))
        snap_writer__write(w, raw_data(self.prev_sibling),   entities_cap * size_of(entity_id))
        snap_writer__write(w, raw_data(self.children_count), entities_cap * size_of(i32))
        snap_writer__pad8(w)
        // scratch is transient (valid only until the next call) — not saved
    }

///////////////////////////////////////////////////////////////////////////////
// Deserialize

    @(private)
    // Validates one row's saved entity_id against whichever id-space this
    // deserialize call trusts. use_saved selects the snapshot's own recorded
    // state (saved_items) — correct only when this Database owns the
    // entity-id section being restored; otherwise the row is checked against
    // the database's live Overbase, which is either already independently
    // restored (via overbase_deserialize) or simply the ground truth the
    // caller is expected to have set up. See the entity-id ownership note at
    // the top of this file.
    snapshot__validate_row_eid :: proc(self: ^Database, eid: entity_id, saved_items: []entity_id, use_saved: bool) -> Error {
        if use_saved {
            if eid.ix < 0 || eid.ix >= len(saved_items) do return API_Error.Snapshot_Invalid
            if saved_items[eid.ix] != eid do return API_Error.Snapshot_Invalid
        } else {
            if overbase__is_entity_correct(self.overbase, eid) != nil do return API_Error.Snapshot_Invalid
        }
        return nil
    }

    // Loads a snapshot into an already-initialized database with a matching
    // schema (same tables inited in the same order, same component types) and
    // capacities >= the saved ones. All existing entities/components/relations
    // are replaced; views and groups are rebuilt from the loaded data.
    // The whole buffer is validated before anything is mutated (all-or-nothing).
    database__deserialize :: proc(self: ^Database, data: []byte) -> Error {
        if !database__is_valid(self) do return API_Error.Object_Invalid
        database__snapshot_check_not_paused(self, check_holes = false) or_return

        //
        // Pass 1 — validate everything, mutate nothing
        //
        r := Snap_Reader{ data = data }

        hdr: Snapshot_Header
        snap_reader__read(&r, &hdr, size_of(hdr)) or_return

        if hdr.magic != SNAPSHOT_MAGIC do return API_Error.Snapshot_Invalid
        if hdr.endian_check != SNAPSHOT_ENDIAN_CHECK do return API_Error.Snapshot_Invalid
        if hdr.version != SNAPSHOT_VERSION do return API_Error.Snapshot_Version_Mismatch

        // has_entity_ids: the buffer physically carries the items/freed blob
        // (written iff the saving Database owned its Overbase). apply_entity_ids:
        // this Database owns its Overbase too, so it's safe to overwrite it from
        // that blob. When has_entity_ids is true but apply_entity_ids is false
        // (this Database shares its Overbase, or a foreign snapshot is being
        // loaded), the blob is still present in the buffer and must be skipped
        // over, but row entity_ids are validated against the live Overbase
        // instead of the snapshot's own saved_items — see the entity-id
        // ownership note at the top of this file.
        has_entity_ids := (hdr.flags & SNAPSHOT_FLAG__HAS_ENTITY_ID_SECTION) != 0
        apply_entity_ids := has_entity_ids && self.owns_overbase

        saved_cap := int(hdr.entities_cap)
        created_count := int(hdr.created_count)
        freed_count := int(hdr.freed_count)

        if saved_cap <= 0 do return API_Error.Snapshot_Invalid
        if created_count < 0 || created_count > saved_cap do return API_Error.Snapshot_Invalid
        if freed_count < 0 || freed_count > created_count do return API_Error.Snapshot_Invalid
        if hdr.section_count < 0 do return API_Error.Snapshot_Invalid

        saved_items: []entity_id
        if has_entity_ids {
            if apply_entity_ids && saved_cap > self.overbase.id_factory.cap do return API_Error.Snapshot_Capacity_Too_Small

            saved_items = snap_reader__entity_ids(&r, saved_cap) or_return

            freed_bytes := snap_reader__bytes(&r, freed_count * size_of(int)) or_return
            saved_freed := slice.reinterpret([]int, freed_bytes)
            for f in saved_freed {
                if f < 0 || f >= saved_cap do return API_Error.Snapshot_Invalid
                if saved_items[f].ix != DELETED_INDEX do return API_Error.Snapshot_Invalid
            }
            snap_reader__pad8(&r) or_return
        }

        nonnil_tables := 0
        for table in self.tables.items {
            if table != nil do nonnil_tables += 1
        }
        if int(hdr.section_count) != nonnil_tables do return API_Error.Snapshot_Schema_Mismatch

        has_relations := (hdr.flags & SNAPSHOT_FLAG__HAS_RELATIONS) != 0
        db_has_relations := self.relations != nil && self.relations.state == Object_State.Normal
        if has_relations != db_has_relations do return API_Error.Snapshot_Schema_Mismatch

        prev_id := -1
        for _ in 0..<int(hdr.section_count) {
            th: Snap_Table_Header
            snap_reader__read(&r, &th, size_of(th)) or_return

            tid := int(th.table_id)
            if tid <= prev_id do return API_Error.Snapshot_Invalid // ids are written strictly ascending
            prev_id = tid

            if tid < 0 || tid >= len(self.tables.items) do return API_Error.Snapshot_Schema_Mismatch
            table := self.tables.items[tid]
            if table == nil || table.state != Object_State.Normal do return API_Error.Snapshot_Schema_Mismatch
            if int(th.table_type) != int(table.type) do return API_Error.Snapshot_Schema_Mismatch

            n := int(th.len)
            if n < 0 do return API_Error.Snapshot_Invalid
            if n > shared_table__cap(table) do return API_Error.Snapshot_Capacity_Too_Small

            name_len := int(th.name_len)
            if name_len < 0 do return API_Error.Snapshot_Invalid

            ti := shared_table__type_info(table)
            if ti != nil {
                if int(th.comp_size) != ti.size || int(th.comp_align) != ti.align {
                    return API_Error.Snapshot_Schema_Mismatch
                }
                name_bytes := snap_reader__bytes(&r, name_len) or_return
                if !snapshot__name_matches(ti, name_bytes) do return API_Error.Snapshot_Schema_Mismatch
                snap_reader__pad8(&r) or_return

                eids := snap_reader__entity_ids(&r, n) or_return
                for eid in eids {
                    // every row's entity must be alive in the id-space this
                    // load trusts (the snapshot's own, or the live Overbase)
                    snapshot__validate_row_eid(self, eid, saved_items, apply_entity_ids) or_return
                }
                _ = snap_reader__bytes(&r, n * ti.size) or_return // rows blob
                snap_reader__pad8(&r) or_return
            } else {
                // Tag_Table
                if th.comp_size != 0 || th.comp_align != 0 || name_len != 0 {
                    return API_Error.Snapshot_Schema_Mismatch
                }
                eids := snap_reader__entity_ids(&r, n) or_return
                for eid in eids {
                    snapshot__validate_row_eid(self, eid, saved_items, apply_entity_ids) or_return
                }
            }
        }

        if has_relations {
            rh: Snap_Relations_Header
            snap_reader__read(&r, &rh, size_of(rh)) or_return
            if rh.count < 0 || int(rh.count) > self.relations.cap do return API_Error.Snapshot_Capacity_Too_Small

            for _ in 0..<4 { // parent, first_child, next_sibling, prev_sibling
                links := snap_reader__entity_ids(&r, saved_cap) or_return
                for e in links {
                    if is_not_set(e) do continue
                    snapshot__validate_row_eid(self, e, saved_items, apply_entity_ids) or_return
                }
            }
            _ = snap_reader__bytes(&r, saved_cap * size_of(i32)) or_return // children_count
            snap_reader__pad8(&r) or_return
        }

        if r.offset != len(data) do return API_Error.Snapshot_Invalid

        //
        // Pass 2 — apply (validated above, so nothing below is expected to fail)
        //

        // Reset to a clean post-init state. No gen bump: the factory items are
        // fully overwritten from the snapshot right after. Only when this
        // Database owns its Overbase — otherwise the shared id-space is left
        // completely untouched by this call (a sibling Database, or nothing
        // at all, may depend on it; see overbase_deserialize to restore it
        // explicitly).
        if apply_entity_ids {
            oc.ix_gen_factory__clear(&self.overbase.id_factory, bump_gen = false)
        }
        slice.zero(self.eid_to_bits)

        for table in self.tables.items {
            if table == nil do continue
            shared_table__clear(table) or_return
        }
        if db_has_relations do relations_table__clear(self.relations) or_return
        for view in self.views.items {
            if view == nil || view.state != Object_State.Normal do continue
            view__clear(view) or_return
        }

        r = Snap_Reader{ data = data }
        snap_reader__read(&r, &hdr, size_of(hdr)) or_return

        if apply_entity_ids {
            // Id factory. Slots >= saved_cap stay cleared (ix == DELETED_INDEX),
            // so both new_id paths remain correct on a larger target database.
            snap_reader__read(&r, raw_data(self.overbase.id_factory.items), saved_cap * size_of(oc.ix_gen)) or_return
            snap_reader__read(&r, raw_data(self.overbase.id_factory.freed), freed_count * size_of(int)) or_return
            snap_reader__pad8(&r) or_return
            self.overbase.id_factory.created_count = created_count
            self.overbase.id_factory.freed_count = freed_count
        } else if has_entity_ids {
            // Section is present in the buffer but doesn't belong to this
            // Database (shared Overbase, or a foreign snapshot) — skip past
            // it without touching the live id-space.
            _ = snap_reader__bytes(&r, saved_cap * size_of(oc.ix_gen)) or_return
            _ = snap_reader__bytes(&r, freed_count * size_of(int)) or_return
            snap_reader__pad8(&r) or_return
        }

        for _ in 0..<int(hdr.section_count) {
            th: Snap_Table_Header
            snap_reader__read(&r, &th, size_of(th)) or_return
            shared_table__snapshot_apply(self.tables.items[int(th.table_id)], &th, &r) or_return
        }

        if has_relations {
            rh: Snap_Relations_Header
            snap_reader__read(&r, &rh, size_of(rh)) or_return

            rt := self.relations
            snap_reader__read(&r, raw_data(rt.parent),         saved_cap * size_of(entity_id)) or_return
            snap_reader__read(&r, raw_data(rt.first_child),    saved_cap * size_of(entity_id)) or_return
            snap_reader__read(&r, raw_data(rt.next_sibling),   saved_cap * size_of(entity_id)) or_return
            snap_reader__read(&r, raw_data(rt.prev_sibling),   saved_cap * size_of(entity_id)) or_return
            snap_reader__read(&r, raw_data(rt.children_count), saved_cap * size_of(i32)) or_return
            snap_reader__pad8(&r) or_return
            rt.count = int(rh.count)
        }

        assert(r.offset == len(data))

        // Groups first (their swaps settle the final row order), then views.
        // Notifications fired at the cleared views during group rebuild are
        // harmless no-ops.
        for group in self.groups.items {
            if group == nil || group.state != Object_State.Normal do continue
            group__rebuild(group) or_return
        }
        for view in self.views.items {
            if view == nil || view.state != Object_State.Normal do continue
            view__rebuild(view) or_return
        }

        return nil
    }

    @(private)
    shared_table__snapshot_apply :: proc(table: ^Shared_Table, th: ^Snap_Table_Header, r: ^Snap_Reader) -> Error {
        n := int(th.len)
        db := table.db

        switch table.type {
            case Table_Type.Unknown:
                assert(false) // should not happen
            case Table_Type.Table:
                raw := cast(^Table_Raw) table
                _ = snap_reader__bytes(r, int(th.name_len)) or_return
                snap_reader__pad8(r) or_return

                eids := snap_reader__entity_ids(r, n) or_return
                snap_reader__read(r, raw_data(raw.rows), n * raw.type_info.size) or_return
                snap_reader__pad8(r) or_return
                (^runtime.Raw_Slice)(&raw.rows).len = n

                #no_bounds_check for rid in 0..<n {
                    eid := eids[rid]
                    raw.rid_to_eid[rid] = eid
                    raw.eid_to_rid[eid.ix] = u32(rid)
                    uni_bits__add(&db.eid_to_bits[eid.ix], raw.id)
                }
            case Table_Type.Compact_Table:
                raw := cast(^Compact_Table_Raw) table
                _ = snap_reader__bytes(r, int(th.name_len)) or_return
                snap_reader__pad8(r) or_return

                eids := snap_reader__entity_ids(r, n) or_return
                snap_reader__read(r, raw_data(raw.rows), n * raw.type_info.size) or_return
                snap_reader__pad8(r) or_return
                (^runtime.Raw_Slice)(&raw.rows).len = n

                #no_bounds_check for rid in 0..<n {
                    eid := eids[rid]
                    raw.rid_to_eid[rid] = eid
                    // cannot fail: the map was cleared and its capacity covers table cap
                    oc_maps.rh_map32__add(&raw.eid_to_rid, u32(eid.ix), u32(rid)) or_return
                    uni_bits__add(&db.eid_to_bits[eid.ix], raw.id)
                }
            case Table_Type.Tiny_Table:
                raw := cast(^Tiny_Table_Raw) table
                _ = snap_reader__bytes(r, int(th.name_len)) or_return
                snap_reader__pad8(r) or_return

                T_size := raw.type_info.size
                eids := snap_reader__entity_ids(r, n) or_return
                snap_reader__read(r, &raw.rows[0], n * T_size) or_return
                snap_reader__pad8(r) or_return
                raw.len = n

                for rid in 0..<n {
                    eid := eids[rid]
                    raw.rid_to_eid[rid] = eid
                    // recompute the component pointer — never load pointers from a snapshot
                    ptr := rawptr(uintptr(&raw.rows[0]) + uintptr(rid * T_size))
                    oc_maps.tt_map__add(&raw.eid_to_ptr, eid.ix, ptr) or_return
                    uni_bits__add(&db.eid_to_bits[eid.ix], raw.id)
                }
            case Table_Type.Tag_Table:
                tt := cast(^Tag_Table) table
                snap_reader__read(r, raw_data(tt.rows), n * size_of(entity_id)) or_return
                (^runtime.Raw_Slice)(&tt.rows).len = n

                #no_bounds_check for rid in 0..<n {
                    eid := tt.rows[rid]
                    oc_maps.rh_map32__add(&tt.eid_to_rid, u32(eid.ix), u32(rid)) or_return
                    uni_bits__add(&db.eid_to_bits[eid.ix], tt.id)
                }
        }

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// File convenience

    // Serialize into a temporary buffer (the only allocation) and write it to
    // `path`, overwriting the file if it exists.
    database__save_to_file :: proc(self: ^Database, path: string, allocator := context.allocator, allow_non_pod := false) -> Error {
        size := database__serialized_size(self) or_return

        buf := make([]byte, size, allocator) or_return
        defer delete(buf, allocator)

        written := database__serialize(self, buf, allow_non_pod) or_return

        if os.write_entire_file(path, buf[:written]) != nil do return API_Error.File_Error

        return nil
    }

    database__load_from_file :: proc(self: ^Database, path: string, allocator := context.allocator) -> Error {
        data, rerr := os.read_entire_file(path, allocator)
        if rerr != nil do return API_Error.File_Error
        defer delete(data, allocator)

        return database__deserialize(self, data)
    }

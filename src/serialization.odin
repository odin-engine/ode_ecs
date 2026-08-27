/*
    2026 (c) Oleh, https://github.com/zm69

    Binary snapshot serialization of a whole Database: entities (with their
    generations, so saved entity_ids stay valid after load), components, tags
    and relations round-trip; views and groups are derived data and are rebuilt
    on load instead of being stored.

    Components must be POD — no pointers, slices, strings, maps or
    dynamic arrays inside them (their rows are copied as raw bytes). serialize
    rejects non-POD component types unless allow_non_pod = true is passed.

    Loading requires an already-initialized Database with a matching schema:
    the same tables initialized in the same order (and with the same
    init/terminate history, so table ids coincide), same component types, and
    capacities no smaller than the saved data. Deserialization is all-or-nothing:
    the whole buffer is validated before anything is mutated.
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
    SNAPSHOT_MAGIC :: u64(0x4244_5343_4545_444F)

    @(private)
    SNAPSHOT_VERSION :: u32(8)

    @(private)
    SNAPSHOT_ENDIAN_CHECK :: u32(0x0A0B0C0D)

    @(private)
    SNAPSHOT_FLAG__HAS_RELATIONS :: u32(1 << 0)

    @(private)
    SNAPSHOT_FLAG__HAS_ENTITY_ID_SECTION :: u32(1 << 1)

    @(private)
    Snapshot_Header :: struct #packed {
        magic:         u64,
        version:       u32,
        endian_check:  u32,
        flags:         u32,
        _reserved:     u32,
        entities_cap:  i64,
        created_count: i64,
        freed_count:   i64,
        section_count: i64,
        pair_table_section_count: i64,
    }

    @(private)
    Snap_Table_Header :: struct #packed {
        table_id:   i64,
        table_type: i32,
        _pad:       i32,
        comp_size:  i64,
        comp_align: i64,
        cap:        i64,
        len:        i64,
        name_len:   i64,
        column_count: i64,
    }

    @(private)
    Snap_Arch_Column_Header :: struct #packed {
        comp_size:  i64,
        comp_align: i64,
        name_len:   i64,
    }

    @(private)
    Snap_Relations_Header :: struct #packed {
        cap:   i64,
        count: i64,
    }

    @(private)
    Snap_Pair_Table_Header :: struct #packed {
        pair_table_id:     i64,
        presence_table_id: i64,
        data_elem_size:    i64,
        data_elem_align:   i64,
        pairs_cap:         i64,
        count:             i64,
    }

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

        return false
    }

    @(private)
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
            case Table_Type.Auto:
                return 0
            case Table_Type.Table:
                return (cast(^Table_Base) table).holes_count
            case Table_Type.Compact_Table:
                return (cast(^Compact_Table_Base) table).holes_count
            case Table_Type.Tiny_Table:
                return (cast(^Tiny_Table_Base) table).holes_count
            case Table_Type.Tag_Table:
                return (cast(^Tag_Table) table).holes_count
            case Table_Type.Arch_Table:
                return (cast(^Arch_Table) table).holes_count
        }
        return 0
    }

    @(private)
    shared_table__snapshot_len :: proc(table: ^Shared_Table) -> int {
        if table.type == Table_Type.Tag_Table {
            return (^runtime.Raw_Slice)(&(cast(^Tag_Table) table).rows).len
        }
        return shared_table__len(table)
    }

    @(private)
    database__snapshot_check_not_paused :: proc(self: ^Database, check_holes: bool) -> Error {
        if self.tail_swap_paused do return API_Error.Cannot_Serialize_While_Packing_Paused

        for table in self.tables.items {
            if table == nil || table.state != Object_State.Normal do continue
            if table.pause_packing do return API_Error.Cannot_Serialize_While_Packing_Paused
            if check_holes && shared_table__snapshot_holes_count(table) > 0 {
                return API_Error.Cannot_Serialize_While_Packing_Paused
            }
        }

        for tag in self.tag_tables.items {
            if tag == nil || tag.state != Object_State.Normal do continue
            if tag.pause_packing do return API_Error.Cannot_Serialize_While_Packing_Paused
            if check_holes && shared_table__snapshot_holes_count(cast(^Shared_Table) tag) > 0 {
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

    database__serialized_size :: proc(self: ^Database) -> (size: int, err: Error) {
        if !database__is_valid(self) do return 0, API_Error.Object_Invalid

        size = size_of(Snapshot_Header)
        if self.owns_overbase {
            size += self.overbase.id_factory.cap * size_of(oc.ix_gen)
            size += self.overbase.id_factory.freed_count * size_of(int)
            size = snap__align8(size)
        }

        size += self.overbase.id_factory.cap * size_of(Uni_Bits)
        size = snap__align8(size)

        size += self.overbase.id_factory.cap * size_of(Uni_Bits)
        size = snap__align8(size)

        for table in self.tables.items {
            if table == nil do continue

            size += size_of(Snap_Table_Header)

            n := shared_table__snapshot_len(table)

            if table.type == Table_Type.Arch_Table {
                at := cast(^Arch_Table) table
                for col in at.columns {
                    size += size_of(Snap_Arch_Column_Header)
                    size = snap__align8(size + snapshot__name_len(col.type_info))
                }
                size += n * size_of(entity_id)
                size = snap__align8(size)
                for col in at.columns {
                    size = snap__align8(size + n * col.type_info.size)
                }
            } else {
                ti := shared_table__type_info(table)
                if ti != nil {
                    size = snap__align8(size + snapshot__name_len(ti))
                    size += n * size_of(entity_id)
                    size = snap__align8(size + n * ti.size)
                } else {
                    size += n * size_of(entity_id)
                }
            }
        }

        for tag in self.tag_tables.items {
            if tag == nil do continue

            size += size_of(Snap_Table_Header)
            n := shared_table__snapshot_len(cast(^Shared_Table) tag)
            size += n * size_of(entity_id)
        }

        if self.relations != nil && self.relations.state == Object_State.Normal {
            entities_cap := self.overbase.id_factory.cap
            size += size_of(Snap_Relations_Header)
            size += 4 * entities_cap * size_of(entity_id)
            size = snap__align8(size + entities_cap * size_of(i32))
        }

        for pt in self.pair_tables.items {
            if pt == nil do continue

            size += size_of(Snap_Pair_Table_Header)
            size = snap__align8(size + pt.pairs_count * 2 * size_of(entity_id))
            size = snap__align8(size + pt.pairs_count * pt.data_type_info.size)
        }

        return size, nil
    }

///////////////////////////////////////////////////////////////////////////////
// Serialize

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
        for tag in self.tag_tables.items {
            if tag != nil do section_count += 1
        }

        pair_table_section_count: i64 = 0
        for pt in self.pair_tables.items {
            if pt != nil do pair_table_section_count += 1
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
            pair_table_section_count = pair_table_section_count,
        }
        snap_writer__write(&w, &hdr, size_of(hdr))

        if self.owns_overbase {
            snap_writer__write(&w, raw_data(self.overbase.id_factory.items), self.overbase.id_factory.cap * size_of(oc.ix_gen))
            snap_writer__write(&w, raw_data(self.overbase.id_factory.freed), self.overbase.id_factory.freed_count * size_of(int))
            snap_writer__pad8(&w)
        }

        snap_writer__write(&w, raw_data(self.eid_to_disabled_bits), self.overbase.id_factory.cap * size_of(Uni_Bits))
        snap_writer__pad8(&w)

        snap_writer__write(&w, raw_data(self.eid_to_tag_disabled_bits), self.overbase.id_factory.cap * size_of(Uni_Bits))
        snap_writer__pad8(&w)

        for table in self.tables.items {
            if table == nil do continue
            shared_table__snapshot_write(table, &w)
        }

        for tag in self.tag_tables.items {
            if tag == nil do continue
            shared_table__snapshot_write(cast(^Shared_Table) tag, &w)
        }

        if has_relations do relations_table__snapshot_write(self.relations, &w)

        for pt in self.pair_tables.items {
            if pt != nil do pair_table_base__snapshot_write(pt, &w)
        }

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
        if table.type == Table_Type.Arch_Table {
            th.column_count = i64(len((cast(^Arch_Table) table).columns))
        }
        snap_writer__write(w, &th, size_of(th))

        switch table.type {
            case Table_Type.Auto:
                assert(false)
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
            case Table_Type.Arch_Table:
                at := cast(^Arch_Table) table

                for col in at.columns {
                    cih := Snap_Arch_Column_Header{
                        comp_size  = i64(col.type_info.size),
                        comp_align = i64(col.type_info.align),
                        name_len   = i64(snapshot__name_len(col.type_info)),
                    }
                    snap_writer__write(w, &cih, size_of(cih))
                    snap_writer__write_name(w, col.type_info)
                    snap_writer__pad8(w)
                }

                snap_writer__write(w, raw_data(at.rid_to_eid), n * size_of(entity_id))
                snap_writer__pad8(w)

                for col in at.columns {
                    snap_writer__write(w, raw_data(col.rows), n * col.type_info.size)
                    snap_writer__pad8(w)
                }
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
    }

    @(private)
    pair_table_base__snapshot_write :: proc(self: ^Pair_Table_Base, w: ^Snap_Writer) {
        raw := cast(^Pair_Table_Raw) self
        elem_size := self.data_type_info.size

        pth := Snap_Pair_Table_Header{
            pair_table_id     = i64(self.id),
            presence_table_id = i64(self.presence.id),
            data_elem_size    = i64(elem_size),
            data_elem_align   = i64(self.data_type_info.align),
            pairs_cap         = i64(self.pairs_cap),
            count             = i64(self.pairs_count),
        }
        snap_writer__write(w, &pth, size_of(pth))

        for r := 0; r < self.pairs_cap; r += 1 {
            if self.row_holder[r].ix == DELETED_INDEX do continue
            h := self.row_holder[r]
            snap_writer__write(w, &h, size_of(entity_id))
        }
        for r := 0; r < self.pairs_cap; r += 1 {
            if self.row_holder[r].ix == DELETED_INDEX do continue
            tgt := self.targets[r]
            snap_writer__write(w, &tgt, size_of(entity_id))
        }
        snap_writer__pad8(w)

        if elem_size > 0 {
            base := uintptr(raw_data(raw.data))
            for r := 0; r < self.pairs_cap; r += 1 {
                if self.row_holder[r].ix == DELETED_INDEX do continue
                src := rawptr(base + uintptr(r * elem_size))
                snap_writer__write(w, src, elem_size)
            }
        }
        snap_writer__pad8(w)
    }

///////////////////////////////////////////////////////////////////////////////
// Deserialize

    @(private)
    snapshot__validate_row_eid :: proc(self: ^Database, eid: entity_id, saved_items: []entity_id, use_saved: bool) -> Error {
        if use_saved {
            if eid.ix < 0 || eid.ix >= len(saved_items) do return API_Error.Snapshot_Invalid
            if saved_items[eid.ix] != eid do return API_Error.Snapshot_Invalid
        } else {
            if overbase__is_entity_correct(self.overbase, eid) != nil do return API_Error.Snapshot_Invalid
        }
        return nil
    }

    @(private)
    snapshot__validate_relations :: proc(
        self: ^Database,
        parent, first_child, next_sibling, prev_sibling: []entity_id,
        cc: []i32,
        saved_count: int,
        saved_items: []entity_id,
        use_saved: bool,
        stamps: []i32,
        stamp_base: i32,
    ) -> Error {
        saved_cap := len(parent)
        cap := self.relations.cap

        links_count := 0
        cc_total := 0
        for ix in 0..<saved_cap {
            p  := parent[ix]
            fc := first_child[ix]
            ns := next_sibling[ix]
            ps := prev_sibling[ix]
            n_cc := cc[ix]

            if n_cc < 0 || int(n_cc) > cap do return API_Error.Snapshot_Invalid

            if is_not_set(p) && is_not_set(fc) && is_not_set(ns) && is_not_set(ps) {
                if n_cc != 0 do return API_Error.Snapshot_Invalid
                continue
            }

            if use_saved {
                if saved_items[ix].ix != ix do return API_Error.Snapshot_Invalid
            } else {
                if self.overbase.id_factory.items[ix].ix != ix do return API_Error.Snapshot_Invalid
            }

            for e in ([4]entity_id{ p, fc, ns, ps }) {
                if is_not_set(e) do continue
                snapshot__validate_row_eid(self, e, saved_items, use_saved) or_return
                if e.ix >= saved_cap do return API_Error.Snapshot_Invalid
            }

            if !is_not_set(ns) {
                if is_not_set(p) do return API_Error.Snapshot_Invalid
                if is_not_set(parent[ns.ix]) || parent[ns.ix].ix != p.ix do return API_Error.Snapshot_Invalid
                if is_not_set(prev_sibling[ns.ix]) || prev_sibling[ns.ix].ix != ix do return API_Error.Snapshot_Invalid
            }
            if !is_not_set(ps) {
                if is_not_set(p) do return API_Error.Snapshot_Invalid
                if is_not_set(next_sibling[ps.ix]) || next_sibling[ps.ix].ix != ix do return API_Error.Snapshot_Invalid
                if is_not_set(parent[ps.ix]) || parent[ps.ix].ix != p.ix do return API_Error.Snapshot_Invalid
            } else if !is_not_set(p) {
                if is_not_set(first_child[p.ix]) || first_child[p.ix].ix != ix do return API_Error.Snapshot_Invalid
            }
            if !is_not_set(fc) {
                if is_not_set(parent[fc.ix]) || parent[fc.ix].ix != ix do return API_Error.Snapshot_Invalid
                if !is_not_set(prev_sibling[fc.ix]) do return API_Error.Snapshot_Invalid
            } else if n_cc != 0 {
                return API_Error.Snapshot_Invalid
            }

            if !is_not_set(p) do links_count += 1
            cc_total += int(n_cc)
        }

        if links_count != saved_count do return API_Error.Snapshot_Invalid
        if cc_total != saved_count do return API_Error.Snapshot_Invalid

        walked_total := 0
        for ix in 0..<saved_cap {
            c := first_child[ix]
            if is_not_set(c) do continue
            n := 0
            for !is_not_set(c) {
                n += 1
                if n > cap do return API_Error.Snapshot_Invalid
                c = next_sibling[c.ix]
            }
            if n != int(cc[ix]) do return API_Error.Snapshot_Invalid
            walked_total += n
        }
        if walked_total != saved_count do return API_Error.Snapshot_Invalid

        for ix in 0..<saved_cap {
            if is_not_set(parent[ix]) do continue
            epoch := stamp_base + 1 + i32(ix)
            j := ix
            for {
                if stamps[j] == epoch do return API_Error.Snapshot_Invalid
                if stamps[j] > stamp_base do break
                stamps[j] = epoch
                p := parent[j]
                if is_not_set(p) do break
                j = p.ix
            }
        }

        return nil
    }

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

        if saved_cap > self.overbase.id_factory.cap do return API_Error.Snapshot_Capacity_Too_Small
        _ = snap_reader__bytes(&r, saved_cap * size_of(Uni_Bits)) or_return
        snap_reader__pad8(&r) or_return

        _ = snap_reader__bytes(&r, saved_cap * size_of(Uni_Bits)) or_return
        snap_reader__pad8(&r) or_return

        nonnil_tables := 0
        for table in self.tables.items {
            if table != nil do nonnil_tables += 1
        }
        for tag in self.tag_tables.items {
            if tag != nil do nonnil_tables += 1
        }
        if int(hdr.section_count) != nonnil_tables do return API_Error.Snapshot_Schema_Mismatch

        nonnil_pair_tables := 0
        for pt in self.pair_tables.items {
            if pt != nil do nonnil_pair_tables += 1
        }
        if int(hdr.pair_table_section_count) < 0 do return API_Error.Snapshot_Invalid
        if int(hdr.pair_table_section_count) != nonnil_pair_tables do return API_Error.Snapshot_Schema_Mismatch

        has_relations := (hdr.flags & SNAPSHOT_FLAG__HAS_RELATIONS) != 0
        db_has_relations := self.relations != nil && self.relations.state == Object_State.Normal
        if has_relations != db_has_relations do return API_Error.Snapshot_Schema_Mismatch

        stamps: []i32
        if int(hdr.section_count) > 0 || has_relations {
            stamps = make([]i32, self.overbase.id_factory.cap, self.allocator) or_return
        }
        defer if stamps != nil do delete(stamps, self.allocator)

        prev_id := -1
        prev_tag_id := -1
        for section_ix in 0..<int(hdr.section_count) {
            th: Snap_Table_Header
            snap_reader__read(&r, &th, size_of(th)) or_return

            tid := int(th.table_id)
            is_tag_section := int(th.table_type) == int(Table_Type.Tag_Table)

            table: ^Shared_Table
            if is_tag_section {
                if tid <= prev_tag_id do return API_Error.Snapshot_Invalid
                prev_tag_id = tid
                if tid < 0 || tid >= len(self.tag_tables.items) do return API_Error.Snapshot_Schema_Mismatch
                table = cast(^Shared_Table) self.tag_tables.items[tid]
            } else {
                if tid <= prev_id do return API_Error.Snapshot_Invalid
                prev_id = tid
                if tid < 0 || tid >= len(self.tables.items) do return API_Error.Snapshot_Schema_Mismatch
                table = self.tables.items[tid]
            }
            if table == nil || table.state != Object_State.Normal do return API_Error.Snapshot_Schema_Mismatch
            if int(th.table_type) != int(table.type) do return API_Error.Snapshot_Schema_Mismatch

            n := int(th.len)
            if n < 0 do return API_Error.Snapshot_Invalid
            if n > shared_table__cap(table) do return API_Error.Snapshot_Capacity_Too_Small

            name_len := int(th.name_len)
            if name_len < 0 do return API_Error.Snapshot_Invalid

            if table.type == Table_Type.Arch_Table {
                at := cast(^Arch_Table) table

                if th.comp_size != 0 || th.comp_align != 0 || name_len != 0 {
                    return API_Error.Snapshot_Schema_Mismatch
                }
                if int(th.column_count) != len(at.columns) do return API_Error.Snapshot_Schema_Mismatch

                for col in at.columns {
                    cih: Snap_Arch_Column_Header
                    snap_reader__read(&r, &cih, size_of(cih)) or_return
                    if int(cih.comp_size) != col.type_info.size || int(cih.comp_align) != col.type_info.align {
                        return API_Error.Snapshot_Schema_Mismatch
                    }
                    cname_len := int(cih.name_len)
                    if cname_len < 0 do return API_Error.Snapshot_Invalid
                    cname_bytes := snap_reader__bytes(&r, cname_len) or_return
                    if !snapshot__name_matches(col.type_info, cname_bytes) do return API_Error.Snapshot_Schema_Mismatch
                    snap_reader__pad8(&r) or_return
                }

                eids := snap_reader__entity_ids(&r, n) or_return
                for eid in eids {
                    snapshot__validate_row_eid(self, eid, saved_items, apply_entity_ids) or_return
                    if stamps[eid.ix] == i32(section_ix + 1) do return API_Error.Snapshot_Invalid
                    stamps[eid.ix] = i32(section_ix + 1)
                }
                snap_reader__pad8(&r) or_return

                for col in at.columns {
                    _ = snap_reader__bytes(&r, n * col.type_info.size) or_return
                    snap_reader__pad8(&r) or_return
                }
            } else {
                if th.column_count != 0 do return API_Error.Snapshot_Schema_Mismatch

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
                        snapshot__validate_row_eid(self, eid, saved_items, apply_entity_ids) or_return
                        if stamps[eid.ix] == i32(section_ix + 1) do return API_Error.Snapshot_Invalid
                        stamps[eid.ix] = i32(section_ix + 1)
                    }
                    _ = snap_reader__bytes(&r, n * ti.size) or_return
                    snap_reader__pad8(&r) or_return
                } else {
                    if th.comp_size != 0 || th.comp_align != 0 || name_len != 0 {
                        return API_Error.Snapshot_Schema_Mismatch
                    }
                    eids := snap_reader__entity_ids(&r, n) or_return
                    for eid in eids {
                        snapshot__validate_row_eid(self, eid, saved_items, apply_entity_ids) or_return
                        if stamps[eid.ix] == i32(section_ix + 1) do return API_Error.Snapshot_Invalid
                        stamps[eid.ix] = i32(section_ix + 1)
                    }
                }
            }
        }

        if has_relations {
            rh: Snap_Relations_Header
            snap_reader__read(&r, &rh, size_of(rh)) or_return
            if rh.count < 0 || int(rh.count) > self.relations.cap do return API_Error.Snapshot_Capacity_Too_Small
            if saved_cap > len(self.relations.parent) do return API_Error.Snapshot_Capacity_Too_Small

            s_parent       := snap_reader__entity_ids(&r, saved_cap) or_return
            s_first_child  := snap_reader__entity_ids(&r, saved_cap) or_return
            s_next_sibling := snap_reader__entity_ids(&r, saved_cap) or_return
            s_prev_sibling := snap_reader__entity_ids(&r, saved_cap) or_return
            cc_bytes       := snap_reader__bytes(&r, saved_cap * size_of(i32)) or_return
            s_cc           := slice.reinterpret([]i32, cc_bytes)
            snap_reader__pad8(&r) or_return

            snapshot__validate_relations(
                self, s_parent, s_first_child, s_next_sibling, s_prev_sibling, s_cc,
                int(rh.count), saved_items, apply_entity_ids,
                stamps, i32(hdr.section_count),
            ) or_return
        }

        prev_pair_id := -1
        for _ in 0..<int(hdr.pair_table_section_count) {
            pth: Snap_Pair_Table_Header
            snap_reader__read(&r, &pth, size_of(pth)) or_return

            ptid := int(pth.pair_table_id)
            if ptid <= prev_pair_id do return API_Error.Snapshot_Invalid
            prev_pair_id = ptid

            if ptid < 0 || ptid >= len(self.pair_tables.items) do return API_Error.Snapshot_Schema_Mismatch
            pt := self.pair_tables.items[ptid]
            if pt == nil || pt.state != Object_State.Normal do return API_Error.Snapshot_Schema_Mismatch
            if int(pth.data_elem_size) != pt.data_type_info.size do return API_Error.Snapshot_Schema_Mismatch
            if int(pth.data_elem_align) != pt.data_type_info.align do return API_Error.Snapshot_Schema_Mismatch
            if int(pth.presence_table_id) != int(pt.presence.id) do return API_Error.Snapshot_Schema_Mismatch

            count := int(pth.count)
            if count < 0 do return API_Error.Snapshot_Invalid
            if count > pt.pairs_cap do return API_Error.Snapshot_Capacity_Too_Small

            holders := snap_reader__entity_ids(&r, count) or_return
            targets := snap_reader__entity_ids(&r, count) or_return
            snap_reader__pad8(&r) or_return

            for h in holders do snapshot__validate_row_eid(self, h, saved_items, apply_entity_ids) or_return
            for tg in targets do snapshot__validate_row_eid(self, tg, saved_items, apply_entity_ids) or_return

            elem_size := int(pth.data_elem_size)
            if elem_size > 0 {
                _ = snap_reader__bytes(&r, count * elem_size) or_return
            }
            snap_reader__pad8(&r) or_return
        }

        if r.offset != len(data) do return API_Error.Snapshot_Invalid

        //
        // Pass 2 — apply
        //
        if apply_entity_ids {
            oc.ix_gen_factory__clear(&self.overbase.id_factory, bump_gen = false)
        }
        slice.zero(self.eid_to_bits)
        slice.zero(self.eid_to_disabled_bits)
        slice.zero(self.eid_to_tag_bits)
        slice.zero(self.eid_to_tag_disabled_bits)

        for table in self.tables.items {
            if table == nil do continue
            shared_table__clear(table) or_return
        }
        for tag in self.tag_tables.items {
            if tag == nil do continue
            tag_table__clear(tag) or_return
        }
        if db_has_relations do relations_table__clear(self.relations) or_return
        for pt in self.pair_tables.items {
            if pt == nil do continue
            pair_table_base__reset_rows(pt)
        }
        for view in self.views.items {
            if view == nil || view.state != Object_State.Normal do continue
            view__clear(view) or_return
        }

        r = Snap_Reader{ data = data }
        snap_reader__read(&r, &hdr, size_of(hdr)) or_return

        if apply_entity_ids {
            snap_reader__read(&r, raw_data(self.overbase.id_factory.items), saved_cap * size_of(oc.ix_gen)) or_return
            snap_reader__read(&r, raw_data(self.overbase.id_factory.freed), freed_count * size_of(int)) or_return
            snap_reader__pad8(&r) or_return
            self.overbase.id_factory.created_count = created_count
            self.overbase.id_factory.freed_count = freed_count
        } else if has_entity_ids {
            _ = snap_reader__bytes(&r, saved_cap * size_of(oc.ix_gen)) or_return
            _ = snap_reader__bytes(&r, freed_count * size_of(int)) or_return
            snap_reader__pad8(&r) or_return
        }

        snap_reader__read(&r, raw_data(self.eid_to_disabled_bits), saved_cap * size_of(Uni_Bits)) or_return
        snap_reader__pad8(&r) or_return

        snap_reader__read(&r, raw_data(self.eid_to_tag_disabled_bits), saved_cap * size_of(Uni_Bits)) or_return
        snap_reader__pad8(&r) or_return

        self.has_disabled_components = true

        for _ in 0..<int(hdr.section_count) {
            th: Snap_Table_Header
            snap_reader__read(&r, &th, size_of(th)) or_return
            table: ^Shared_Table
            if int(th.table_type) == int(Table_Type.Tag_Table) {
                table = cast(^Shared_Table) self.tag_tables.items[int(th.table_id)]
            } else {
                table = self.tables.items[int(th.table_id)]
            }
            shared_table__snapshot_apply(table, &th, &r) or_return
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

        for _ in 0..<int(hdr.pair_table_section_count) {
            pth: Snap_Pair_Table_Header
            snap_reader__read(&r, &pth, size_of(pth)) or_return
            pt := self.pair_tables.items[int(pth.pair_table_id)]

            count := int(pth.count)
            holders := snap_reader__entity_ids(&r, count) or_return
            targets := snap_reader__entity_ids(&r, count) or_return
            snap_reader__pad8(&r) or_return

            elem_size := int(pth.data_elem_size)
            data_bytes: []byte
            if elem_size > 0 {
                data_bytes = snap_reader__bytes(&r, count * elem_size) or_return
            }
            snap_reader__pad8(&r) or_return

            for i in 0..<count {
                data_ptr: rawptr = nil
                if elem_size > 0 do data_ptr = &data_bytes[i * elem_size]
                _, paerr := pair_table_base__add_raw(pt, holders[i], targets[i], data_ptr)
                if paerr != nil do return paerr
            }
        }

        assert(r.offset == len(data))

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
            case Table_Type.Auto:
                assert(false)
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
                    uni_bits__add(&db.eid_to_tag_bits[eid.ix], tt.id)
                }
            case Table_Type.Arch_Table:
                at := cast(^Arch_Table) table

                for col in at.columns {
                    cih: Snap_Arch_Column_Header
                    snap_reader__read(r, &cih, size_of(cih)) or_return
                    _ = snap_reader__bytes(r, int(cih.name_len)) or_return
                    snap_reader__pad8(r) or_return
                }

                eids := snap_reader__entity_ids(r, n) or_return
                snap_reader__pad8(r) or_return

                #no_bounds_check for rid in 0..<n {
                    at.rid_to_eid[rid] = eids[rid]
                }

                for &col in at.columns {
                    elem_size := col.type_info.size
                    snap_reader__read(r, raw_data(col.rows), n * elem_size) or_return
                    snap_reader__pad8(r) or_return
                }

                #no_bounds_check for rid in 0..<n {
                    eid := eids[rid]
                    at.eid_to_rid[eid.ix] = u32(rid)
                    uni_bits__add(&db.eid_to_bits[eid.ix], at.id)
                }

                at.len = n
        }

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// File convenience

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

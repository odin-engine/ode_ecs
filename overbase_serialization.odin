/*
    2026 (c) Oleh, https://github.com/zm69

    Binary snapshot serialization of an Overbase's entity-id space alone
    (generations, freed list) — independent of which, or how many, Databases
    are currently attached. The attached-database list is runtime-only and is
    never part of this format: Databases re-attach via init_from_overbase
    after a load, same as any freshly created Overbase.

    This is the counterpart to Database's own serialize/deserialize
    (serialization.odin): a Database attached to a shared Overbase no longer
    snapshots (or restores) that Overbase's id-space as part of its own
    snapshot — use overbase_serialize/overbase_deserialize for that instead.
    See docs/overbase.md.

    Shares the Snap_Writer/Snap_Reader cursor helpers and SNAPSHOT_ENDIAN_CHECK
    with serialization.odin, but uses its own magic/version so the two buffer
    kinds can never be cross-loaded by mistake.
*/
package ode_ecs

// Core
    import "core:os"
    import "core:slice"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Format

    @(private)
    OVERBASE_SNAPSHOT_MAGIC :: u64(0x424F_5343_4545_444F) // "ODEECSOB" as little-endian bytes

    @(private)
    OVERBASE_SNAPSHOT_VERSION :: u32(1)

    @(private)
    Overbase_Snapshot_Header :: struct #packed {
        magic:         u64,
        version:       u32,
        endian_check:  u32,
        entities_cap:  i64, // saved id_factory.cap
        created_count: i64, // factory state
        freed_count:   i64,
    }

///////////////////////////////////////////////////////////////////////////////
// Size

    // Exact number of bytes overbase__serialize will produce for the current
    // state. Allocation-free; call it to size the buffer.
    overbase__serialized_size :: proc(self: ^Overbase) -> (size: int, err: Error) {
        if !overbase__is_valid(self) do return 0, API_Error.Object_Invalid

        size = size_of(Overbase_Snapshot_Header)
        size += self.id_factory.cap * size_of(oc.ix_gen)
        size += self.id_factory.freed_count * size_of(int)
        size = snap__align8(size)

        return size, nil
    }

///////////////////////////////////////////////////////////////////////////////
// Serialize

    // Writes a snapshot of the Overbase's entity-id space into buf (sized via
    // overbase__serialized_size). Zero allocations. Works regardless of how
    // many Databases are currently attached — they are not part of the
    // format. Errors: Serialize_Buffer_Too_Small.
    overbase__serialize :: proc(self: ^Overbase, buf: []byte) -> (written: int, err: Error) {
        if !overbase__is_valid(self) do return 0, API_Error.Object_Invalid

        total := overbase__serialized_size(self) or_return
        if len(buf) < total do return 0, API_Error.Serialize_Buffer_Too_Small

        w := Snap_Writer{ buf = buf }

        hdr := Overbase_Snapshot_Header{
            magic         = OVERBASE_SNAPSHOT_MAGIC,
            version       = OVERBASE_SNAPSHOT_VERSION,
            endian_check  = SNAPSHOT_ENDIAN_CHECK,
            entities_cap  = i64(self.id_factory.cap),
            created_count = i64(self.id_factory.created_count),
            freed_count   = i64(self.id_factory.freed_count),
        }
        snap_writer__write(&w, &hdr, size_of(hdr))

        // The WHOLE items array: generations of freed and never-recreated
        // slots drive expired-id detection and must round-trip. The freed
        // list order matters too (LIFO reuse).
        snap_writer__write(&w, raw_data(self.id_factory.items), self.id_factory.cap * size_of(oc.ix_gen))
        snap_writer__write(&w, raw_data(self.id_factory.freed), self.id_factory.freed_count * size_of(int))
        snap_writer__pad8(&w)

        assert(w.offset == total)
        return w.offset, nil
    }

///////////////////////////////////////////////////////////////////////////////
// Deserialize

    // Loads a snapshot into an already-initialized Overbase with cap >= the
    // saved cap. All-or-nothing: the whole buffer is validated before
    // anything is mutated. Safe to call whether zero or more Databases are
    // currently attached to self — restoring the id-space this way is the
    // deliberate, explicit way to roll back a shared entity-id space; unlike
    // Database's own deserialize, this is the only call that touches it.
    overbase__deserialize :: proc(self: ^Overbase, data: []byte) -> Error {
        if !overbase__is_valid(self) do return API_Error.Object_Invalid

        //
        // Pass 1 — validate everything, mutate nothing
        //
        r := Snap_Reader{ data = data }

        hdr: Overbase_Snapshot_Header
        snap_reader__read(&r, &hdr, size_of(hdr)) or_return

        if hdr.magic != OVERBASE_SNAPSHOT_MAGIC do return API_Error.Snapshot_Invalid
        if hdr.endian_check != SNAPSHOT_ENDIAN_CHECK do return API_Error.Snapshot_Invalid
        if hdr.version != OVERBASE_SNAPSHOT_VERSION do return API_Error.Snapshot_Version_Mismatch

        saved_cap := int(hdr.entities_cap)
        created_count := int(hdr.created_count)
        freed_count := int(hdr.freed_count)

        if saved_cap <= 0 do return API_Error.Snapshot_Invalid
        if created_count < 0 || created_count > saved_cap do return API_Error.Snapshot_Invalid
        if freed_count < 0 || freed_count > created_count do return API_Error.Snapshot_Invalid
        if saved_cap > self.id_factory.cap do return API_Error.Snapshot_Capacity_Too_Small

        saved_items := snap_reader__entity_ids(&r, saved_cap) or_return

        freed_bytes := snap_reader__bytes(&r, freed_count * size_of(int)) or_return
        saved_freed := slice.reinterpret([]int, freed_bytes)
        for f in saved_freed {
            if f < 0 || f >= saved_cap do return API_Error.Snapshot_Invalid
            if saved_items[f].ix != DELETED_INDEX do return API_Error.Snapshot_Invalid
        }
        snap_reader__pad8(&r) or_return

        if r.offset != len(data) do return API_Error.Snapshot_Invalid

        //
        // Pass 2 — apply (validated above, so nothing below is expected to fail)
        //

        // No gen bump: the factory items are fully overwritten from the
        // snapshot right after.
        oc.ix_gen_factory__clear(&self.id_factory, bump_gen = false)

        r = Snap_Reader{ data = data }
        snap_reader__read(&r, &hdr, size_of(hdr)) or_return

        // Slots >= saved_cap stay cleared (ix == DELETED_INDEX), so both
        // new_id paths remain correct on a larger target Overbase.
        snap_reader__read(&r, raw_data(self.id_factory.items), saved_cap * size_of(oc.ix_gen)) or_return
        snap_reader__read(&r, raw_data(self.id_factory.freed), freed_count * size_of(int)) or_return
        snap_reader__pad8(&r) or_return
        self.id_factory.created_count = created_count
        self.id_factory.freed_count = freed_count

        assert(r.offset == len(data))

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// File convenience

    // Serialize into a temporary buffer (the only allocation) and write it to
    // `path`, overwriting the file if it exists.
    overbase__save_to_file :: proc(self: ^Overbase, path: string, allocator := context.allocator) -> Error {
        size := overbase__serialized_size(self) or_return

        buf := make([]byte, size, allocator) or_return
        defer delete(buf, allocator)

        written := overbase__serialize(self, buf) or_return

        if os.write_entire_file(path, buf[:written]) != nil do return API_Error.File_Error

        return nil
    }

    overbase__load_from_file :: proc(self: ^Overbase, path: string, allocator := context.allocator) -> Error {
        data, rerr := os.read_entire_file(path, allocator)
        if rerr != nil do return API_Error.File_Error
        defer delete(data, allocator)

        return overbase__deserialize(self, data)
    }

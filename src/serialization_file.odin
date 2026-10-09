/*
    File save/load helpers for serialization.odin and overbase_serialization.odin.
    Split out because core:os doesn't exist on js/wasm; in-memory
    (de)serialization still works there.
*/
#+build !js
package ode_ecs

// Core
    import "core:os"

// Public API
    save_to_file        :: database__save_to_file
    load_from_file      :: database__load_from_file
    overbase_save_to_file    :: overbase__save_to_file
    overbase_load_from_file  :: overbase__load_from_file

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

///////////////////////////////////////////////////////////////////////////////
// File convenience (overbase)

    // Serialize into a temporary buffer (the only allocation) and write it to `path`, overwriting the file if it exists.
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

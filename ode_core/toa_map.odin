/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_core

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"

///////////////////////////////////////////////////////////////////////////////
// Tiny Open Addressing Map (tiny one array map, int to $V).

    Toa_Map :: struct($CAP: int, $V: typeid) {
        values: [CAP]V,
    }

    toa_map__init :: proc (self: ^Toa_Map($CAP, $V)) {

    }

    toa_map__terminate :: proc (self: ^Toa_Map($CAP, $V)) {

    }

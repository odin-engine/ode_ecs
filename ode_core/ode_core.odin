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
//

    // Mirrors the ECS-level flag (ecs.odin): -define:ECS_VALIDATIONS=false
    // also compiles out ode_core's hot-path sanity asserts, keeping the
    // "validations off = no checks in the game loop" promise in one switch.
    VALIDATIONS :: #config(ECS_VALIDATIONS, true)

    DELETED_INDEX :: -1

    Core_Error :: enum {
        None = 0,
        Container_Is_Full,
        Unexpected_Error,
        Not_Found,
        Already_Freed,
        Out_Of_Bounds,
        Already_Exists,
        Capacity_Is_Not_Power_Of_2,
        Key_Exists,
    }

    Error :: union #shared_nil {
        Core_Error,
        runtime.Allocator_Error,
    }
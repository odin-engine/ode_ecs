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

    DELETED_INDEX :: -1

    Core_Error :: enum {
        None = 0,
        Container_Is_Full,
        Unexpected_Error,
        Not_Found,
        Already_Freed,
        Out_Of_Bounds,
        Already_Exists,
    }

    Error :: union #shared_nil {
        Core_Error,
        runtime.Allocator_Error,
    }
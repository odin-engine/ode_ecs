/*
    2025 (c) Oleh, https://github.com/zm69
*/
package maps

// Base
    import "base:runtime"

// Core
    import "core:log"
    import "core:mem"
    import "core:testing"

    // Predictable hash values for map tests (key 0 -> hash 0, key 1 -> hash 1, etc.)
    MAPS_TESTING :: #config(maps_testing, false)
    RH_MAP32_LOAD_PCT :: #config(RH_MAP32_LOAD_PCT, 50) // max load factor, percent
    #assert(RH_MAP32_LOAD_PCT > 0 && RH_MAP32_LOAD_PCT < 100)

    // Same switch as ode_core/ecs: also compiles out hot-path sanity asserts here.
    VALIDATIONS :: #config(ECS_VALIDATIONS, true)

///////////////////////////////////////////////////////////////////////////////
// Aliases
//


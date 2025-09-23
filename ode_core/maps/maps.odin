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

    // To test maps we need predictable hash values (like for key 0 hash should be 0, for key 1 hash should be 1, etc.)
    // Set maps_testing to true in command line when you are runnig maps tests, like this:
    // odin test . -define:maps_testing=true

    MAPS_TESTING :: #config(maps_testing, false) // set to true to enable testing code

///////////////////////////////////////////////////////////////////////////////
// Aliases
//


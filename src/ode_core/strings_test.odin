/*
    2025 (c) Oleh, https://github.com/zm69
*/
#+build !js
package ode_core

import "core:strings"
import "core:mem"
import "core:testing"

    @(test)
    add_thousand_separator__test :: proc(t: ^testing.T) {

        a := context.temp_allocator

        testing.expect(t, strings.compare(add_thousand_separator(0, ',', a), "0") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(10, ',', a), "10") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(100, ',', a), "100") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(1000, ',', a), "1,000") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(10000, ',', a), "10,000") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(100000, ',', a), "100,000") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(1000000, ',', a), "1,000,000") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(10000000, ',', a), "10,000,000") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(-10000000, ',', a), "-10,000,000") == 0)
        testing.expect(t, strings.compare(add_thousand_separator(-1, ',', a), "-1") == 0)

        mem.free_all(a)
    }

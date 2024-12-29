/*
    2025 (c) Oleh, https://github.com/zm69
*/
package ode_core

import "core:strings"
import "core:mem"
import "core:testing"

///////////////////////////////////////////////////////////////////////////////
// Strings
// 

    add_thousand_separator :: proc (value: int, sep := '_', allocator := context.allocator) -> (ret: string, err: mem.Allocator_Error) #optional_allocator_error {
        b := strings.builder_make(allocator = allocator) or_return 
        defer strings.builder_destroy(&b)

        strings.write_int(&b, value)

        b_len := len(b.buf)

        b_len_m := b_len // b_len but taking into a accout minus
        if value < 0 do b_len_m -= 1

        inserts_count := b_len_m % 3 == 0 ? b_len_m / 3 - 1 : b_len_m / 3
        res_b_len := b_len + inserts_count

        res_b := strings.builder_make_len(res_b_len, allocator = allocator) or_return
        defer strings.builder_destroy(&res_b)

        j:=res_b_len-1
        for i := 0; i < b_len; i+=1 {
            res_b.buf[j] = b.buf[b_len-1-i]
            if (i + 1) % 3 == 0 && inserts_count > 0 {
                j-= 1
                res_b.buf[j] = u8(sep)
                inserts_count -= 1
            }
            j -= 1
        }

        return strings.clone(strings.to_string(res_b), allocator), nil 
    }

///////////////////////////////////////////////////////////////////////////////
// Tests
// 

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
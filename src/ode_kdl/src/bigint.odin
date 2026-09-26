/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    Bigint — minimal unsigned big integer, used only for parsing/formatting
    KDL integer literals too large to fit in i64. Ported from ckdl's
    src/bigint.c (base-2^32 digit array), but leans on Odin's `[dynamic]u32`
    for growth instead of hand-rolled realloc, and `append`/`pop` instead of
    the manual carry-digit dance.
*/
package kdl

// Core
    import "base:runtime"
    import "core:strings"

///////////////////////////////////////////////////////////////////////////////
// Bigint

    @(private)
    Bigint :: struct {
        digits:    [dynamic]u32, // little-endian base-2^32 digits, len >= 1
        allocator: runtime.Allocator,
    }

    @(private)
    bigint_init :: proc(self: ^Bigint, initial_value: u32 = 0, allocator := context.allocator) -> runtime.Allocator_Error {
        self.allocator = allocator
        self.digits = make([dynamic]u32, 1, allocator) or_return
        self.digits[0] = initial_value
        return nil
    }

    @(private)
    bigint_destroy :: proc(self: ^Bigint) {
        delete(self.digits)
        self.digits = nil
    }

    // self += b
    @(private)
    bigint_add :: proc(self: ^Bigint, b: u32) -> runtime.Allocator_Error {
        carry := u64(b)
        for i in 0 ..< len(self.digits) {
            tmp := u64(self.digits[i]) + carry
            carry = tmp >> 32
            self.digits[i] = u32(tmp)
        }
        if carry != 0 {
            _, err := append(&self.digits, u32(carry))
            if err != nil do return err
        }
        return nil
    }

    // self *= b
    @(private)
    bigint_multiply :: proc(self: ^Bigint, b: u32) -> runtime.Allocator_Error {
        carry: u32 = 0
        for i in 0 ..< len(self.digits) {
            tmp := u64(self.digits[i]) * u64(b) + u64(carry)
            carry = u32(tmp >> 32)
            self.digits[i] = u32(tmp)
        }
        if carry != 0 {
            _, err := append(&self.digits, carry)
            if err != nil do return err
        }
        return nil
    }

    // self /= b, returns the remainder
    @(private)
    bigint_divide :: proc(self: ^Bigint, b: u32) -> (remainder: u32) {
        rem: u64 = 0
        #reverse for _, i in self.digits {
            tmp := u64(self.digits[i]) | (rem << 32)
            rem = tmp % u64(b)
            self.digits[i] = u32(tmp / u64(b))
        }
        for len(self.digits) > 1 && self.digits[len(self.digits) - 1] == 0 {
            pop(&self.digits)
        }
        return u32(rem)
    }

    // Convert to i64, if it fits (matches ckdl: at most 2 base-2^32 digits, top bit clear)
    @(private)
    bigint_as_i64 :: proc(self: ^Bigint) -> (result: i64, ok: bool) {
        if len(self.digits) > 2 do return 0, false

        top := self.digits[len(self.digits) - 1]
        if top & 0x8000_0000 != 0 do return 0, false

        v: u64 = 0
        #reverse for d in self.digits {
            v = (v << 32) | u64(d)
        }
        return i64(v), true
    }

    // Format as a signed decimal string. Destructive to a scratch copy, not to self.
    @(private)
    bigint_to_decimal_string :: proc(self: ^Bigint, negative: bool, allocator := context.allocator) -> (result: string, err: runtime.Allocator_Error) {
        tmp: Bigint
        tmp.digits = make([dynamic]u32, len(self.digits), context.temp_allocator) or_return
        copy(tmp.digits[:], self.digits[:])
        defer delete(tmp.digits)

        sb: strings.Builder
        _ = strings.builder_init(&sb, allocator) or_return

        if negative do strings.write_byte(&sb, '-')

        decimal_digits := make([dynamic]byte, 0, 12, context.temp_allocator) or_return
        defer delete(decimal_digits)
        for len(tmp.digits) > 1 || tmp.digits[0] != 0 {
            d := bigint_divide(&tmp, 10)
            _, append_err := append(&decimal_digits, '0' + byte(d))
            if append_err != nil do return "", append_err
        }

        if len(decimal_digits) == 0 {
            strings.write_byte(&sb, '0')
        } else {
            #reverse for d in decimal_digits {
                strings.write_byte(&sb, d)
            }
        }

        return strings.to_string(sb), nil
    }

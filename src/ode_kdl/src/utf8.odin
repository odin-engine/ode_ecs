/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    UTF-8 decode helpers. pop_rune/peek_rune lean on core:unicode/utf8 and are
    used everywhere a whole string is already buffered (nothing more is ever
    coming, so an invalid trailing sequence is just invalid). peek_codepoint
    is the streaming tokenizer's own byte-level decoder (ported from ckdl's
    utf8.c) — it alone distinguishes a truncated-at-the-buffer-edge sequence
    (Incomplete: go read more) from a genuinely invalid one (Decode_Error).
*/
package kdl

// Core
    import "core:unicode/utf8"

///////////////////////////////////////////////////////////////////////////////
// Utf8

    Utf8_Status :: enum u8 {
        OK,
        EOF,
        Decode_Error,
    }

    // Decode and consume one rune from the front of s. Advances s past the rune on OK.
    @(private)
    pop_rune :: proc(s: ^string) -> (r: rune, status: Utf8_Status) {
        if len(s^) == 0 do return 0, .EOF

        width: int
        r, width = utf8.decode_rune_in_string(s^)
        if r == utf8.RUNE_ERROR && width <= 1 do return 0, .Decode_Error

        s^ = s[width:]
        return r, .OK
    }

    // Decode one rune at a byte offset into s, without mutating anything. Returns the
    // byte offset just past the rune. Used by the string tokenizer, which needs to
    // peek and backtrack by exact byte positions.
    @(private)
    peek_rune :: proc(s: string, offset: int) -> (r: rune, next_offset: int, status: Utf8_Status) {
        if offset >= len(s) do return 0, offset, .EOF

        width: int
        r, width = utf8.decode_rune_in_string(s[offset:])
        if r == utf8.RUNE_ERROR && width <= 1 do return 0, offset, .Decode_Error

        return r, offset + width, .OK
    }

    @(private)
    Codepoint_Status :: enum u8 {
        OK,
        EOF,
        Incomplete,
        Decode_Error,
    }

    @(private)
    is_utf8_continuation :: #force_inline proc(b: byte) -> bool {
        return b & 0xc0 == 0x80
    }

    // Byte-level decode at offset into data, distinguishing Incomplete (not enough
    // buffered bytes yet for this sequence) from Decode_Error (invalid encoding).
    @(private)
    peek_codepoint :: proc(data: []byte, offset: int) -> (r: rune, next_offset: int, status: Codepoint_Status) {
        avail := len(data) - offset
        if avail < 1 do return 0, offset, .EOF

        s0 := data[offset]
        switch {
        case s0 & 0x80 == 0:
            return rune(s0), offset + 1, .OK

        case s0 & 0xe0 == 0xc0:
            if avail < 2 do return 0, offset, .Incomplete
            if !is_utf8_continuation(data[offset + 1]) do return 0, offset, .Decode_Error
            r = rune(s0 & 0x1f) << 6 | rune(data[offset + 1] & 0x3f)
            return r, offset + 2, .OK

        case s0 & 0xf0 == 0xe0:
            if avail < 3 do return 0, offset, .Incomplete
            if !is_utf8_continuation(data[offset + 1]) || !is_utf8_continuation(data[offset + 2]) {
                return 0, offset, .Decode_Error
            }
            r = rune(s0 & 0xf) << 12 | rune(data[offset + 1] & 0x3f) << 6 | rune(data[offset + 2] & 0x3f)
            return r, offset + 3, .OK

        case s0 & 0xf8 == 0xf0:
            if avail < 4 do return 0, offset, .Incomplete
            if !is_utf8_continuation(data[offset + 1]) || !is_utf8_continuation(data[offset + 2]) ||
               !is_utf8_continuation(data[offset + 3]) {
                return 0, offset, .Decode_Error
            }
            r = rune(s0 & 0x7) << 18 | rune(data[offset + 1] & 0x3f) << 12 | rune(data[offset + 2] & 0x3f) << 6 |
                rune(data[offset + 3] & 0x3f)
            return r, offset + 4, .OK

        case:
            return 0, offset, .Decode_Error
        }
    }

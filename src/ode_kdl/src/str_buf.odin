/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    String escaping/unescaping for KDL v2 string literals. Ported from
    ckdl's src/str.c (v2 half only — no kdl_version parameter, no v1
    functions). Uses core:strings.Builder in place of ckdl's hand-rolled
    _kdl_write_buffer; growth is handled by the builder instead of manual
    realloc.
*/
package kdl

// Core
    import "core:strings"

///////////////////////////////////////////////////////////////////////////////
// Escape_Mode

    Escape_Flag :: enum u8 {
        Control,     // escape ASCII control characters
        Newline,     // escape newline characters
        Tab,         // escape tabs
        Ascii_Extra, // combined with the other three: escape all non-ASCII characters
    }
    Escape_Mode :: bit_set[Escape_Flag]

    ESCAPE_MINIMAL     :: Escape_Mode{}
    ESCAPE_CONTROL     :: Escape_Mode{.Control}
    ESCAPE_NEWLINE     :: Escape_Mode{.Newline}
    ESCAPE_TAB         :: Escape_Mode{.Tab}
    ESCAPE_ASCII_MODE  :: Escape_Mode{.Control, .Newline, .Tab, .Ascii_Extra}
    ESCAPE_DEFAULT     :: Escape_Mode{.Control, .Newline, .Tab}

///////////////////////////////////////////////////////////////////////////////
// Public

    // Escape special characters in s according to KDL v2 string rules.
    escape :: proc(s: string, mode: Escape_Mode, allocator := context.allocator) -> (result: string, ok: bool) {
        sb: strings.Builder
        if _, err := strings.builder_init(&sb, allocator); err != nil do return "", false

        remaining := s
        for {
            before := remaining
            c, status := pop_rune(&remaining)
            if status == .EOF do return strings.to_string(sb), true
            if status == .Decode_Error {
                strings.builder_destroy(&sb)
                return "", false
            }

            switch {
            case c == 0x0A && .Newline in mode:
                strings.write_string(&sb, "\\n")
            case c == 0x0D && .Newline in mode:
                strings.write_string(&sb, "\\r")
            case c == 0x09 && .Tab in mode:
                strings.write_string(&sb, "\\t")
            case c == 0x5C: // backslash
                strings.write_string(&sb, "\\\\")
            case c == 0x22: // "
                strings.write_string(&sb, "\\\"")
            case c == 0x08 && .Control in mode:
                strings.write_string(&sb, "\\b")
            case c == 0x0C && .Newline in mode:
                strings.write_string(&sb, "\\f")
            case is_illegal_char(c) ||
                 (.Control in mode && c == 0x0B) ||
                 (.Newline in mode && (c == 0x85 || c == 0x2028 || c == 0x2029)) ||
                 ((mode & ESCAPE_ASCII_MODE) == ESCAPE_ASCII_MODE && c >= 0x7f):
                strings.write_string(&sb, "\\u{")
                strings.write_u64(&sb, u64(c), 16)
                strings.write_byte(&sb, '}')
            case:
                // keep the original bytes of this rune
                strings.write_string(&sb, before[:len(before) - len(remaining)])
            }
        }
    }

    // Resolve backslash escape sequences (KDL v2 single-line string rules).
    unescape_single_line :: proc(s: string, allocator := context.allocator) -> (result: string, ok: bool) {
        no_ws_escapes := remove_escaped_whitespace(s, allocator) or_return
        defer delete(no_ws_escapes, allocator)

        if contains_newline(no_ws_escapes) do return "", false

        return resolve_escapes(no_ws_escapes, allocator)
    }

    // Resolve backslash escape sequences and dedent (KDL v2 multi-line string rules).
    unescape_multi_line :: proc(s: string, allocator := context.allocator) -> (result: string, ok: bool) {
        no_ws_escapes := remove_escaped_whitespace(s, allocator) or_return
        defer delete(no_ws_escapes, allocator)

        dedented := dedent_multiline_string(no_ws_escapes, allocator) or_return
        defer delete(dedented, allocator)

        return resolve_escapes(dedented, allocator)
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    contains_newline :: proc(s: string) -> bool {
        remaining := s
        for {
            c, status := pop_rune(&remaining)
            if status != .OK do return false
            if is_newline(c) do return true
        }
    }

    // Remove backslash-whitespace continuations ("\" followed by whitespace/newlines,
    // up to the next non-whitespace character), leaving other backslash escapes intact
    // for resolve_escapes to handle.
    @(private)
    remove_escaped_whitespace :: proc(s: string, allocator := context.allocator) -> (result: string, ok: bool) {
        sb: strings.Builder
        if _, err := strings.builder_init(&sb, allocator); err != nil do return "", false

        remaining := s
        for {
            c, status := pop_rune(&remaining)
            if status == .EOF do return strings.to_string(sb), true
            if status == .Decode_Error || is_illegal_char(c) {
                strings.builder_destroy(&sb)
                return "", false
            }

            if c != '\\' {
                strings.write_rune(&sb, c)
                continue
            }

            tail := remaining
            removed_whitespace := false
            last_status: Utf8_Status
            for {
                c2: rune
                c2, last_status = pop_rune(&tail)
                if last_status != .OK do break
                if !(is_whitespace(c2) || is_newline(c2)) do break
                remaining = tail
                removed_whitespace = true
            }
            if last_status == .Decode_Error {
                strings.builder_destroy(&sb)
                return "", false
            }

            if !removed_whitespace {
                strings.write_byte(&sb, '\\')
                c3, status3 := pop_rune(&remaining)
                if status3 == .OK do strings.write_rune(&sb, c3)
            }
        }
    }

    // Remove common leading whitespace from a multi-line string body (KDL v2 rules).
    // Expects normalized input (no backslash-whitespace continuations left).
    @(private)
    dedent_multiline_string :: proc(s: string, allocator := context.allocator) -> (result: string, ok: bool) {
        // Normalize all newline variants to plain LF
        norm_sb: strings.Builder
        if _, err := strings.builder_init(&norm_sb, allocator); err != nil do return "", false

        remaining := s
        for {
            c, status := pop_rune(&remaining)
            if status == .EOF do break
            if status == .Decode_Error {
                strings.builder_destroy(&norm_sb)
                return "", false
            }
            if is_newline(c) {
                if c == '\r' && len(remaining) >= 1 && remaining[0] == '\n' {
                    remaining = remaining[1:]
                }
                strings.write_byte(&norm_sb, '\n')
            } else {
                strings.write_rune(&norm_sb, c)
            }
        }

        norm_lf := strings.to_string(norm_sb)
        defer delete(norm_lf, allocator)

        final_newline := -1
        for i := len(norm_lf) - 1; i >= 0; i -= 1 {
            if norm_lf[i] == '\n' {
                final_newline = i
                break
            }
        }
        if final_newline < 0 do return "", false // no newlines: not a valid multi-line string

        indent := norm_lf[final_newline + 1:]

        // indentation must be all whitespace
        indent_scan := indent
        for {
            c, status := pop_rune(&indent_scan)
            if status == .EOF do break
            if status != .OK || !is_whitespace(c) do return "", false
        }

        if len(norm_lf) == 0 || norm_lf[0] != '\n' do return "", false

        out_sb: strings.Builder
        if _, err := strings.builder_init(&out_sb, allocator); err != nil do return "", false

        in_pos := 1 // skip initial LF
        for in_pos < len(norm_lf) {
            eol := in_pos
            for eol < len(norm_lf) && norm_lf[eol] != '\n' do eol += 1
            if eol == len(norm_lf) do break // final (indent-only) segment - not part of the content

            line := norm_lf[in_pos:eol]

            is_ws := true
            line_scan := line
            for {
                c, status := pop_rune(&line_scan)
                if status == .EOF do break
                if status != .OK || !is_whitespace(c) {
                    is_ws = false
                    break
                }
            }

            if is_ws {
                strings.write_byte(&out_sb, '\n')
            } else if len(line) >= len(indent) && line[:len(indent)] == indent {
                strings.write_string(&out_sb, line[len(indent):])
                strings.write_byte(&out_sb, '\n')
            } else {
                strings.builder_destroy(&out_sb)
                return "", false
            }

            in_pos = eol + 1
        }

        out := strings.to_string(out_sb)
        if len(out) > 0 && out[len(out) - 1] == '\n' {
            out = out[:len(out) - 1]
        }
        return out, true
    }

    // Resolve backslash escapes (\n \r \t \s \\ \" \b \f \u{...}) into their literal characters.
    @(private)
    resolve_escapes :: proc(s: string, allocator := context.allocator) -> (result: string, ok: bool) {
        sb: strings.Builder
        if _, err := strings.builder_init(&sb, allocator); err != nil do return "", false

        remaining := s
        for {
            c, status := pop_rune(&remaining)
            if status == .EOF do return strings.to_string(sb), true
            if status == .Decode_Error || is_illegal_char(c) {
                strings.builder_destroy(&sb)
                return "", false
            }

            if c != '\\' {
                strings.write_rune(&sb, c)
                continue
            }

            c2, status2 := pop_rune(&remaining)
            if status2 != .OK {
                strings.builder_destroy(&sb)
                return "", false
            }

            switch c2 {
            case 'n': strings.write_byte(&sb, '\n')
            case 'r': strings.write_byte(&sb, '\r')
            case 't': strings.write_byte(&sb, '\t')
            case 's': strings.write_byte(&sb, ' ')
            case '\\': strings.write_byte(&sb, '\\')
            case '"': strings.write_byte(&sb, '"')
            case 'b': strings.write_byte(&sb, '\b')
            case 'f': strings.write_byte(&sb, '\f')
            case 'u':
                c3, status3 := pop_rune(&remaining)
                if status3 != .OK || c3 != '{' {
                    strings.builder_destroy(&sb)
                    return "", false
                }

                r: u32 = 0
                closed := false
                loop: for {
                    c4, status4 := pop_rune(&remaining)
                    if status4 != .OK {
                        strings.builder_destroy(&sb)
                        return "", false
                    }
                    digit: u32
                    switch {
                    case c4 == '}':
                        closed = true
                        break loop
                    case c4 >= '0' && c4 <= '9': digit = u32(c4 - '0')
                    case c4 >= 'a' && c4 <= 'f': digit = u32(c4 - 'a') + 0xa
                    case c4 >= 'A' && c4 <= 'F': digit = u32(c4 - 'A') + 0xa
                    case:
                        strings.builder_destroy(&sb)
                        return "", false
                    }
                    r = (r << 4) + digit
                }
                if !closed || r > 0x10FFFF || (0xD800 <= r && r <= 0xDFFF) {
                    strings.builder_destroy(&sb)
                    return "", false
                }
                strings.write_rune(&sb, rune(r))
            case:
                strings.builder_destroy(&sb)
                return "", false
            }
        }
    }

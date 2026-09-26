/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    Emitter — formats KDL v2 events back into document text. Ported from
    ckdl's src/emitter.c, v2-only (always emits #null/#true/#false, always
    prefers bare identifiers per KDL v2 rules).

    Buffering mode (emitter__init) and streaming mode (emitter__init_stream)
    both write through the same self.writer: io.Writer field — buffering mode
    just points it at self.buf via strings.to_writer. Because of that, an
    Emitter must never be moved after init; self.writer in buffering mode
    holds a pointer into the same struct it lives in.
*/
package kdl

// Core
    import "base:runtime"
    import "core:io"
    import "core:math"
    import "core:strconv"
    import "core:strings"

///////////////////////////////////////////////////////////////////////////////
// Emitter_Options

    Identifier_Emission_Mode :: enum u8 {
        Prefer_Bare, // quote identifiers only if absolutely necessary
        Quote_All,   // express *all* identifiers as strings
        Ascii_Only,  // use only ASCII
    }

    Float_Printing_Options :: struct {
        always_write_decimal_point:             bool,
        always_write_decimal_point_or_exponent: bool,
        capital_e:                              bool,
        exponent_plus:                          bool,
        plus:                                   bool,
        min_exponent:                           int,
    }

    Emitter_Options :: struct {
        indent:          int, // number of spaces to indent child nodes by
        escape_mode:     Escape_Mode,
        identifier_mode: Identifier_Emission_Mode,
        float_mode:      Float_Printing_Options,
    }

    DEFAULT_EMITTER_OPTIONS :: Emitter_Options{
        indent          = 4,
        escape_mode     = ESCAPE_DEFAULT,
        identifier_mode = .Prefer_Bare,
        float_mode      = Float_Printing_Options{
            always_write_decimal_point             = false,
            always_write_decimal_point_or_exponent = true,
            capital_e                              = false,
            exponent_plus                          = false,
            plus                                   = false,
            min_exponent                           = 4,
        },
    }

///////////////////////////////////////////////////////////////////////////////
// Emitter

    Emitter :: struct {
        opt:           Emitter_Options,
        depth:         int,
        start_of_line: bool,
        writer:        io.Writer,
        buffering:     bool, // true: buf owns storage and get_buffer is valid; false: writer is caller-supplied
        buf:           strings.Builder,
        allocator:     runtime.Allocator,
    }

    emitter__init :: proc(self: ^Emitter, opt: Emitter_Options = DEFAULT_EMITTER_OPTIONS, allocator := context.allocator) -> runtime.Allocator_Error {
        self^ = Emitter{}
        self.allocator = allocator
        self.opt = opt
        self.start_of_line = true
        self.buffering = true
        _ = strings.builder_init(&self.buf, allocator) or_return
        self.writer = strings.to_writer(&self.buf)
        return nil
    }

    emitter__init_stream :: proc(self: ^Emitter, writer: io.Writer, opt: Emitter_Options = DEFAULT_EMITTER_OPTIONS, allocator := context.allocator) {
        self^ = Emitter{}
        self.allocator = allocator // still needed: escape()/float_to_string() allocate scratch buffers regardless of output mode
        self.opt = opt
        self.start_of_line = true
        self.writer = writer
    }

    emitter__destroy :: proc(self: ^Emitter) {
        _ = emitter__emit_end(self)
        if self.buffering do strings.builder_destroy(&self.buf)
        self^ = Emitter{}
    }

    // Write a node tag
    emitter__emit_node :: proc(self: ^Emitter, name: string) -> bool {
        return emitter__emit_node_preamble(self) && emitter__emit_bare_string(self, name)
    }

    // Write a node tag including a type annotation
    emitter__emit_node_with_type :: proc(self: ^Emitter, type: string, name: string) -> bool {
        return emitter__emit_node_preamble(self) &&
            emitter__write_str(self, "(") && emitter__emit_bare_string(self, type) && emitter__write_str(self, ")") &&
            emitter__emit_bare_string(self, name)
    }

    // Write an argument for a node
    emitter__emit_arg :: proc(self: ^Emitter, value: Value) -> bool {
        return emitter__write_str(self, " ") && emitter__emit_value(self, value)
    }

    // Write a property for a node
    emitter__emit_property :: proc(self: ^Emitter, name: string, value: Value) -> bool {
        return emitter__write_str(self, " ") && emitter__emit_bare_string(self, name) && emitter__write_str(self, "=") && emitter__emit_value(self, value)
    }

    // Start a list of children for the previous node ('{')
    emitter__start_emitting_children :: proc(self: ^Emitter) -> bool {
        self.start_of_line = true
        self.depth += 1
        return emitter__write_str(self, " {\n")
    }

    // End the list of children ('}')
    emitter__finish_emitting_children :: proc(self: ^Emitter) -> bool {
        if self.depth == 0 do return false
        self.depth -= 1
        if !emitter__emit_node_preamble(self) do return false
        self.start_of_line = true
        return emitter__write_str(self, "}\n")
    }

    // Finish - write a final newline if required
    emitter__emit_end :: proc(self: ^Emitter) -> bool {
        for self.depth != 0 {
            if !emitter__finish_emitting_children(self) do return false
        }
        if !self.start_of_line {
            if !emitter__write_str(self, "\n") do return false
            self.start_of_line = true
        }
        return true
    }

    // Buffering mode only. Invalidated by any further emit_* call.
    emitter__get_buffer :: proc(self: ^Emitter) -> string {
        return strings.to_string(self.buf)
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    emitter__write_str :: proc(self: ^Emitter, s: string) -> bool {
        n, err := io.write_string(self.writer, s)
        return err == nil && n == len(s)
    }

    @(private)
    emitter__emit_quoted_str :: proc(self: ^Emitter, s: string) -> bool {
        escaped, ok := escape(s, self.opt.escape_mode, self.allocator)
        if !ok do return false
        defer delete(escaped, self.allocator)
        return emitter__write_str(self, "\"") && emitter__write_str(self, escaped) && emitter__write_str(self, "\"")
    }

    @(private)
    emitter__emit_bare_string :: proc(self: ^Emitter, s: string) -> bool {
        bare := true
        if self.opt.identifier_mode == .Quote_All {
            bare = false
        } else if len(s) == 0 {
            bare = false
        } else {
            require_ascii := self.opt.identifier_mode == .Ascii_Only ||
                (self.opt.escape_mode & ESCAPE_ASCII_MODE) == ESCAPE_ASCII_MODE
            first := true
            remaining := s
            for {
                c, status := pop_rune(&remaining)
                if status != .OK do break
                if (first && !is_id_start(c)) || !is_id(c) || (require_ascii && c >= 0x7f) {
                    bare = false
                    break
                }
                first = false
            }
        }

        if bare do return emitter__write_str(self, s)
        return emitter__emit_quoted_str(self, s)
    }

    @(private)
    emitter__emit_number :: proc(self: ^Emitter, n: Number) -> bool {
        switch v in n {
        case i64:
            buf: [32]byte
            return emitter__write_str(self, strconv.write_int(buf[:], v, 10))
        case f64:
            s := float_to_string(v, self.opt.float_mode, self.allocator)
            defer delete(s, self.allocator)
            return emitter__write_str(self, s)
        case string:
            return emitter__write_str(self, v)
        }
        return false
    }

    @(private)
    emitter__emit_value :: proc(self: ^Emitter, v: Value) -> bool {
        if ta, has_ta := v.type_annotation.?; has_ta {
            if !(emitter__write_str(self, "(") && emitter__emit_bare_string(self, ta) && emitter__write_str(self, ")")) {
                return false
            }
        }

        switch val in v.variant {
        case bool:
            return emitter__write_str(self, val ? "#true" : "#false")
        case Number:
            return emitter__emit_number(self, val)
        case string:
            return emitter__emit_bare_string(self, val)
        case:
            return emitter__write_str(self, "#null")
        }
    }

    @(private)
    emitter__emit_node_preamble :: proc(self: ^Emitter) -> bool {
        if !self.start_of_line {
            if !emitter__write_str(self, "\n") do return false
        }
        indent := self.depth * self.opt.indent
        for i := 0; i < indent; i += 1 {
            if !emitter__write_str(self, " ") do return false
        }
        self.start_of_line = false
        return true
    }

    // Formats a double the way ckdl does: the shortest decimal representation that
    // rounds back to the same double, digit by digit, honoring Float_Printing_Options.
    @(private)
    float_to_string :: proc(f: f64, opts: Float_Printing_Options, allocator := context.allocator) -> string {
        if math.is_nan(f) do return strings.clone("#nan", allocator)
        if math.is_inf(f, 0) do return strings.clone(f < 0.0 ? "#-inf" : "#inf", allocator)

        negative := f < 0.0
        af := math.abs(f)
        exponent := af != 0.0 ? int(math.floor(math.log10(af))) : 0
        exp_factor := 1.0
        if math.abs(exponent) < opts.min_exponent {
            exponent = 0
        } else {
            exp_factor = math.pow(f64(10.0), f64(exponent))
        }

        integer_part := int(math.floor(af / exp_factor))

        sb: strings.Builder
        strings.builder_init(&sb, allocator)

        if negative {
            strings.write_byte(&sb, '-')
        } else if opts.plus {
            strings.write_byte(&sb, '+')
        }
        strings.write_int(&sb, integer_part)

        f_intpart := f64(integer_part) * exp_factor
        written_point := false
        zeros := 0
        nines := 0
        queued_digit := -1
        fractional_part_so_far: u64 = 0
        pos := 0.1 * exp_factor

        f_so_far := f_intpart

        for af + pos != af && f_so_far < af { // while this digit makes a difference
            remainder := af - f_so_far
            next_digit := int(math.floor(remainder / pos))
            fractional_part_so_far = 10 * fractional_part_so_far + u64(next_digit)

            for f_intpart + f64(fractional_part_so_far + 1) * pos <= af {
                next_digit += 1
                fractional_part_so_far += 1
            }

            f_so_far = f_intpart + f64(fractional_part_so_far) * pos

            if next_digit == 0 {
                zeros += 1
            } else if next_digit == 9 {
                nines += 1
            } else if next_digit >= 10 {
                // defensive clamp; shouldn't normally happen
                overflow := next_digit - 9
                next_digit -= overflow
                fractional_part_so_far -= u64(overflow)
            } else {
                if queued_digit >= 0 || zeros != 0 || nines != 0 {
                    if !written_point {
                        strings.write_byte(&sb, '.')
                        written_point = true
                    }
                    if queued_digit >= 0 do strings.write_byte(&sb, '0' + byte(queued_digit))
                    for zeros > 0 {
                        strings.write_byte(&sb, '0')
                        zeros -= 1
                    }
                    for nines > 0 {
                        strings.write_byte(&sb, '9')
                        nines -= 1
                    }
                }
                queued_digit = next_digit
            }

            pos /= 10.0
        }

        if queued_digit != -1 {
            if !written_point {
                strings.write_byte(&sb, '.')
                written_point = true
            }
            if nines != 0 do queued_digit += 1
            strings.write_byte(&sb, '0' + byte(queued_digit))
        }
        // Adding more decimal digits now makes no difference to the number.

        if !written_point && opts.always_write_decimal_point {
            strings.write_string(&sb, ".0")
            written_point = true
        }

        if exponent != 0 {
            strings.write_byte(&sb, opts.capital_e ? 'E' : 'e')
            if exponent >= 0 && opts.exponent_plus do strings.write_byte(&sb, '+')
            strings.write_int(&sb, exponent)
        } else if !written_point && opts.always_write_decimal_point_or_exponent {
            // Always write either an exponent or a decimal point, to mark this number as float
            strings.write_string(&sb, ".0")
        }

        return strings.to_string(sb)
    }

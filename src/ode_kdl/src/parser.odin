/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    Parser — a pull parser for KDL v2 documents. Ported from ckdl's
    src/parser.c, v2-only (no kdl_version detection/switching, no KDLv1
    literals). Supports both whole-string input (parser__init) and
    streaming input from an io.Reader (parser__init_stream) — see
    tokenizer.odin, which does all the actual streaming work.

    ckdl packs the state machine's "can this event happen here" flags as
    extra bits ORed onto a small base-state enum (PARSER_FLAG_* = 0x100,
    0x200, ...). This port keeps ckdl's exact state machine but represents
    it as a `Parser_Base_State` enum plus a `Parser_Flags` bit_set, which
    is what those extra bits actually were.

    Number parsing goes through Bigint (see bigint.odin) exactly like
    ckdl, to support integer literals wider than i64 — they fall back to
    Number's string-encoded case, matching kdl_number's
    KDL_NUMBER_TYPE_STRING_ENCODED.
*/
package kdl

// Core
    import "base:runtime"
    import "core:io"
    import "core:math"
    import "core:strings"

///////////////////////////////////////////////////////////////////////////////
// Event

    Event_Type :: enum u8 {
        EOF,
        Parse_Error,
        Start_Node,
        End_Node,
        Argument,
        Property,
        Comment, // a standalone // or /* */ comment (only produced when emit_comments is on)
    }

    Event :: struct {
        type:          Event_Type,
        commented_out: bool, // this node/argument/property was commented out with /- (only set when emit_comments is on)
        name:          string, // node or property name
        value:         Value, // argument/property value; for Start_Node: null, possibly with a type annotation
        location:      Location, // where the node, argument or property starts
    }

///////////////////////////////////////////////////////////////////////////////
// Parser

    @(private)
    Parser_Base_State :: enum u8 {
        Outside_Node,
        In_Node,
    }

    @(private)
    Parser_Flag :: enum u8 {
        Line_Cont,
        Type_Annotation_Start,
        Type_Annotation_End,
        Type_Annotation_Ended,
        In_Property,
        Maybe_In_Property,
        Newlines_Are_Whitespace,
        End_Of_Node,
        End_Of_Node_Or_Child_Block,
        Whitespace_Required,
        Contextually_Illegal_Whitespace,
    }
    @(private)
    Parser_Flags :: bit_set[Parser_Flag]

    @(private)
    NODE_CANNOT_END_HERE :: Parser_Flags{
        .Type_Annotation_Start, .Type_Annotation_End, .Type_Annotation_Ended,
        .In_Property, .Maybe_In_Property,
    }
    @(private)
    WHITESPACE_CONTEXTUALLY_BANNED :: Parser_Flags{.Maybe_In_Property}

    Parser :: struct {
        tokenizer:               Tokenizer,
        emit_comments:           bool,
        depth:                   int,
        slashdash_depth:         int,
        child_block_at_depth:    int,
        base_state:              Parser_Base_State,
        flags:                   Parser_Flags,
        event:                   Event,
        tmp_string_type:         string, // owned: type-annotation text
        tmp_string_key:          string, // owned: node/property name text
        tmp_string_value:        string, // owned: argument/property string value text
        waiting_type_annotation: Maybe(string), // view into tmp_string_type; not separately owned
        waiting_prop_name:       string, // owned (moved out of tmp_string_value)
        next_token:              Token,
        have_next_token:         bool,
        token_location:          Location, // start of the token being processed
        waiting_prop_location:   Location, // start of waiting_prop_name
        allocator:               runtime.Allocator,
    }

    parser__init :: proc(self: ^Parser, document: string, emit_comments: bool = false, allocator := context.allocator) {
        self^ = Parser{}
        self.allocator = allocator
        tokenizer__init(&self.tokenizer, document)
        self.emit_comments = emit_comments
        self.slashdash_depth = -1
        self.child_block_at_depth = -1
    }

    parser__init_stream :: proc(self: ^Parser, reader: io.Reader, emit_comments: bool = false, allocator := context.allocator) -> runtime.Allocator_Error {
        self^ = Parser{}
        self.allocator = allocator
        tokenizer__init_stream(&self.tokenizer, reader, allocator) or_return
        self.emit_comments = emit_comments
        self.slashdash_depth = -1
        self.child_block_at_depth = -1
        return nil
    }

    parser__destroy :: proc(self: ^Parser) {
        if len(self.tmp_string_type) > 0 do delete(self.tmp_string_type, self.allocator)
        if len(self.tmp_string_key) > 0 do delete(self.tmp_string_key, self.allocator)
        if len(self.tmp_string_value) > 0 do delete(self.tmp_string_value, self.allocator)
        if len(self.waiting_prop_name) > 0 do delete(self.waiting_prop_name, self.allocator)
        tokenizer__destroy(&self.tokenizer)
        self^ = Parser{}
    }

    // Pre-fetch more data / reclaim already-consumed buffer space; see tokenizer.odin.
    // No-ops in string mode.
    parser__grow :: #force_inline proc(self: ^Parser) -> bool {
        return tokenizer__grow(&self.tokenizer)
    }
    parser__compact :: #force_inline proc(self: ^Parser) {
        tokenizer__compact(&self.tokenizer)
    }

    // Get the next parse event. The event (including any strings it references) is
    // invalidated by the next call to parser__next_event or by parser__destroy.
    parser__next_event :: proc(self: ^Parser) -> Event {
        parser__reset_event(self)

        for {
            token: Token
            if self.have_next_token {
                token = self.next_token
                self.have_next_token = false
            } else {
                tok, tstatus := tokenizer__pop_token(&self.tokenizer)
                self.token_location = self.tokenizer.location
                switch tstatus {
                case .EOF:
                    if self.base_state == .In_Node {
                        // EOF may be ok, but we have to close the node first
                        self.flags -= {.Newlines_Are_Whitespace}
                        token = Token{type = .Newline, value = "", location = self.tokenizer.location}
                    } else if self.depth > 0 {
                        return parser__set_parse_error(self, "Unexpected end of data (unclosed lists of children)")
                    } else if self.slashdash_depth > 0 {
                        return parser__set_parse_error(self, "Dangling slashdash (/-)")
                    } else if self.flags != {} {
                        return parser__set_parse_error(self, "Unexpected end of data")
                    } else {
                        self.event = Event{type = .EOF, location = self.tokenizer.location}
                        return self.event
                    }
                case .OK:
                    token = tok
                case .Error:
                    return parser__set_parse_error(self, "Parse error")
                }
            }

            self.token_location = token.location

            if token.type == .Newline && .Newlines_Are_Whitespace in self.flags {
                token.type = .Whitespace
            }

            dispatch := false

            #partial switch token.type {
            case .Whitespace:
                if .Whitespace_Required in self.flags do self.flags -= {.Whitespace_Required}
                if WHITESPACE_CONTEXTUALLY_BANNED & self.flags != {} {
                    self.flags += {.Contextually_Illegal_Whitespace}
                }
                // ignore whitespace, get the next token

            case .Multi_Line_Comment, .Single_Line_Comment:
                if .Whitespace_Required in self.flags do self.flags -= {.Whitespace_Required}
                if WHITESPACE_CONTEXTUALLY_BANNED & self.flags != {} {
                    self.flags += {.Contextually_Illegal_Whitespace}
                }
                if self.emit_comments {
                    self.event = Event{type = .Comment, value = Value{variant = token.value}, location = token.location}
                    return self.event
                }
                // else: comments are not emitted, get the next token

            case .Slashdash:
                if .Whitespace_Required in self.flags {
                    return parser__set_parse_error(self, "Whitespace required before /-")
                }
                // slashdash comments out the next node, argument, or property
                if WHITESPACE_CONTEXTUALLY_BANNED & self.flags != {} {
                    // this token should be dispatched normally - it'll come back
                    // around once the ambiguous "maybe a property key" is resolved
                    dispatch = true
                } else if NODE_CANNOT_END_HERE & self.flags != {} {
                    return parser__set_parse_error(self, "/- not allowed here")
                } else {
                    if self.slashdash_depth < 0 do self.slashdash_depth = self.depth + 1
                    self.flags += {.Newlines_Are_Whitespace}
                    // get the next token
                }

            case:
                dispatch = true
            }

            if !dispatch do continue

            self.flags -= {.Newlines_Are_Whitespace}

            emit: bool
            switch self.base_state {
            case .Outside_Node: emit = parser__next_node(self, token)
            case .In_Node:      emit = parser__next_event_in_node(self, token)
            }
            if emit do return self.event
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Private - state machine

    @(private)
    parser__reset_event :: proc(self: ^Parser) {
        self.event.name = ""
        self.event.value = Value{}
    }

    @(private)
    parser__set_parse_error :: proc(self: ^Parser, message: string) -> Event {
        self.event = Event{type = .Parse_Error, value = Value{variant = message}, location = self.token_location}
        return self.event
    }

    @(private)
    parser__apply_slashdash :: proc(self: ^Parser) -> (emit: bool) {
        if self.slashdash_depth < 0 do return true // slashdash not active: event stands as-is

        if self.slashdash_depth == self.depth + 1 do self.slashdash_depth = -1

        if self.emit_comments {
            self.event.commented_out = true
            return true
        }

        // eat this event and all its attributes
        parser__reset_event(self)
        return false
    }

    @(private)
    parser__handle_type_annotation_start :: proc(self: ^Parser, token: Token) -> (emit: bool) {
        #partial switch token.type {
        case .Word, .String, .Multiline_String, .Raw_String, .Raw_Multiline_String:
            val, ok := parser__parse_value(self, token, &self.tmp_string_type)
            if !ok {
                parser__set_parse_error(self, "Error parsing type annotation")
                return true
            }
            if s, is_string := val.variant.(string); is_string {
                self.flags = (self.flags - {.Type_Annotation_Start}) + {.Type_Annotation_End}
                self.waiting_type_annotation = s
                return false
            }
            parser__set_parse_error(self, "Expected identifier or string")
            return true
        case:
            parser__set_parse_error(self, "Unexpected token, expected type")
            return true
        }
    }

    @(private)
    parser__handle_type_annotation_end :: proc(self: ^Parser, token: Token) -> (emit: bool) {
        if token.type == .End_Type {
            self.flags = (self.flags - {.Type_Annotation_End}) + {.Type_Annotation_Ended}
            return false
        }
        parser__set_parse_error(self, "Unexpected token, expected ')'")
        return true
    }

    @(private)
    parser__next_node :: proc(self: ^Parser, token: Token) -> (emit: bool) {
        if .Type_Annotation_Start in self.flags do return parser__handle_type_annotation_start(self, token)
        if .Type_Annotation_End in self.flags do return parser__handle_type_annotation_end(self, token)

        #partial switch token.type {
        case .Newline, .Semicolon:
            if .Whitespace_Required in self.flags do self.flags -= {.Whitespace_Required}
            if NODE_CANNOT_END_HERE & self.flags != {} {
                parser__set_parse_error(self, "Unexpected end of node (incomplete node name?)")
                return true
            }
            // no open type annotation: additional newlines are allowed
            return false

        case .Start_Type:
            if self.event.value.type_annotation != nil {
                parser__set_parse_error(self, "Unexpected second type annotation")
                return true
            }
            self.flags += {.Type_Annotation_Start}
            return false

        case .Word, .String, .Multiline_String, .Raw_String, .Raw_Multiline_String:
            val, ok := parser__parse_value(self, token, &self.tmp_string_key)
            if !ok {
                parser__set_parse_error(self, "Error parsing node name")
                return true
            }
            name, is_string := val.variant.(string)
            if !is_string {
                parser__set_parse_error(self, "Expected identifier or string")
                return true
            }

            type_annotation := self.waiting_type_annotation
            self.waiting_type_annotation = nil

            self.base_state = .In_Node
            self.flags = {.Whitespace_Required}
            self.event = Event{type = .Start_Node, name = name, value = Value{type_annotation = type_annotation}, location = token.location}
            self.depth += 1
            return parser__apply_slashdash(self)

        case .End_Children:
            if self.depth == 0 {
                parser__set_parse_error(self, "Unexpected '}'")
                return true
            }
            self.base_state = .In_Node
            self.flags = {}
            self.depth -= 1
            parser__reset_event(self)
            if self.slashdash_depth < 0 {
                self.flags = {.End_Of_Node}
                self.child_block_at_depth = self.depth
            } else if self.child_block_at_depth == self.depth {
                self.flags = {.End_Of_Node}
            } else {
                self.flags = {.End_Of_Node_Or_Child_Block}
            }
            if self.slashdash_depth == self.depth + 1 do self.slashdash_depth = -1
            return false

        case .Line_Continuation:
            // line continuations do nothing outside of nodes in v2
            return false

        case:
            parser__set_parse_error(self, "Unexpected token, expected node")
            return true
        }
    }

    @(private)
    parser__next_event_in_node :: proc(self: ^Parser, token: Token) -> (emit: bool) {
        if .Line_Cont in self.flags {
            #partial switch token.type {
            case .Single_Line_Comment:
            // fine; fall through to normal handling below
            case .Newline:
                self.flags -= {.Line_Cont}
                return false
            case:
                parser__set_parse_error(self, "Illegal token after line continuation")
                return true
            }
        }

        if token.type == .Line_Continuation {
            if .Whitespace_Required in self.flags do self.flags -= {.Whitespace_Required}
            if WHITESPACE_CONTEXTUALLY_BANNED & self.flags != {} {
                self.flags += {.Contextually_Illegal_Whitespace}
            }
            self.flags += {.Line_Cont}
            return false
        }

        if .Maybe_In_Property in self.flags {
            if token.type == .Equals {
                self.flags = (self.flags - {.Maybe_In_Property}) + {.In_Property}
                self.flags -= {.Contextually_Illegal_Whitespace}
                return false
            }

            // we'll need that token again
            self.next_token = token
            self.have_next_token = true

            // not in a property: emit as an argument
            self.tmp_string_value = self.waiting_prop_name
            self.waiting_prop_name = ""
            self.event = Event{type = .Argument, value = Value{variant = self.tmp_string_value}, location = self.waiting_prop_location}

            emit = parser__apply_slashdash(self)

            new_flags: Parser_Flags
            if .Contextually_Illegal_Whitespace not_in self.flags do new_flags = {.Whitespace_Required}
            self.base_state = .In_Node
            self.flags = new_flags
            return emit
        }

        if .Type_Annotation_Start in self.flags do return parser__handle_type_annotation_start(self, token)
        if .Type_Annotation_End in self.flags do return parser__handle_type_annotation_end(self, token)

        // End-of-node cases: always valid
        end_of_node_token := false
        #partial switch token.type {
        case .End_Children:
            // end this node, and process the token again
            self.next_token = token
            self.have_next_token = true
            end_of_node_token = true
        case .Newline, .Semicolon:
            end_of_node_token = true
        }

        if end_of_node_token {
            if NODE_CANNOT_END_HERE & self.flags != {} {
                parser__set_parse_error(self, "Unexpected end of node (incomplete argument or property?)")
                return true
            }
            self.base_state = .Outside_Node
            self.flags = {}
            self.depth -= 1
            if self.child_block_at_depth > self.depth do self.child_block_at_depth = -1
            self.event = Event{type = .End_Node, location = token.location}
            return parser__apply_slashdash(self)
        }

        // Child block: valid unless we've already had a non-slashdashed child
        // block, or slashdash is active now
        if .End_Of_Node in self.flags && self.slashdash_depth < 0 {
            parser__set_parse_error(self, "Expected end of node")
            return true
        }
        if token.type == .Start_Children {
            self.base_state = .Outside_Node
            self.flags = {}
            self.depth += 1
            parser__reset_event(self)
            return false
        }

        // Args, props: only valid at the start
        if (self.flags & {.End_Of_Node, .End_Of_Node_Or_Child_Block}) != {} {
            parser__set_parse_error(self, "Expected end of node or child block")
            return true
        }

        #partial switch token.type {
        case .Word, .String, .Multiline_String, .Raw_String, .Raw_Multiline_String:
            if .Whitespace_Required in self.flags {
                parser__set_parse_error(self, "Whitespace required before argument or property")
                return true
            }

            val, ok := parser__parse_value(self, token, &self.tmp_string_value)
            if !ok {
                parser__set_parse_error(self, "Error parsing property or argument")
                return true
            }

            _, is_string := val.variant.(string)

            // Can this be a property key?
            if self.waiting_type_annotation == nil && .In_Property not_in self.flags && is_string {
                self.waiting_prop_name = self.tmp_string_value
                self.waiting_prop_location = token.location
                self.tmp_string_value = ""
                self.flags += {.Maybe_In_Property}
                return false
            }

            // This is an argument or a property value.
            ev_value := val
            if self.waiting_type_annotation != nil {
                ev_value.type_annotation = self.waiting_type_annotation
                self.waiting_type_annotation = nil
            }
            if .In_Property in self.flags {
                if len(self.tmp_string_key) > 0 do delete(self.tmp_string_key, self.allocator)
                self.tmp_string_key = self.waiting_prop_name
                self.waiting_prop_name = ""
                self.event = Event{type = .Property, name = self.tmp_string_key, value = ev_value, location = self.waiting_prop_location}
            } else {
                self.event = Event{type = .Argument, value = ev_value, location = token.location}
            }
            emit = parser__apply_slashdash(self)
            self.base_state = .In_Node
            self.flags = {.Whitespace_Required}
            return emit

        case .Start_Type:
            if .Whitespace_Required in self.flags {
                parser__set_parse_error(self, "Whitespace required before type")
                return true
            }
            if self.event.value.type_annotation != nil {
                parser__set_parse_error(self, "Unexpected second type annotation")
                return true
            }
            self.flags += {.Type_Annotation_Start}
            return false

        case:
            parser__set_parse_error(self, "Unexpected token")
            return true
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Private - value parsing

    // Parse token as a KDL value, writing any newly-allocated string content into
    // dest (which must be one of self's owned tmp_string_* fields; its previous
    // content, if any, is freed first).
    @(private)
    parser__parse_value :: proc(self: ^Parser, token: Token, dest: ^string) -> (val: Value, ok: bool) {
        if len(dest^) > 0 do delete(dest^, self.allocator)
        dest^ = ""

        #partial switch token.type {
        case .Raw_String:
            // newlines are not allowed in plain raw strings
            if contains_newline(token.value) do return {}, false
            cloned := strings.clone(token.value, self.allocator)
            dest^ = cloned
            val.variant = cloned
            return val, true

        case .Raw_Multiline_String:
            dedented, dedent_ok := dedent_multiline_string(token.value, self.allocator)
            if !dedent_ok do return {}, false
            dest^ = dedented
            val.variant = dedented
            return val, true

        case .String:
            unescaped, unesc_ok := unescape_single_line(token.value, self.allocator)
            if !unesc_ok do return {}, false
            dest^ = unescaped
            val.variant = unescaped
            return val, true

        case .Multiline_String:
            unescaped, unesc_ok := unescape_multi_line(token.value, self.allocator)
            if !unesc_ok do return {}, false
            dest^ = unescaped
            val.variant = unescaped
            return val, true

        case .Word:
            switch token.value {
            case "#null":
                return val, true
            case "#true":
                val.variant = true
                return val, true
            case "#false":
                val.variant = false
                return val, true
            case "#inf":
                n: Number = math.inf_f64(1)
                val.variant = n
                return val, true
            case "#-inf":
                n: Number = math.inf_f64(-1)
                val.variant = n
                return val, true
            case "#nan":
                n: Number = math.nan_f64()
                val.variant = n
                return val, true
            }

            // either a number or an identifier
            if len(token.value) >= 1 {
                first_char := token.value[0]
                offset := 0
                if (first_char == '+' || first_char == '-') && len(token.value) >= 2 {
                    first_char = token.value[1]
                    offset = 1
                }
                if first_char >= '0' && first_char <= '9' {
                    return parser__parse_number(self, token.value, dest)
                } else if first_char == '.' && len(token.value) - offset >= 2 {
                    // banned "almost number" (e.g. `.5abc`)
                    second_char := token.value[offset + 1]
                    if second_char >= '0' && second_char <= '9' do return {}, false
                }
            }

            // a regular identifier, or a syntax error
            if !identifier_is_valid(token.value) do return {}, false
            cloned := strings.clone(token.value, self.allocator)
            dest^ = cloned
            val.variant = cloned
            return val, true

        case:
            return {}, false
        }
    }

    @(private)
    identifier_is_valid :: proc(value: string) -> bool {
        switch value {
        case "inf", "-inf", "nan", "null", "true", "false":
            return false
        }

        remaining := value
        c, status := pop_rune(&remaining)
        if status != .OK || !is_id_start(c) do return false

        for {
            c2, s2 := pop_rune(&remaining)
            switch s2 {
            case .OK:
                if !is_id(c2) do return false
            case .EOF:
                return true
            case .Decode_Error:
                return false
            }
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Private - number parsing

    @(private)
    parser__parse_number :: proc(self: ^Parser, number: string, dest: ^string) -> (val: Value, ok: bool) {
        body := number
        if len(body) >= 1 && (body[0] == '-' || body[0] == '+') do body = body[1:]

        if len(body) > 2 && body[0] == '0' {
            switch body[1] {
            case 'x': return parser__parse_radix_number(self, number, 16, 'x', dest)
            case 'o': return parser__parse_radix_number(self, number, 8, 'o', dest)
            case 'b': return parser__parse_radix_number(self, number, 2, 'b', dest)
            }
        }
        return parser__parse_decimal_number(self, number, dest)
    }

    @(private)
    parser__parse_decimal_number :: proc(self: ^Parser, number: string, dest: ^string) -> (val: Value, ok: bool) {
        for i := 0; i < len(number); i += 1 {
            switch number[i] {
            case '.', 'e', 'E':
                return parser__parse_decimal_float(self, number, dest)
            }
        }
        return parser__parse_decimal_integer(self, number, dest)
    }

    @(private)
    parser__parse_decimal_integer :: proc(self: ^Parser, number: string, dest: ^string) -> (val: Value, ok: bool) {
        negative := false
        i := 0
        if len(number) > 1 {
            switch number[0] {
            case '-': negative = true; i = 1
            case '+': i = 1
            }
        }
        if len(number) - i > 0 && number[i] == '_' do return {}, false

        n: Bigint
        if bigint_init(&n, 0, self.allocator) != nil do return {}, false
        defer bigint_destroy(&n)

        for ; i < len(number); i += 1 {
            c := number[i]
            if c == '_' do continue
            if c < '0' || c > '9' do return {}, false
            digit := u32(c - '0')
            if bigint_multiply(&n, 10) != nil do return {}, false
            if bigint_add(&n, digit) != nil do return {}, false
        }

        return finish_integer(&n, negative, dest, self.allocator)
    }

    @(private)
    parser__parse_radix_number :: proc(self: ^Parser, number: string, radix: u32, prefix: byte, dest: ^string) -> (val: Value, ok: bool) {
        negative := false
        i := 0
        if len(number) > 1 {
            switch number[0] {
            case '-': negative = true; i = 1
            case '+': i = 1
            }
        }

        if len(number) - i < 3 || number[i] != '0' || number[i + 1] != prefix || number[i + 2] == '_' {
            return {}, false
        }
        i += 2

        n: Bigint
        if bigint_init(&n, 0, self.allocator) != nil do return {}, false
        defer bigint_destroy(&n)

        for ; i < len(number); i += 1 {
            c := number[i]
            if c == '_' do continue
            digit, digit_ok := radix_digit_value(c, radix)
            if !digit_ok do return {}, false
            if bigint_multiply(&n, radix) != nil do return {}, false
            if bigint_add(&n, digit) != nil do return {}, false
        }

        return finish_integer(&n, negative, dest, self.allocator)
    }

    @(private)
    radix_digit_value :: proc(c: byte, radix: u32) -> (digit: u32, ok: bool) {
        switch {
        case c >= '0' && c <= '9': digit = u32(c - '0')
        case c >= 'a' && c <= 'f': digit = u32(c - 'a') + 0xa
        case c >= 'A' && c <= 'F': digit = u32(c - 'A') + 0xa
        case: return 0, false
        }
        if digit >= radix do return 0, false
        return digit, true
    }

    @(private)
    finish_integer :: proc(n: ^Bigint, negative: bool, dest: ^string, allocator := context.allocator) -> (val: Value, ok: bool) {
        if i64_val, fits := bigint_as_i64(n); fits {
            if negative do i64_val = -i64_val
            num: Number = i64_val
            val.variant = num
            return val, true
        }
        s, err := bigint_to_decimal_string(n, negative, allocator)
        if err != nil do return {}, false
        dest^ = s
        num: Number = s
        val.variant = num
        return val, true
    }

    @(private)
    parser__parse_decimal_float :: proc(self: ^Parser, number: string, dest: ^string) -> (val: Value, ok: bool) {
        Float_State :: enum {
            Before_Decimal,
            After_Decimal_No_Digit,
            After_Decimal,
            Exponent_No_Digit,
            Exponent,
        }

        negative := false
        digits_before_decimal := 0
        digits_after_decimal := 0
        decimal_mantissa: u64 = 0
        explicit_exponent := 0
        exponent_negative := false
        state := Float_State.Before_Decimal

        i := 0
        if len(number) > 1 {
            switch number[0] {
            case '-': negative = true; i = 1
            case '+': i = 1
            }
        }
        if len(number) - i > 0 && number[i] == '_' do return {}, false

        for ; i < len(number); i += 1 {
            c := number[i]
            switch {
            case c == '.' && state == .Before_Decimal:
                state = .After_Decimal_No_Digit
                if len(number) - i <= 1 || number[i + 1] == '_' do return {}, false

            case (c == 'e' || c == 'E') && state != .Exponent && state != .After_Decimal_No_Digit:
                state = .Exponent_No_Digit
                if i + 1 < len(number) {
                    switch number[i + 1] {
                    case '-': exponent_negative = true; i += 1
                    case '+': i += 1
                    }
                    if len(number) - i <= 1 || number[i + 1] == '_' do return {}, false
                }

            case c >= '0' && c <= '9':
                digit := u64(c - '0')
                if state == .Exponent || state == .Exponent_No_Digit {
                    state = .Exponent
                    if explicit_exponent < 285 do explicit_exponent = explicit_exponent * 10 + int(digit)
                } else {
                    decimal_mantissa = decimal_mantissa * 10 + digit
                    if state == .Before_Decimal {
                        digits_before_decimal += 1
                    } else {
                        state = .After_Decimal
                        digits_after_decimal += 1
                    }
                }

            case c == '_':
            // underscores are allowed

            case:
                return {}, false
            }
        }

        if state == .After_Decimal_No_Digit || state == .Exponent_No_Digit do return {}, false

        // rough heuristic for numbers that fit into a double exactly
        if digits_before_decimal + digits_after_decimal <= 15 && explicit_exponent < 285 && explicit_exponent > -285 {
            for decimal_mantissa % 10 == 0 && digits_after_decimal > 0 {
                decimal_mantissa /= 10
                digits_after_decimal -= 1
            }
            n := f64(decimal_mantissa)
            if negative do n = -n
            if exponent_negative do explicit_exponent = -explicit_exponent
            net_exponent := explicit_exponent - digits_after_decimal
            if net_exponent < 0 do n /= math.pow(f64(10.0), f64(-net_exponent))
            if net_exponent > 0 do n *= math.pow(f64(10.0), f64(net_exponent))

            num: Number = n
            val.variant = num
            return val, true
        }

        // Remove underscores and the initial '+', keep the digits as a string-encoded number
        sb: strings.Builder
        if _, err := strings.builder_init(&sb, self.allocator); err != nil do return {}, false
        p := number
        if len(p) > 0 && p[0] == '+' do p = p[1:]
        for k := 0; k < len(p); k += 1 {
            if p[k] != '_' do strings.write_byte(&sb, p[k])
        }
        s := strings.to_string(sb)
        dest^ = s
        num: Number = s
        val.variant = num
        return val, true
    }

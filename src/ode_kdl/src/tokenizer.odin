/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    Tokenizer — turns KDL v2 source text into a stream of tokens. Ported
    from ckdl's src/tokenizer.c, v2-only (no kdl_character_set, no KDLv1
    raw-string 'r"..."' prefix).

    Supports both whole-string input (tokenizer__init) and streaming input
    from an io.Reader (tokenizer__init_stream). Every scan position used
    while popping one token is a byte offset *relative to self.pos* (the
    start of that token), not an absolute buffer index — tokenizer__grow
    never moves self.pos, and tokenizer__compact only ever drops bytes
    before it, so a relative offset survives any number of grows/compactions
    without the caller having to recompute it (unlike ckdl's own C, which
    has to re-derive every raw pointer after each buffer refill).
*/
package kdl

// Base
    import "base:runtime"

// Core
    import "core:io"

///////////////////////////////////////////////////////////////////////////////
// Token

    Token_Type :: enum u8 {
        Start_Type,           // '('
        End_Type,             // ')'
        Word,                 // identifier, number, boolean, or null
        String,               // regular string
        Multiline_String,     // multi-line string
        Raw_String,           // raw string: #"..."#
        Raw_Multiline_String, // raw multi-line string
        Single_Line_Comment,  // // ...
        Slashdash,            // /-
        Multi_Line_Comment,   // /* ... */
        Equals,               // '='
        Start_Children,       // '{'
        End_Children,         // '}'
        Newline,              // LF, CR, or CRLF
        Semicolon,            // ';'
        Line_Continuation,    // '\\'
        Whitespace,           // any regular whitespace
    }

    // Source position; line and column are 1-based, column counts code points.
    Location :: struct {
        offset: int, // bytes from the start of the document
        line:   int,
        column: int,
    }

    Token :: struct {
        type:     Token_Type,
        value:    string,
        location: Location, // where the token starts
    }

    Tokenizer_Status :: enum u8 {
        OK,
        EOF,
        Error,
    }

///////////////////////////////////////////////////////////////////////////////
// Tokenizer

    Tokenizer :: struct {
        document:     []byte,        // string mode: the caller's string, reinterpreted; stream mode: owned_buffer[:]
        pos:          int,           // start of the unconsumed region within document
        reader:       io.Reader,     // zero Stream (procedure == nil) in string mode
        owned_buffer: [dynamic]byte, // backing storage in stream mode; nil in string mode
        allocator:    runtime.Allocator,
        location:     Location,      // position of pos
        after_cr:     bool,          // last consumed rune was CR, so a following LF is not a new line
    }

    tokenizer__init :: proc(self: ^Tokenizer, document: string) {
        self^ = Tokenizer{}
        self.location = Location{line = 1, column = 1}
        self.document = transmute([]byte)document
        tokenizer__skip_bom(self)
    }

    tokenizer__init_stream :: proc(self: ^Tokenizer, reader: io.Reader, allocator := context.allocator) -> runtime.Allocator_Error {
        self^ = Tokenizer{}
        self.location = Location{line = 1, column = 1}
        self.reader = reader
        self.allocator = allocator
        self.owned_buffer = make([dynamic]byte, 0, STREAM_REFILL_SIZE, allocator) or_return
        self.document = self.owned_buffer[:]
        tokenizer__skip_bom(self)
        return nil
    }

    tokenizer__destroy :: proc(self: ^Tokenizer) {
        if self.owned_buffer != nil do delete(self.owned_buffer)
        self^ = Tokenizer{}
    }

    // Reads one more chunk via self.reader and appends it; never compacts. Returns false
    // at true EOF (always false in string mode). Called automatically when a scan runs
    // out of buffered bytes, and directly callable to pre-fetch data.
    tokenizer__grow :: proc(self: ^Tokenizer) -> bool {
        if self.reader.procedure == nil do return false

        old_len := len(self.owned_buffer)
        resize(&self.owned_buffer, old_len + STREAM_REFILL_SIZE)
        n, _ := io.read(self.reader, self.owned_buffer[old_len:])
        resize(&self.owned_buffer, old_len + max(n, 0))
        self.document = self.owned_buffer[:]
        return n > 0
    }

    // Drops the already-consumed prefix, reclaiming its memory. Never called
    // automatically — safe to call any time between pop_token/next_event calls.
    tokenizer__compact :: proc(self: ^Tokenizer) {
        if self.owned_buffer == nil || self.pos == 0 do return

        n := len(self.owned_buffer) - self.pos
        copy(self.owned_buffer[:n], self.owned_buffer[self.pos:])
        resize(&self.owned_buffer, n)
        self.pos = 0
        self.document = self.owned_buffer[:]
    }

    tokenizer__pop_token :: proc(self: ^Tokenizer) -> (token: Token, status: Tokenizer_Status) {
        start := self.location
        token, status = tokenizer__pop_token_at(self)
        token.location = start
        return
    }

    @(private)
    tokenizer__pop_token_at :: proc(self: ^Tokenizer) -> (token: Token, status: Tokenizer_Status) {
        c, cur, ustatus := tokenizer__get_char(self, 0)
        switch ustatus {
        case .OK:
        case .EOF: return {}, .EOF
        case .Decode_Error: return {}, .Error
        }

        switch {
        case is_illegal_char(c):
            return {}, .Error

        case is_whitespace(c):
            for {
                c2, next2, s2 := tokenizer__get_char(self, cur)
                if s2 != .OK || !is_whitespace(c2) do break
                cur = next2
            }
            return Token{type = .Whitespace, value = tokenizer__take(self, cur)}, .OK

        case is_newline(c):
            if c == '\r' {
                c2, next2, s2 := tokenizer__get_char(self, cur)
                if s2 == .OK && c2 == '\n' do cur = next2
            }
            return Token{type = .Newline, value = tokenizer__take(self, cur)}, .OK

        case c == ';':
            return Token{type = .Semicolon, value = tokenizer__take(self, cur)}, .OK

        case c == '\\':
            return Token{type = .Line_Continuation, value = tokenizer__take(self, cur)}, .OK

        case c == '(':
            return Token{type = .Start_Type, value = tokenizer__take(self, cur)}, .OK

        case c == ')':
            return Token{type = .End_Type, value = tokenizer__take(self, cur)}, .OK

        case c == '{':
            return Token{type = .Start_Children, value = tokenizer__take(self, cur)}, .OK

        case c == '}':
            return Token{type = .End_Children, value = tokenizer__take(self, cur)}, .OK

        case c == '=':
            return Token{type = .Equals, value = tokenizer__take(self, cur)}, .OK

        case c == '/':
            return tokenizer__pop_comment(self)

        case c == '"':
            return tokenizer__pop_string(self)

        case is_word_char(c):
            if c == '#' {
                // this *could* be a raw string
                if tok, st := tokenizer__pop_string(self); st == .OK do return tok, st
                // else: parse this as an identifier instead (which may also fail)
            }
            return tokenizer__pop_word(self)

        case:
            return {}, .Error
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    tokenizer__skip_bom :: proc(self: ^Tokenizer) {
        c, next, status := tokenizer__get_char(self, 0)
        if status == .OK && c == 0xFEFF {
            self.pos = next
            self.location.offset = next
        }
    }

    // Byte-level, refill-aware "get next char" — the choke point every scan loop
    // calls through. rel is relative to self.pos.
    @(private)
    tokenizer__get_char :: proc(self: ^Tokenizer, rel: int) -> (r: rune, next_rel: int, status: Utf8_Status) {
        for {
            r2, next_abs, cs := peek_codepoint(self.document, self.pos + rel)
            switch cs {
            case .OK:            return r2, next_abs - self.pos, .OK
            case .Decode_Error:  return r2, next_abs - self.pos, .Decode_Error
            case .EOF:
                if !tokenizer__grow(self) do return 0, rel, .EOF
            case .Incomplete:
                if !tokenizer__grow(self) do return 0, rel, .Decode_Error
            }
        }
    }

    @(private)
    tokenizer__slice :: #force_inline proc(self: ^Tokenizer, a: int, b: int) -> string {
        return string(self.document[self.pos + a : self.pos + b])
    }

    // Slices document[0:rel] (relative to self.pos) and advances self.pos past it.
    @(private)
    tokenizer__take :: proc(self: ^Tokenizer, rel: int) -> string {
        value := tokenizer__slice(self, 0, rel)
        tokenizer__advance(self, rel)
        return value
    }

    // Moves pos forward by rel bytes, updating the line/column counters.
    @(private)
    tokenizer__advance :: proc(self: ^Tokenizer, rel: int) {
        end := self.pos + rel
        for i := self.pos; i < end; {
            r: rune
            next := i + 1
            if b := self.document[i]; b < 0x80 {
                r = rune(b)
            } else {
                r2, next_abs, _ := peek_codepoint(self.document, i)
                r = r2
                if next_abs > i do next = next_abs
            }

            switch {
            case r == '\n' && self.after_cr:
                self.after_cr = false
            case is_newline(r):
                self.location.line += 1
                self.location.column = 1
                self.after_cr = r == '\r'
            case:
                self.location.column += 1
                self.after_cr = false
            }
            i = next
        }
        self.location.offset += rel
        self.pos = end
    }

    @(private)
    tokenizer__pop_word :: proc(self: ^Tokenizer) -> (token: Token, status: Tokenizer_Status) {
        cur := 0
        for {
            c, next, s := tokenizer__get_char(self, cur)
            if s == .EOF do break
            if s == .Decode_Error do return {}, .Error
            if is_end_of_word(c) do break
            if !is_word_char(c) do return {}, .Error
            cur = next
        }
        return Token{type = .Word, value = tokenizer__take(self, cur)}, .OK
    }

    @(private)
    tokenizer__pop_comment :: proc(self: ^Tokenizer) -> (token: Token, status: Tokenizer_Status) {
        c1, after_slash, s1 := tokenizer__get_char(self, 0)
        if s1 != .OK do return {}, .Error
        c2, after_c2, s2 := tokenizer__get_char(self, after_slash)
        if s2 != .OK do return {}, .Error
        assert(c1 == '/')

        switch c2 {
        case '-':
            return Token{type = .Slashdash, value = tokenizer__take(self, after_c2)}, .OK

        case '/':
            cur := after_c2
            for {
                c, next, s := tokenizer__get_char(self, cur)
                if s == .EOF do break
                if s == .Decode_Error do return {}, .Error
                if is_illegal_char(c) do return {}, .Error
                if is_newline(c) do break
                cur = next
            }
            return Token{type = .Single_Line_Comment, value = tokenizer__take(self, cur)}, .OK

        case '*':
            cur := after_c2
            depth := 1
            prev_char: rune = 0
            for depth > 0 {
                c, next, s := tokenizer__get_char(self, cur)
                if s != .OK do return {}, .Error // EOF or error inside a comment is always an error
                if is_illegal_char(c) do return {}, .Error
                if c == '*' && prev_char == '/' {
                    depth += 1
                    c = 0 // "/*/" doesn't count as self-closing
                } else if c == '/' && prev_char == '*' {
                    depth -= 1
                    c = 0 // "*/*" doesn't count as reopening
                }
                prev_char = c
                cur = next
            }
            return Token{type = .Multi_Line_Comment, value = tokenizer__take(self, cur)}, .OK

        case:
            return {}, .Error
        }
    }

    @(private)
    tokenizer__pop_string :: proc(self: ^Tokenizer) -> (token: Token, status: Tokenizer_Status) {
        cur := 0
        is_raw := false

        c, _, s := tokenizer__get_char(self, cur)
        if s != .OK do return {}, .Error
        switch c {
        case '#':
            is_raw = true
        // cur unchanged: the hash-counting loop below re-reads this same '#'
        case '"':
        // cur unchanged: the quote-counting loop below re-reads this same quote
        case:
            return {}, .Error
        }

        // count the hashes (raw strings only)
        hashes := 0
        for is_raw {
            c2, next2, s2 := tokenizer__get_char(self, cur)
            if s2 != .OK do return {}, .Error // eof or error in a string is always an error
            if c2 == '#' {
                hashes += 1
                cur = next2
            } else if c2 == '"' {
                break
            } else {
                return {}, .Error
            }
        }

        // count the opening quotes (1 = regular string, 3 = multi-line string)
        initial_quote_count := 0
        for initial_quote_count < 3 {
            c3, next3, s3 := tokenizer__get_char(self, cur)
            if s3 == .EOF {
                if !is_raw && initial_quote_count == 2 {
                    // "" followed immediately by EOF: an empty regular string
                    tokenizer__advance(self, cur)
                    return Token{type = .String, value = ""}, .OK
                }
                return {}, .Error
            }
            if s3 != .OK do return {}, .Error
            if c3 == '"' {
                initial_quote_count += 1
                cur = next3
            } else {
                break
            }
        }

        if initial_quote_count == 2 {
            // overshot: this is an empty single-quoted string; back off by one quote
            cur -= 1
            initial_quote_count = 1
        }

        string_start := cur

        // scan the string body
        hashes_found := 0
        quotes_found := 0
        end_quote_offset := 0
        prev_char: rune = 0
        end_position := 0

        find_end: for {
            c4, next4, s4 := tokenizer__get_char(self, cur)
            if s4 != .OK do return {}, .Error // eof or error in a string is always an error

            if is_illegal_char(c4) {
                return {}, .Error
            } else if !is_raw && c4 == '\\' && prev_char == '\\' {
                c4 = 0 // double backslash is no backslash
                quotes_found, hashes_found = 0, 0
                end_quote_offset = 0
            } else if c4 == '"' && (is_raw || prev_char != '\\') {
                if quotes_found == 0 do end_quote_offset = cur
                if quotes_found < initial_quote_count {
                    quotes_found += 1
                } else {
                    // possibly extra quotes at the end of a raw string
                    end_quote_offset += 1
                }
                hashes_found = 0
            } else if c4 == '#' && (hashes_found != 0 || quotes_found == initial_quote_count) {
                hashes_found += 1
                quotes_found = 0
            } else {
                quotes_found, hashes_found = 0, 0
                end_quote_offset = 0
            }

            if end_quote_offset != 0 &&
               ((hashes == 0 && quotes_found == initial_quote_count) ||
                (hashes != 0 && hashes_found == hashes)) {
                end_position = next4
                break find_end
            }

            prev_char = c4
            cur = next4
        }

        value := tokenizer__slice(self, string_start, end_quote_offset)
        tokenizer__advance(self, end_position)

        tok_type: Token_Type
        switch {
        case initial_quote_count == 3: tok_type = is_raw ? .Raw_Multiline_String : .Multiline_String
        case is_raw:                   tok_type = .Raw_String
        case:                          tok_type = .String
        }
        return Token{type = tok_type, value = value}, .OK
    }

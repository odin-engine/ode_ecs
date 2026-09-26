/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    kdl_tokenize — dumps a KDL v2 document's raw token stream, one KDL node
    per token: the node's name is the Token_Type case name (via
    reflect.enum_string, so it can't drift from the enum) and its single
    argument is the token's raw text.

    Drives cmd/kdl_tokenize (the CLI).
*/
package kdl_tokenize

// Core
    import "core:io"
    import "core:reflect"

// ODE
    import kdl "../src"

///////////////////////////////////////////////////////////////////////////////
// Tokenize

    // Tokenize reader as KDL v2 and write one node per token to writer. Returns
    // false on a tokenizer or emitter error.
    tokenize_stream :: proc(reader: io.Reader, writer: io.Writer, allocator := context.allocator) -> bool {
        tokenizer: kdl.Tokenizer
        if kdl.init(&tokenizer, reader, allocator) != nil do return false
        defer kdl.destroy(&tokenizer)

        emitter: kdl.Emitter
        kdl.init(&emitter, writer, allocator = allocator)
        defer kdl.destroy(&emitter)

        for {
            token, status := kdl.pop_token(&tokenizer)
            switch status {
            case .Error:
                kdl.emit_end(&emitter)
                return false
            case .EOF:
                return kdl.emit_end(&emitter)
            case .OK:
                if !kdl.emit_node(&emitter, reflect.enum_string(token.type)) do return false
                if !kdl.emit_arg(&emitter, kdl.Value{variant = token.value}) do return false
            }
        }
    }

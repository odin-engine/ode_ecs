/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    A KDL v2 document-language parser/emitter, ported from ckdl
    (https://github.com/tjol/ckdl) into Odin.

    This file is the public API surface: short aliases for the
    `Tokenizer`/`Parser`/`Emitter` typename__action procedures defined in
    tokenizer.odin, parser.odin, and emitter.odin. See CLAUDE.md for the
    architecture and the deliberate differences from upstream ckdl (v2
    only, no CLI/bindings beyond kdl-cat).
*/
package kdl

///////////////////////////////////////////////////////////////////////////////
// Defines

    // Bytes read per tokenizer__grow call in stream mode.
    STREAM_REFILL_SIZE :: #config(KDL_STREAM_REFILL_SIZE, 4096)

///////////////////////////////////////////////////////////////////////////////
// Aliases
//

    //
    // Tokenizer
    //
        pop_token :: tokenizer__pop_token

    //
    // Parser
    //
        next_event :: parser__next_event

    //
    // Emitter
    //
        emit_node                :: emitter__emit_node
        emit_node_with_type      :: emitter__emit_node_with_type
        emit_arg                 :: emitter__emit_arg
        emit_property             :: emitter__emit_property
        start_emitting_children  :: emitter__start_emitting_children
        finish_emitting_children :: emitter__finish_emitting_children
        emit_end                 :: emitter__emit_end
        get_buffer                :: emitter__get_buffer

    //
    // init/destroy - overloaded across Tokenizer, Parser, Emitter
    //
        init :: proc {
            tokenizer__init,
            tokenizer__init_stream,
            parser__init,
            parser__init_stream,
            emitter__init,
            emitter__init_stream,
        }

        destroy :: proc {
            tokenizer__destroy,
            parser__destroy,
            emitter__destroy,
        }

    //
    // Stream buffer control - see tokenizer.odin. No-ops in string mode.
    //
        grow :: proc {
            tokenizer__grow,
            parser__grow,
        }

        compact :: proc {
            tokenizer__compact,
            parser__compact,
        }

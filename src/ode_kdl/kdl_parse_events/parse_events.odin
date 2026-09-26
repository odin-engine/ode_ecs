/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    kdl_parse_events — dumps a KDL v2 document's parser event stream, one KDL
    node per event: the node's name is the Event_Type case name (via
    reflect.enum_string), type-annotated `(commented-out)` when the event's
    commented_out flag is set (replacing ckdl's bit-flag event encoding, which
    this port already unpacks into that bool field). A "name" property is
    attached only for Start_Node/Property, the only event types that carry one
    in this grammar; a "value" property is always attached.

    Drives cmd/kdl_parse_events (the CLI).
*/
package kdl_parse_events

// Core
    import "core:io"
    import "core:reflect"

// ODE
    import kdl "../src"

///////////////////////////////////////////////////////////////////////////////
// Parse events

    // Parse reader as KDL v2 and write one node per parser event to writer.
    // Returns false on a parse or emit error.
    parse_events_stream :: proc(reader: io.Reader, writer: io.Writer, emit_comments := false, allocator := context.allocator) -> bool {
        parser: kdl.Parser
        if kdl.init(&parser, reader, emit_comments, allocator) != nil do return false
        defer kdl.destroy(&parser)

        emitter: kdl.Emitter
        kdl.init(&emitter, writer, allocator = allocator)
        defer kdl.destroy(&emitter)

        for {
            ev := kdl.next_event(&parser)
            event_name := reflect.enum_string(ev.type)

            emitted: bool
            if ev.commented_out {
                emitted = kdl.emit_node_with_type(&emitter, "commented-out", event_name)
            } else {
                emitted = kdl.emit_node(&emitter, event_name)
            }
            if !emitted do return false

            if ev.type == .Start_Node || ev.type == .Property {
                if !kdl.emit_property(&emitter, "name", kdl.Value{variant = ev.name}) do return false
            }
            if !kdl.emit_property(&emitter, "value", ev.value) do return false

            if ev.type == .Parse_Error {
                kdl.emit_end(&emitter)
                return false
            }
            if ev.type == .EOF {
                return kdl.emit_end(&emitter)
            }
        }
    }

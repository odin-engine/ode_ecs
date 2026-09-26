/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)
*/
package kdl_tests

// Core
    import "core:testing"
    import "core:fmt"

// ODE
    import kdl "../src"

@(test)
smoke_round_trip :: proc(t: ^testing.T) {
    doc := "node1 \"arg\" prop=1 {\n    child\n}\n"

    parser: kdl.Parser
    kdl.init(&parser, doc)
    defer kdl.destroy(&parser)

    emitter: kdl.Emitter
    err := kdl.init(&emitter)
    testing.expect(t, err == nil)
    defer kdl.destroy(&emitter)

    in_node_list := true

    for {
        ev := kdl.next_event(&parser)
        switch ev.type {
        case .EOF:
            ok := kdl.emit_end(&emitter)
            testing.expect(t, ok)
            out := kdl.get_buffer(&emitter)
            fmt.println(out)
            testing.expect(t, len(out) > 0)
            return
        case .Parse_Error:
            msg, _ := ev.value.variant.(string)
            testing.expectf(t, false, "parse error: %s", msg)
            return
        case .Start_Node:
            if !in_node_list {
                ok := kdl.start_emitting_children(&emitter)
                testing.expect(t, ok)
            }
            ok := kdl.emit_node(&emitter, ev.name)
            testing.expect(t, ok)
            in_node_list = false
        case .End_Node:
            if in_node_list {
                ok := kdl.finish_emitting_children(&emitter)
                testing.expect(t, ok)
            }
            in_node_list = true
        case .Argument:
            ok := kdl.emit_arg(&emitter, ev.value)
            testing.expect(t, ok)
        case .Property:
            ok := kdl.emit_property(&emitter, ev.name, ev.value)
            testing.expect(t, ok)
        case .Comment:
        // not emitted in this test (emit_comments is off)
        }
    }
}

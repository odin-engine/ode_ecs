/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    kdl_cat — parses a KDL v2 document and re-emits it in canonical form.
    Ported from ckdl's src/utils/ckdl-cat.c: a node's properties are
    de-duplicated (last value wins) and sorted lexically by name before
    being written out, since KDL properties are semantically a map, not
    an ordered list.

    Drives both cmd/kdl_cat (the CLI) and tests/conformance_test.odin
    (which diffs its output against the upstream KDL test corpus).
*/
package kdl_cat

// Core
    import "core:io"
    import "core:slice"
    import "core:strings"

// ODE
    import kdl "../src"

///////////////////////////////////////////////////////////////////////////////
// Cat

    Options :: struct {
        emitter_opt: kdl.Emitter_Options,
    }

    DEFAULT_OPTIONS :: Options{
        emitter_opt = kdl.DEFAULT_EMITTER_OPTIONS,
    }

    // Parse doc as KDL v2 and re-emit it in canonical form. Returns ("", false) on
    // any parse or emit failure. The returned string is allocated with allocator.
    cat :: proc(doc: string, opt: Options = DEFAULT_OPTIONS, allocator := context.allocator) -> (result: string, ok: bool) {
        parser: kdl.Parser
        kdl.init(&parser, doc, false, allocator)
        defer kdl.destroy(&parser)

        emitter: kdl.Emitter
        if kdl.init(&emitter, opt.emitter_opt, allocator) != nil do return "", false
        defer kdl.destroy(&emitter)

        if !cat_events(&parser, &emitter, allocator) do return "", false
        return strings.clone(kdl.get_buffer(&emitter), allocator), true
    }

    // Same as cat, but reads/writes incrementally via io.Reader/io.Writer instead of
    // building the whole document/output in memory. Matches upstream ckdl-cat, which
    // already streams. Call kdl.compact(&parser) between events to bound memory.
    cat_stream :: proc(reader: io.Reader, writer: io.Writer, opt: Options = DEFAULT_OPTIONS, allocator := context.allocator) -> bool {
        parser: kdl.Parser
        if kdl.init(&parser, reader, false, allocator) != nil do return false
        defer kdl.destroy(&parser)

        emitter: kdl.Emitter
        kdl.init(&emitter, writer, opt.emitter_opt, allocator)
        defer kdl.destroy(&emitter)

        return cat_events(&parser, &emitter, allocator)
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    Prop :: struct {
        name:  string,
        value: kdl.Value,
    }

    @(private)
    cat_events :: proc(parser: ^kdl.Parser, emitter: ^kdl.Emitter, allocator := context.allocator) -> bool {
        in_node_list := true
        props := make([dynamic]Prop, allocator)
        defer delete(props)

        for {
            ev := kdl.next_event(parser)
            #partial switch ev.type {
            case .EOF:
                return kdl.emit_end(emitter)

            case .Parse_Error:
                return false

            case .Start_Node:
                if !in_node_list {
                    if !emit_props(emitter, &props) do return false
                    if !kdl.start_emitting_children(emitter) do return false
                }
                emitted: bool
                if ta, has_ta := ev.value.type_annotation.?; has_ta {
                    emitted = kdl.emit_node_with_type(emitter, ta, ev.name)
                } else {
                    emitted = kdl.emit_node(emitter, ev.name)
                }
                if !emitted do return false
                in_node_list = false

            case .End_Node:
                if in_node_list {
                    if !kdl.finish_emitting_children(emitter) do return false
                } else {
                    if !emit_props(emitter, &props) do return false
                }
                in_node_list = true

            case .Argument:
                if !kdl.emit_arg(emitter, ev.value) do return false

            case .Property:
                append(&props, Prop{name = ev.name, value = ev.value})

            case:
                return false
            }
        }
    }

    // Emit properties in lexical order by name, keeping only the last occurrence
    // of each duplicate name (properties are a map, not an ordered list). Clears
    // props on return.
    @(private)
    emit_props :: proc(emitter: ^kdl.Emitter, props: ^[dynamic]Prop) -> bool {
        defer clear(props)

        slice.stable_sort_by(props[:], proc(a, b: Prop) -> bool { return a.name < b.name })

        ok := true
        n := len(props)
        for i := 0; i < n; i += 1 {
            if i + 1 < n && props[i].name == props[i + 1].name do continue // shadowed by a later duplicate
            if !kdl.emit_property(emitter, props[i].name, props[i].value) do ok = false
        }
        return ok
    }

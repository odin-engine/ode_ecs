/*
    2026 (c) Oleh, https://github.com/zm69

    Tests for source locations on parser events, in string and stream mode.
*/
package kdl_tests

// Core
    import "core:testing"

// ODE
    import kdl "../src"

@(private = "file")
Loc_Expect :: struct {
    type:   kdl.Event_Type,
    line:   int,
    column: int,
}

@(private = "file")
LOC_DOC :: "a 1\nb \"x\"  key=2\r\n  c {\n    d #true\n  }\n\"multi\" \"\"\"\n  line\n  \"\"\" 5\n"

@(private = "file")
LOC_EXPECTED := []Loc_Expect{
    {.Start_Node, 1, 1}, {.Argument, 1, 3}, {.End_Node, 1, 4},
    {.Start_Node, 2, 1}, {.Argument, 2, 3}, {.Property, 2, 8}, {.End_Node, 2, 13},
    {.Start_Node, 3, 3},
    {.Start_Node, 4, 5}, {.Argument, 4, 7}, {.End_Node, 4, 12},
    {.End_Node, 5, 4},
    {.Start_Node, 6, 1}, {.Argument, 6, 9}, {.Argument, 8, 7}, {.End_Node, 8, 8},
    {.EOF, 9, 1},
}

@(private = "file")
expect_locations :: proc(t: ^testing.T, parser: ^kdl.Parser, expected: []Loc_Expect) {
    for e, i in expected {
        ev := kdl.next_event(parser)
        testing.expectf(t, ev.type == e.type, "event %d: type %v, expected %v", i, ev.type, e.type)
        testing.expectf(t, ev.location.line == e.line && ev.location.column == e.column,
            "event %d (%v): at %d:%d, expected %d:%d", i, ev.type, ev.location.line, ev.location.column, e.line, e.column)
    }
}

@(test)
locations_in_string_mode :: proc(t: ^testing.T) {
    parser: kdl.Parser
    kdl.init(&parser, LOC_DOC)
    defer kdl.destroy(&parser)

    expect_locations(t, &parser, LOC_EXPECTED)
}

@(test)
locations_in_stream_mode_one_byte_chunks :: proc(t: ^testing.T) {
    cr := chunked_reader_make(LOC_DOC, 1)
    parser: kdl.Parser
    testing.expect(t, kdl.init(&parser, chunked_reader_to_reader(&cr)) == nil)
    defer kdl.destroy(&parser)

    expect_locations(t, &parser, LOC_EXPECTED)
}

@(test)
location_offset_skips_bom :: proc(t: ^testing.T) {
    parser: kdl.Parser
    kdl.init(&parser, "\uFEFFa\nb\n")
    defer kdl.destroy(&parser)

    ev := kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Start_Node)
    testing.expect_value(t, ev.location, kdl.Location{offset = 3, line = 1, column = 1})

    kdl.next_event(&parser) // End_Node
    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.name, "b")
    testing.expect_value(t, ev.location, kdl.Location{offset = 5, line = 2, column = 1})
}

@(test)
location_of_parse_error :: proc(t: ^testing.T) {
    parser: kdl.Parser
    kdl.init(&parser, "node }\n")
    defer kdl.destroy(&parser)

    expect_locations(t, &parser, []Loc_Expect{{.Start_Node, 1, 1}, {.End_Node, 1, 6}, {.Parse_Error, 1, 6}})
}

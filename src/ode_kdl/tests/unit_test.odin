/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    Targeted unit tests for behavior the corpus-driven conformance test
    (conformance_test.odin) doesn't exercise: kdl_cat always parses with
    emit_comments off, so it never touches the Comment event path or the
    slashdash "commented_out" flag. Bigint overflow into the string-encoded
    Number case is also only lightly exercised by the corpus.
*/
package kdl_tests

// Core
    import "core:fmt"
    import "core:strings"
    import "core:testing"

// ODE
    import kdl "../src"

@(test)
comment_events_are_emitted_when_enabled :: proc(t: ^testing.T) {
    doc := "// leading comment\nnode 1 /- 2\n"

    parser: kdl.Parser
    kdl.init(&parser, doc, true) // emit_comments = true
    defer kdl.destroy(&parser)

    ev := kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Comment)
    comment_text, is_str := ev.value.variant.(string)
    testing.expect(t, is_str)
    testing.expect_value(t, comment_text, "// leading comment")

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Start_Node)
    testing.expect_value(t, ev.name, "node")

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Argument)
    n1, n1_ok := ev.value.variant.(kdl.Number)
    testing.expect(t, n1_ok)
    i1, i1_ok := n1.(i64)
    testing.expect(t, i1_ok)
    testing.expect_value(t, i1, i64(1))

    // the slashdashed argument still comes through as an event, flagged commented_out
    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Argument)
    testing.expect(t, ev.commented_out)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.End_Node)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.EOF)
}

@(test)
integer_beyond_i64_becomes_string_encoded :: proc(t: ^testing.T) {
    doc := "node 99999999999999999999999999\n"

    parser: kdl.Parser
    kdl.init(&parser, doc)
    defer kdl.destroy(&parser)

    ev := kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Start_Node)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Argument)
    n, n_ok := ev.value.variant.(kdl.Number)
    testing.expect(t, n_ok)
    s, s_ok := n.(string)
    testing.expect(t, s_ok)
    testing.expect_value(t, s, "99999999999999999999999999")
}

@(test)
integer_within_i64_stays_an_integer :: proc(t: ^testing.T) {
    doc := "node -1234567890\n"

    parser: kdl.Parser
    kdl.init(&parser, doc)
    defer kdl.destroy(&parser)

    ev := kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Start_Node)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Argument)
    n, n_ok := ev.value.variant.(kdl.Number)
    testing.expect(t, n_ok)
    i, i_ok := n.(i64)
    testing.expect(t, i_ok)
    testing.expect_value(t, i, i64(-1234567890))
}

@(test)
empty_string_type_annotation_is_distinct_from_none :: proc(t: ^testing.T) {
    doc := "(\"\")node\n"

    parser: kdl.Parser
    kdl.init(&parser, doc)
    defer kdl.destroy(&parser)

    ev := kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Start_Node)
    ta, has_ta := ev.value.type_annotation.?
    testing.expect(t, has_ta)
    testing.expect_value(t, ta, "")
}

@(test)
parse_error_is_reported_and_terminal :: proc(t: ^testing.T) {
    doc := "node =\n" // '=' with no preceding property name is a syntax error

    parser: kdl.Parser
    kdl.init(&parser, doc)
    defer kdl.destroy(&parser)

    ev := kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Start_Node)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Parse_Error)
    msg, msg_ok := ev.value.variant.(string)
    testing.expect(t, msg_ok)
    testing.expect(t, len(msg) > 0)
}

@(test)
streaming_matches_string_mode :: proc(t: ^testing.T) {
    doc := "node1 \"arg\" prop=42 (Type)child {\n    inner \"nested string\"\n}\n"

    parser_str: kdl.Parser
    kdl.init(&parser_str, doc)
    defer kdl.destroy(&parser_str)

    reader := chunked_reader_make(doc, 1)
    parser_stream: kdl.Parser
    err := kdl.init(&parser_stream, chunked_reader_to_reader(&reader))
    testing.expect(t, err == nil)
    defer kdl.destroy(&parser_stream)

    for {
        ev_str := kdl.next_event(&parser_str)
        ev_stream := kdl.next_event(&parser_stream)
        testing.expect_value(t, ev_stream.type, ev_str.type)
        testing.expect_value(t, ev_stream.name, ev_str.name)
        testing.expect_value(t, ev_stream.commented_out, ev_str.commented_out)
        testing.expect_value(t, ev_stream.value, ev_str.value)
        if ev_str.type == .EOF || ev_str.type == .Parse_Error do break
    }
}

// Forces a 2-byte UTF-8 rune ('é') across a chunk boundary, exercising Codepoint_Status.Incomplete.
@(test)
streaming_splits_multibyte_rune_across_reads :: proc(t: ^testing.T) {
    doc := "café\n"

    reader := chunked_reader_make(doc, 1)
    parser: kdl.Parser
    err := kdl.init(&parser, chunked_reader_to_reader(&reader))
    testing.expect(t, err == nil)
    defer kdl.destroy(&parser)

    ev := kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Start_Node)
    testing.expect_value(t, ev.name, "café")

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.End_Node)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.EOF)
}

// A single string argument spans many tokenizer__grow calls; kdl.compact between events
// proves compaction right before/after a big scan doesn't disturb it.
@(test)
long_token_survives_growth_and_manual_compaction :: proc(t: ^testing.T) {
    inner := strings.repeat("x", 5000)
    defer delete(inner)
    doc := fmt.tprintf("node \"%s\"\n", inner)

    reader := chunked_reader_make(doc, 4)
    parser: kdl.Parser
    err := kdl.init(&parser, chunked_reader_to_reader(&reader))
    testing.expect(t, err == nil)
    defer kdl.destroy(&parser)

    ev := kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Start_Node)
    kdl.compact(&parser)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.Argument)
    s, s_ok := ev.value.variant.(string)
    testing.expect(t, s_ok)
    testing.expect_value(t, len(s), 5000)
    kdl.compact(&parser)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.End_Node)

    ev = kdl.next_event(&parser)
    testing.expect_value(t, ev.type, kdl.Event_Type.EOF)
}

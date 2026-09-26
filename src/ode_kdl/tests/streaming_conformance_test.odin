/*
    Runs the same upstream corpus as conformance_test.odin, but through
    kdl_cat.cat_stream fed by a Chunked_Reader(1) — proving the streaming
    tokenizer (growing its buffer one byte at a time) reproduces the
    whole-string parser's behavior exactly, across the full KDL v2 spec
    test suite.
*/
package kdl_tests

// Core
    import "core:os"
    import "core:strings"
    import "core:testing"

// ODE
    import kdl "../src"
    import kdl_cat "../kdl_cat"

@(test)
streaming_conformance_v2 :: proc(t: ^testing.T) {
    opt := kdl_cat.Options{
        emitter_opt = kdl.Emitter_Options{
            indent          = 4,
            escape_mode     = kdl.ESCAPE_DEFAULT,
            identifier_mode = .Prefer_Bare,
            float_mode      = kdl.Float_Printing_Options{
                always_write_decimal_point             = true,
                always_write_decimal_point_or_exponent = true,
                capital_e                               = true,
                exponent_plus                           = true,
                plus                                    = false,
                min_exponent                            = 4,
            },
        },
    }

    input_dir := strings.concatenate({CORPUS_DIR, "/input"})
    defer delete(input_dir)
    expected_dir := strings.concatenate({CORPUS_DIR, "/expected_kdl"})
    defer delete(expected_dir)

    handle, open_err := os.open(input_dir)
    if !testing.expectf(t, open_err == nil, "could not open corpus dir %s: %v", input_dir, open_err) {
        return
    }
    defer os.close(handle)

    entries, read_err := os.read_dir(handle, -1, context.allocator)
    if !testing.expectf(t, read_err == nil, "could not list corpus dir: %v", read_err) {
        return
    }
    defer os.file_info_slice_delete(entries, context.allocator)

    tested := 0

    for entry in entries {
        if entry.type == .Directory do continue
        name := entry.name

        is_fuzzy := false
        for fuzzy in FUZZY_CASES {
            if name == fuzzy {
                is_fuzzy = true
                break
            }
        }

        input_path := strings.concatenate({input_dir, "/", name})
        defer delete(input_path)

        input_bytes, in_err := os.read_entire_file_from_path(input_path, context.allocator)
        if !testing.expectf(t, in_err == nil, "%s: could not read input: %v", name, in_err) do continue
        defer delete(input_bytes)

        reader := chunked_reader_make(string(input_bytes), 1)

        out_sb: strings.Builder
        strings.builder_init(&out_sb, context.allocator)
        defer strings.builder_destroy(&out_sb)

        parse_ok := kdl_cat.cat_stream(chunked_reader_to_reader(&reader), strings.to_writer(&out_sb), opt)
        result := strings.to_string(out_sb)

        expected_path := strings.concatenate({expected_dir, "/", name})
        defer delete(expected_path)

        expected_bytes, exp_err := os.read_entire_file_from_path(expected_path, context.allocator)
        has_expected := exp_err == nil
        defer if has_expected do delete(expected_bytes)

        tested += 1

        if !has_expected {
            testing.expectf(t, !parse_ok, "%s: expected a parse failure, but it parsed successfully", name)
            continue
        }

        if !testing.expectf(t, parse_ok, "%s: expected to parse successfully, but got a parse error", name) {
            continue
        }

        if is_fuzzy do continue

        expected_str := string(expected_bytes)
        matches := result == expected_str ||
            (len(expected_str) == 1 && expected_str[0] == '\n' && len(result) == 0)
        testing.expectf(t, matches, "%s: streaming output mismatch\n--- got ---\n%s\n--- want ---\n%s", name, result, expected_str)
    }

    testing.expectf(t, tested > 300, "expected to run over 300 corpus cases, ran %d - is the corpus vendored?", tested)
}

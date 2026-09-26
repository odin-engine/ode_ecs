/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)
*/
package kdl_tests

// Core
    import "core:strings"
    import "core:testing"

// ODE
    import kdl_tokenize "../kdl_tokenize"

@(test)
kdl_tokenize_smoke :: proc(t: ^testing.T) {
    doc := "node1 \"arg\" prop=1 {\n    child\n}\n"

    out_sb: strings.Builder
    strings.builder_init(&out_sb, context.allocator)
    defer strings.builder_destroy(&out_sb)

    reader: strings.Reader
    ok := kdl_tokenize.tokenize_stream(strings.to_reader(&reader, doc), strings.to_writer(&out_sb))
    testing.expect(t, ok)
    testing.expect(t, strings.builder_len(out_sb) > 0)
}

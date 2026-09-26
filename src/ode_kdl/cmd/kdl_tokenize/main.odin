/*
    2026 (c) Oleh, https://github.com/zm69

    kdl-tokenize CLI: reads a KDL v2 document (from a file argument, or
    stdin) and dumps its raw token stream, one KDL node per token.
    Thin wrapper over the kdl_tokenize package; see kdl_tokenize/tokenize.odin.
*/
package main

// Core
    import "core:fmt"
    import "core:os"

// ODE
    import kdl_tokenize "../../kdl_tokenize"

main :: proc() {
    in_file := os.stdin

    if len(os.args) > 1 {
        f, err := os.open(os.args[1])
        if err != nil {
            fmt.eprintfln("Error opening file \"%s\": %v", os.args[1], err)
            os.exit(1)
        }
        in_file = f
    }
    defer if in_file != os.stdin do os.close(in_file)

    ok := kdl_tokenize.tokenize_stream(os.to_reader(in_file), os.to_writer(os.stdout))
    if !ok {
        os.exit(1)
    }
}

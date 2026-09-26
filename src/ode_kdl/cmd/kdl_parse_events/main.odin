/*
    2026 (c) Oleh, https://github.com/zm69

    kdl-parse-events CLI: reads a KDL v2 document (from a file argument, or
    stdin) and dumps its parser event stream, one KDL node per event.
    Thin wrapper over the kdl_parse_events package; see
    kdl_parse_events/parse_events.odin.
*/
package main

// Core
    import "core:fmt"
    import "core:os"

// ODE
    import kdl_parse_events "../../kdl_parse_events"

print_usage :: proc(fp: ^os.File) {
    fmt.fprintfln(fp, "Usage: %s [-h] [-c] [file]", os.args[0])
    fmt.fprintln(fp, "")
    fmt.fprintln(fp, "    -h    Print usage information")
    fmt.fprintln(fp, "    -c    Emit comments")
}

main :: proc() {
    in_file := os.stdin
    emit_comments := false

    for arg in os.args[1:] {
        switch arg {
        case "-h":
            print_usage(os.stdout)
            os.exit(0)
        case "-c":
            emit_comments = true
        case:
            f, err := os.open(arg)
            if err != nil {
                fmt.eprintfln("Error opening file \"%s\": %v", arg, err)
                os.exit(1)
            }
            in_file = f
        }
    }
    defer if in_file != os.stdin do os.close(in_file)

    ok := kdl_parse_events.parse_events_stream(os.to_reader(in_file), os.to_writer(os.stdout), emit_comments)
    if !ok {
        os.exit(1)
    }
}

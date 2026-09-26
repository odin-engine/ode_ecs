# ODE_KDL

A [KDL v2](https://kdl.dev) document-language tokenizer, pull-parser, and emitter for Odin, ported from the C library [ckdl](https://github.com/tjol/ckdl).

Validated against the official upstream KDL 2.0.0 test suite (319 cases, vendored in `tests/test_documents/upstream/2.0.0/`) — see `tests/conformance_test.odin`.

## Install

>‼️ This is an embedded version of ODE_KDL for ODE_ECS (to avoid dealing with submodules or separate git repos).

>‼️ For the standalone version, please check [https://github.com/odin-engine/ode_kdl](https://github.com/odin-engine/ode_kdl).

## Parsing

`Parser` is a pull parser: each call to `next_event` returns the next `Event` in the document.

```odin
package example

import "core:fmt"
import kdl "ode_kdl/src"

main :: proc() {
    doc := `
    package "ode_kdl" version="0.1.0" {
        dependency "odin" version=">=dev-2026-01"
    }
    `

    parser: kdl.Parser
    kdl.init(&parser, doc)
    defer kdl.destroy(&parser)

    for {
        ev := kdl.next_event(&parser)
        switch ev.type {
        case .Start_Node:
            fmt.println("node:", ev.name)
        case .Argument:
            fmt.println("  arg:", ev.value)
        case .Property:
            fmt.println("  prop:", ev.name, "=", ev.value)
        case .End_Node:
            // nothing to do here in this example
        case .Comment:
            // only produced when kdl.init is called with emit_comments = true
        case .Parse_Error:
            msg, _ := ev.value.variant.(string)
            fmt.eprintln("parse error:", msg)
            return
        case .EOF:
            return
        }
    }
}
```

`Value.variant` is a plain Odin union — `bool`, `Number` (itself `union{i64, f64, string}`, string covering integers too large for `i64`), or `string`; `nil` represents KDL's `#null`. `Value.type_annotation` is a `Maybe(string)` — `nil` means no annotation, `Some("")` means an explicit empty-string annotation (`("")node`), which is legal KDL and distinct from having none.

## Emitting

`Emitter` builds a document back up from the same events:

```odin
emitter: kdl.Emitter
kdl.init(&emitter) // or kdl.init(&emitter, kdl.DEFAULT_EMITTER_OPTIONS)
defer kdl.destroy(&emitter)

kdl.emit_node(&emitter, "package")
kdl.emit_property(&emitter, "version", kdl.Value{variant = "0.1.0"})
kdl.emit_end(&emitter)

fmt.println(kdl.get_buffer(&emitter))
```

## Streaming

`Tokenizer`/`Parser` can read from an `io.Reader` instead of a whole `string`, and `Emitter` can write to an `io.Writer` instead of building a `strings.Builder` — so a document never has to be fully in memory before parsing starts:

```odin
f, _ := os.open("big.kdl")
defer os.close(f)

parser: kdl.Parser
kdl.init(&parser, os.to_reader(f))
defer kdl.destroy(&parser)

for {
    ev := kdl.next_event(&parser)
    if ev.type == .EOF || ev.type == .Parse_Error do break
    // ... handle ev ...
    kdl.compact(&parser) // optional: reclaim already-consumed buffer space
}
```

The buffer only grows when parsing needs more bytes; it's never compacted on its own. Call `kdl.compact` yourself, whenever you judge it worthwhile, to bound memory — a caller who never calls it just gets a buffer that grows to hold the whole document. `kdl.grow` is also directly callable, e.g. to pre-fetch data before a burst of parsing. `emitter__init_stream`/`kdl.init(&emitter, some_writer)` works the same way for output.

## kdl-cat

`kdl_cat/cat.odin` reformats a whole document to canonical form (properties de-duplicated and sorted lexically per node, matching ckdl's `ckdl-cat`), and ships as a small CLI:

```sh
odin build cmd/kdl_cat -out:cmd/kdl_cat/out/kdl_cat.exe -debug
./cmd/kdl_cat/out/kdl_cat.exe path/to/file.kdl
```

## kdl-tokenize / kdl-parse-events

`kdl_tokenize/tokenize.odin` dumps a document's raw token stream, and `kdl_parse_events/parse_events.odin` dumps its parser event stream — each as one KDL node per token/event, named after the Odin `Token_Type`/`Event_Type` enum case (e.g. `Word`, `Start_Node`), ported from ckdl's `ckdl-tokenize`/`ckdl-parse-events`:

```sh
odin build cmd/kdl_tokenize -out:cmd/kdl_tokenize/out/kdl_tokenize.exe -debug
./cmd/kdl_tokenize/out/kdl_tokenize.exe path/to/file.kdl

odin build cmd/kdl_parse_events -out:cmd/kdl_parse_events/out/kdl_parse_events.exe -debug
./cmd/kdl_parse_events/out/kdl_parse_events.exe [-c] path/to/file.kdl
```

## Scope

This is a v2-only port of ckdl's core library — see `CLAUDE.md` for the full list of deliberate differences from upstream (no KDL v1, no C++/Python bindings).

## Testing

```sh
cd tests && odin test . -debug -o:none -define:ODIN_TEST_THREADS=1
```

/*
    Test-only io.Reader that yields at most chunk_size bytes per read, to
    force the streaming tokenizer through many grow calls even for small
    documents (and to let tests split a UTF-8 sequence across two reads).
*/
package kdl_tests

// Core
    import "core:io"

Chunked_Reader :: struct {
    data:       string,
    pos:        int,
    chunk_size: int,
}

chunked_reader_make :: proc(data: string, chunk_size: int) -> Chunked_Reader {
    return Chunked_Reader{data = data, chunk_size = chunk_size}
}

chunked_reader_to_reader :: proc(cr: ^Chunked_Reader) -> io.Reader {
    return io.Reader{procedure = chunked_reader_proc, data = cr}
}

@(private = "file")
chunked_reader_proc :: proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
    cr := (^Chunked_Reader)(stream_data)
    #partial switch mode {
    case .Read:
        remaining := len(cr.data) - cr.pos
        if remaining <= 0 do return 0, .EOF
        to_copy := min(len(p), cr.chunk_size, remaining)
        copy(p[:to_copy], cr.data[cr.pos:][:to_copy])
        cr.pos += to_copy
        return i64(to_copy), nil
    case .Query:
        return i64(io.Stream_Mode_Set{.Read}), nil
    case:
        return 0, .Empty
    }
}

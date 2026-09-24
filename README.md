# PicoHTTPParser.jl

[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://AbrJA.github.io/PicoHTTPParser.jl/dev)
[![Build Status](https://github.com/AbrJA/PicoHTTPParser.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/AbrJA/PicoHTTPParser.jl/actions/workflows/CI.yml?query=branch%3Amaster)

A minimal, high-performance Julia wrapper around the [picohttpparser](https://github.com/h2o/picohttpparser) C library.

This package provides extremely fast HTTP parsing by using **zero-copy `StringView`s**. Instead of allocating new Strings for every header name and value, it returns views into the original unmodified buffer, significantly reducing GC pressure and memory usage.

## 🚀 Features

- **Zero-Copy Parsing**: Uses `StringViews.jl` to return views into your buffer.
- **Streaming / Incremental Support**: Parse requests as they arrive in chunks without rescanning.
- **Chunked Transfer Decoding**: High-performance in-place chunked decoding.
- **Battle-Tested Backend**: Bindings to the widely used `picohttpparser` C library.

## 📦 Installation

```julia
pkg> add PicoHTTPParser
```

## 🧩 Usage Examples

```julia
using PicoHTTPParser
```

### Basic Request Parsing

> **Note**: Input must be a `Vector{UInt8}`. The returned `Request` object holds views into this buffer, so you must keep the buffer alive while using the request.

```julia
# Create a mutable buffer (Vector{UInt8})
data = """GET /index.html HTTP/1.1\r
Host: example.com\r
User-Agent: Julia\r
\r
""" |> Vector{UInt8}

# Parse the request
# parse_request(buf, last_len; max_headers)
req = parse_request(data)

@show req.method        # "GET" (StringView)
@show req.path          # "/index.html"
@show req.minor_version # 1
@show req.headers       # Vector{Pair{StringView, StringView}}
@show req.body          # SubArray (View of the body)
```

### Streaming / Incremental Parsing

If you receive data in chunks (e.g., disjoint TCP reads), you can use the `last_len` parameter to tell the parser where you left off. This prevents rescanning bytes that were already confirmed to be part of an incomplete header section.

```julia
# 1. Initialize a buffer
buf = Vector{UInt8}()
prev_len = 0

# 2. Receive Part 1 (Incomplete)
part1 = "GET /async HTTP/1.1\r\nUser-A"
append!(buf, Vector{UInt8}(part1))

# Try to parse. Pass prev_len (0 initially).
req = parse_request(buf, prev_len)
# req === nothing (Incomplete)

# Update prev_len so we don't rescan the first part
prev_len = length(buf)

# 3. Receive Part 2 (Complete)
part2 = "gent: Julia\r\n\r\n"
append!(buf, Vector{UInt8}(part2))

# Parse again from where we left off
req = parse_request(buf, prev_len)

if req !== nothing
    println("Parsed: $(req.method) $(req.path)")
end
```

### Allocation-Free Incremental Head Parsing (`parse_request_head!`)

For servers, `parse_request_head!` parses only the request line and headers with
caller-owned scratch space, so steady-state parsing performs **zero allocations**.
It reports `:partial` / `:done` / `:error`, supports `last_len` incremental
scanning, and exposes headers lazily as views.

```julia
using PicoHTTPParser

hb = HeaderBuffer(64)          # reuse one per worker thread
buf = Vector{UInt8}("GET /items/42 HTTP/1.1\r\nHost: example.com\r\n\r\n")

@show parse_request_head!(hb, buf)   # :done
@show is_done(hb)                    # true
@show head_method(hb, buf)           # "GET"
@show head_path(hb, buf)             # "/items/42"
@show head_header_len(hb)            # header block length
@show get_header(hb, buf, "host")    # "example.com"

for i in 1:header_count(hb)
    @show header_name(hb, i, buf) => header_value(hb, i, buf)
end
```

Body framing (Content-Length / chunked) is the caller's responsibility; the head
parser never touches body bytes. Use `last_len` to avoid rescanning a prefix that
was already known incomplete.

### Chunked Transfer Decoding

`decode_chunked!` decodes **in place**: chunk metadata is removed and the decoded
data is compacted to the front of the buffer. The result reports explicit state
(`:partial`, `:done`, `:error`), the decoded length, and any bytes left after the
terminal chunk (for example a pipelined request).

```julia
# "Wiki" encoded in chunks: "4\r\nWiki\r\n0\r\n\r\n"
raw_chunked = "4\r\nWiki\r\n0\r\n\r\n" |> Vector{UInt8}
decoder = ChunkedDecoder()

# Modifies 'raw_chunked' in-place!
result = decode_chunked!(decoder, raw_chunked)

@show is_done(result)                             # true
@show String(decoded_data(result, raw_chunked))   # "Wiki"
@show result.leftover                             # 0
```

For fragmented input, call `decode_chunked!` again with the newly arrived bytes;
the decoder keeps the framing state. When `is_done(result)`, hand the decoder a
fresh buffer for the next message. Bytes after the terminal chunk are reported as
`leftover` (accessible with `leftover_data(result, buf)`), which enables
pipelining.

## ⚙️ Contributing

Any contributions are welcome!

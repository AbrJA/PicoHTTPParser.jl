# PicoHTTPParser

A minimal, high-performance Julia wrapper around the
[picohttpparser](https://github.com/h2o/picohttpparser) C library.

Parsing is **zero-copy**: the method, request target, header names/values, and
body are returned as views into the caller's `Vector{UInt8}`, so steady-state
parsing allocates nothing. Request heads, response heads, and standalone field
sections (for example chunked trailers) share the same machinery.

## Installation

```julia
pkg> add PicoHTTPParser
```

## Quick start

```julia
using PicoHTTPParser
using PicoHTTPParser: header   # generic name, not exported

buf = Vector{UInt8}("GET /items/42 HTTP/1.1\r\nHost: example.com\r\n\r\n")
req = parse_request(buf)

req.method          # "GET"
req.target          # "/items/42"
req.minor_version   # 1
header(req, "host") # "example.com"
```

Keep `buf` alive while the result is in use. `parse_request` returns `nothing`
for partial input and throws [`HTTPParseError`](@ref) for malformed input. Body
framing in the whole-message API is `Content-Length` only: `Transfer-Encoding`
is rejected with `ArgumentError`, so pair
[`parse_request_head!`](@ref) with [`decode_chunked!`](@ref) for chunked bodies.

## Streaming heads (zero allocation)

Reuse one [`HeaderBuffer`](@ref) per worker thread (it is not thread-safe). After
`:done`, the accessors resolve views by offset, so the buffer may be appended to
and reallocated while the result is in use.

```julia
using PicoHTTPParser
using PicoHTTPParser: header

hb = HeaderBuffer(64)
buf = Vector{UInt8}("POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nHello")

parse_request_head!(hb, buf)  # :done (or :partial / :error)
request_method(hb, buf)       # "POST"
request_target(hb, buf)       # "/submit"
head_length(hb)               # length of request line + header section
length(hb)                    # number of header fields
hb[1, buf]                    # "Host" => "example.com"
header(hb, buf, "host")       # "example.com"
content_length(hb, buf)       # 5 (nothing if absent)
```

`content_length` rejects duplicate fields and any value that is not `1*DIGIT`;
obs-fold continuation lines surface as headers with an empty name. Accessors
validate the last parse: reading, for example, `status_code` after a request head
throws `ArgumentError`.

## Responses and field sections

```julia
hb = HeaderBuffer(64)

resp = Vector{UInt8}("HTTP/1.1 204 No Content\r\nServer: Pico\r\n\r\n")
parse_response_head!(hb, resp)  # :done
status_code(hb)                 # 204
reason_phrase(hb, resp)         # "No Content"

trailer = Vector{UInt8}("Expires: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n")
parse_headers!(hb, trailer)     # :done
header(hb, trailer, "expires")
```

## Chunked transfer decoding

```julia
decoder = ChunkedDecoder()
buf = Vector{UInt8}("4\r\nWiki\r\n0\r\n\r\n")

result = decode_chunked!(decoder, buf)  # modifies buf in place
isdone(result)
String(decoded(result, buf))            # "Wiki"
result.leftover                         # bytes after the terminal chunk
```

See the [API reference](api.md) for all functions.

## Contributing

Any contributions are welcome!

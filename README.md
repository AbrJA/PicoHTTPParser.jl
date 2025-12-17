# PicoHTTPParser.jl

[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://AbrJA.github.io/PicoHTTPParser.jl/dev)
[![Build Status](https://github.com/AbrJA/PicoHTTPParser.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/AbrJA/PicoHTTPParser.jl/actions/workflows/CI.yml?query=branch%3Amain)
A minimal, high-performance Julia wrapper around the [picohttpparser](https://github.com/h2o/picohttpparser) C library.
This package provides extremely fast HTTP request/response/headers parsing and chunked transfer decoding through a clean Julia interface.

## 🚀 Features

- Parse **HTTP requests**, **responses**, and **headers** efficiently
- Thin, zero-copy bindings to the C library via `ccall`
- Built on top of [`PicoHTTPParser_jll`](https://github.com/JuliaBinaryWrappers/PicoHTTPParser_jll.jl)

## 📦 Installation

```julia
pkg> add PicoHTTPParser
```

## 🧩 Usage Examples

```julia
using PicoHTTPParser
```

### Parse request

```julia
message = """GET /index.html HTTP/1.1\r
Host: example.com\r
User-Agent: TestClient/1.0\r
Accept: */*\r
\r
"""

result = parse_request(message)

@show result.method
@show result.path
@show result.minor_version
@show result.headers
@show String(result.body)
```

Output:

```julia
result.method = "GET"
result.path = "/index.html"
result.minor_version = 1
result.headers = Dict("Host" => "example.com", "Accept" => "*/*", "User-Agent" => "TestClient/1.0")
String(result.body) = ""
```

### Parse response

```julia
message = """HTTP/1.1 200 OK\r
Content-Type: text/plain\r
Content-Length: 5\r
\r
Hello""" |> Vector{UInt8}

result = parse_response(message)

@show result.status_code
@show result.minor_version
@show result.headers
@show result.reason
@show String(result.body)
```

Output:

```julia
result.status_code = 200
result.minor_version = 1
result.headers = Dict("Content-Length" => "5", "Content-Type" => "text/plain")
result.reason = "OK"
String(result.body) = "Hello"
```

### Parse headers

```julia
message = """Host: example.com\r
User-Agent: curl/7.68.0\r
\r
"""

result = parse_headers(message)

@show result
```

Output:

```julia
result = Dict("Host" => "example.com", "User-Agent" => "curl/7.68.0")
```

### Decode chunked

```julia
message = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
decoder = ChunkedDecoder()
result = decode_chunked!(decoder, message)

@show result.done
@show String(result.data)
```

Output:

```julia
result.done = true
String(result.data) = "Wikipedia"
```

## ⚙️ Contributing

Any contributions are welcome!

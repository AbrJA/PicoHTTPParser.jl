module PicoHTTPParser

using PicoHTTPParser_jll
using StringViews

# NOTE: `header` and `headers` are intentionally not exported: they are generic
# names that collide with framework APIs (for example Ciro.header). Use them
# qualified, or opt in with `using PicoHTTPParser: header, headers`.
export parse_request, parse_response, parse_headers,
       parse_request_head!, parse_response_head!, parse_headers!,
       HeaderBuffer, isdone, ispartial, iserror,
       head_length, minor_version, request_method, request_target,
       status_code, reason_phrase, content_length,
       header_name, header_value,
       ChunkedDecoder, decode_chunked!, decoded, leftover,
       HTTPParseError

abstract type HTTPMessage end

"""
    HTTPParseError

Thrown by [`parse_request`](@ref), [`parse_response`](@ref), and
[`parse_headers`](@ref) when the input is malformed, and by
[`content_length`](@ref) for invalid or duplicate `Content-Length` fields. The
`result` field holds the raw return code from the underlying picohttpparser
call (`-1` for framing errors detected in Julia).
"""
struct HTTPParseError <: Exception
    result::Int
    message::String
end

Base.showerror(io::IO, e::HTTPParseError) =
    print(io, e.message, " (phr result = ", e.result, ")")

const BufferView = StringView{SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}}

"""
    Request

A parsed HTTP request with zero-copy views into the original buffer.
The `Request` object keeps the original buffer alive.
"""
struct Request <: HTTPMessage
    method::BufferView
    target::BufferView
    minor_version::Int
    headers::Vector{Pair{BufferView,BufferView}}
    body::SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}
end

"""
    Response

A parsed HTTP response with zero-copy views into the original buffer.
"""
struct Response <: HTTPMessage
    status_code::Int
    reason_phrase::BufferView
    minor_version::Int
    headers::Vector{Pair{BufferView,BufferView}}
    body::SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}
end

struct RawHeader
    name::Ptr{Cchar}
    name_len::Csize_t
    value::Ptr{Cchar}
    value_len::Csize_t
end

"""
    isequal_ascii(a, b) -> Bool

Allocation-free ASCII case-insensitive comparison. HTTP tokens and header names
are ASCII by definition; non-ASCII bytes compare exactly.
"""
function isequal_ascii(a::AbstractString, b::AbstractString)
    ncodeunits(a) == ncodeunits(b) || return false
    @inbounds for i in 1:ncodeunits(b)
        ca = codeunit(a, i)
        cb = codeunit(b, i)
        ca_lower = UInt8('A') <= ca <= UInt8('Z') ? ca | 0x20 : ca
        cb_lower = UInt8('A') <= cb <= UInt8('Z') ? cb | 0x20 : cb
        ca_lower == cb_lower || return false
    end
    return true
end

# ── Allocation-free, offset-safe message-head parsing ───────────────────────

"""
    HeaderBuffer([max_headers::Integer=64])

Caller-owned scratch space for the `parse_*!` functions. Reuse one per worker
thread (parsing is synchronous; a `HeaderBuffer` is not thread-safe).

The last parse result is stored in the buffer and exposed through accessors
(`request_method`, `request_target`, `status_code`, `reason_phrase`,
`head_length`, `minor_version`, `length`, `header`, `headers`,
`content_length`).

Header names and values are exposed lazily as views into the input buffer, so
that buffer must stay alive. Views are resolved by offset, so the buffer may be
appended to (and reallocated) after parsing, as long as it is not shrunk below
the parsed region.
"""
mutable struct HeaderBuffer
    raw::Vector{RawHeader}
    n::Int
    kind::Symbol           # :none | :request | :response | :fields
    parse_status::Symbol   # :none | :partial | :done | :error
    header_len::Int
    result::Cint
    # Offsets relative to the buffer base at parse time. The input buffer may be
    # appended to (and reallocated) between parsing the head and consuming it
    # (streaming bodies), so absolute pointers would dangle.
    base::Ptr{Cchar}
    method_off::Int
    method_len::Csize_t
    target_off::Int
    target_len::Csize_t
    minor_version::Cint
    status_code::Cint
    reason_off::Int
    reason_len::Csize_t
end

function HeaderBuffer(max_headers::Integer=64)
    max_headers > 0 || throw(ArgumentError("max_headers must be positive"))
    return HeaderBuffer(Vector{RawHeader}(undef, max_headers), 0, :none, :none, 0, 0,
                        C_NULL, 0, 0, 0, 0, 0, 0, 0, 0)
end

"""Clear every result field so a reused buffer never exposes stale garbage."""
@inline function _begin_parse!(hb::HeaderBuffer, kind::Symbol)
    hb.n = 0
    hb.kind = kind
    hb.parse_status = :none
    hb.header_len = 0
    hb.result = 0
    hb.base = C_NULL
    hb.method_off = 0
    hb.method_len = 0
    hb.target_off = 0
    hb.target_len = 0
    hb.minor_version = 0
    hb.status_code = 0
    hb.reason_off = 0
    hb.reason_len = 0
    return hb
end

@inline function _view_at(buf::Vector{UInt8}, base::Ptr{Cchar}, ptr::Ptr{Cchar}, len::Csize_t)::BufferView
    if ptr == C_NULL
        # picohttpparser reports obsolete line folding (obs-fold) as a header
        # with a NULL name; surface it as an empty-name view.
        len == 0 || error("NULL pointer with non-zero length")
        return StringView(view(buf, 1:0))
    end
    start_idx = Int(UInt(ptr) - UInt(base)) + 1
    end_idx = start_idx + Int(len) - 1
    (start_idx < 1 || end_idx > length(buf)) &&
        error("parsed view falls outside of buffer bounds")
    return StringView(view(buf, start_idx:end_idx))
end

@inline function _store_head!(hb::HeaderBuffer, buf::Vector{UInt8}, ret::Cint, n::Int,
                              method_ptr::Ptr{Cchar}, method_len::Csize_t,
                              target_ptr::Ptr{Cchar}, target_len::Csize_t,
                              minor_version::Cint)
    b = pointer(buf)
    hb.n = n
    hb.parse_status = :done
    hb.header_len = Int(ret)
    hb.result = ret
    hb.base = b
    hb.method_off = Int(UInt(method_ptr) - UInt(b))
    hb.method_len = method_len
    hb.target_off = Int(UInt(target_ptr) - UInt(b))
    hb.target_len = target_len
    hb.minor_version = minor_version
    return :done
end

"""
    parse_request_head!(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0) -> Symbol

Parse only the request line and headers; the body is never touched (body
framing is the caller's responsibility). Returns `:partial` when the head is
incomplete, `:error` when the request is malformed or has more than
`length(hb.raw)` headers, and `:done` when the full head is present.

Nothing is allocated: the result lives in `hb`. After `:done`, use
[`request_method`](@ref), [`request_target`](@ref), [`head_length`](@ref),
[`minor_version`](@ref), `length(hb)`, `hb[i, buf]`, [`header`](@ref), and
[`headers`](@ref); [`content_length`](@ref) gives the validated framing length.

`prev_len` is the number of bytes already scanned in a previous call, so
incremental callers do not rescan the buffer prefix.

Returned views point into `buf`; keep it alive and unmodified until consumed.
"""
function parse_request_head!(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0)::Symbol
    _begin_parse!(hb, :request)
    # Locals (not fields): ccall can elide stack refs that never escape.
    raw = hb.raw
    method_ptr = Ref{Ptr{Cchar}}(C_NULL)
    method_len = Ref{Csize_t}(0)
    target_ptr = Ref{Ptr{Cchar}}(C_NULL)
    target_len = Ref{Csize_t}(0)
    minor_version = Ref{Cint}(0)
    num_headers = Ref{Csize_t}(length(raw))

    ret = GC.@preserve buf raw ccall((:phr_parse_request, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
         Ref{Ptr{Cchar}}, Ref{Csize_t},
         Ref{Ptr{Cchar}}, Ref{Csize_t},
         Ref{Cint}, Ptr{RawHeader}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        method_ptr, method_len,
        target_ptr, target_len,
        minor_version,
        pointer(raw), num_headers,
        prev_len)

    if ret < 0
        hb.parse_status = ret == -2 ? :partial : :error
        hb.result = ret
        return hb.parse_status
    end

    return _store_head!(hb, buf, ret, Int(num_headers[]),
                        method_ptr[], method_len[],
                        target_ptr[], target_len[],
                        minor_version[])
end

"""
    parse_response_head!(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0) -> Symbol

Parse only the status line and headers of a response. Returns `:partial`,
`:error`, or `:done`; after `:done`, use [`status_code`](@ref),
[`reason_phrase`](@ref), [`head_length`](@ref), [`minor_version`](@ref), and the
header accessors. Body framing is the caller's responsibility.

`prev_len` is the number of bytes already scanned in a previous call.
"""
function parse_response_head!(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0)::Symbol
    _begin_parse!(hb, :response)
    raw = hb.raw
    minor_version = Ref{Cint}(0)
    status = Ref{Cint}(0)
    reason_ptr = Ref{Ptr{Cchar}}(C_NULL)
    reason_len = Ref{Csize_t}(0)
    num_headers = Ref{Csize_t}(length(raw))

    ret = GC.@preserve buf raw ccall((:phr_parse_response, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
         Ref{Cint}, Ref{Cint},
         Ref{Ptr{Cchar}}, Ref{Csize_t},
         Ptr{RawHeader}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        minor_version, status,
        reason_ptr, reason_len,
        pointer(raw), num_headers,
        prev_len)

    if ret < 0
        hb.parse_status = ret == -2 ? :partial : :error
        hb.result = ret
        return hb.parse_status
    end

    b = pointer(buf)
    hb.n = Int(num_headers[])
    hb.parse_status = :done
    hb.header_len = Int(ret)
    hb.result = ret
    hb.base = b
    hb.minor_version = minor_version[]
    hb.status_code = status[]
    hb.reason_off = Int(UInt(reason_ptr[]) - UInt(b))
    hb.reason_len = reason_len[]
    return :done
end

"""
    parse_headers!(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0) -> Symbol

Incrementally parse a standalone field section (for example chunked trailers).
Returns `:partial`, `:error`, or `:done`; after `:done`, inspect it with
`length(hb)`, `hb[i, buf]`, [`header`](@ref), and [`headers`](@ref).

`request_method`, `request_target`, `status_code`, and `reason_phrase` are not
set by this function.
"""
function parse_headers!(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0)::Symbol
    _begin_parse!(hb, :fields)
    raw = hb.raw
    num_headers = Ref{Csize_t}(length(raw))

    ret = GC.@preserve buf raw ccall((:phr_parse_headers, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t, Ptr{RawHeader}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        pointer(raw), num_headers,
        prev_len)

    if ret < 0
        hb.parse_status = ret == -2 ? :partial : :error
        hb.result = ret
        return hb.parse_status
    end

    hb.n = Int(num_headers[])
    hb.parse_status = :done
    hb.header_len = Int(ret)
    hb.result = ret
    hb.base = pointer(buf)
    return :done
end

# ── Result accessors ────────────────────────────────────────────────────────

@inline function _require_done(hb::HeaderBuffer, what::String)
    hb.parse_status === :done ||
        throw(ArgumentError("$what requires a completed parse (status: $(hb.parse_status))"))
    return
end

@inline function _require_kind(hb::HeaderBuffer, kind::Symbol, what::String)
    hb.kind === kind ||
        throw(ArgumentError("$what is not available after a $(hb.kind) parse"))
    return
end

"""Whether the last parse completed the head."""
isdone(hb::HeaderBuffer)::Bool = hb.parse_status === :done

"""Whether the last parse left the head incomplete."""
ispartial(hb::HeaderBuffer)::Bool = hb.parse_status === :partial

"""Whether the last parse found a malformed message."""
iserror(hb::HeaderBuffer)::Bool = hb.parse_status === :error

"""Bytes occupied by the parsed head (request line/status line + header section)."""
function head_length(hb::HeaderBuffer)::Int
    _require_done(hb, "head_length")
    return hb.header_len
end

"""HTTP minor version of the parsed message."""
function minor_version(hb::HeaderBuffer)::Int
    _require_done(hb, "minor_version")
    hb.kind === :fields &&
        throw(ArgumentError("minor_version is not available after a :fields parse"))
    return Int(hb.minor_version)
end

"""Request method as a view into `buf`."""
@inline function request_method(hb::HeaderBuffer, buf::Vector{UInt8})::BufferView
    _require_done(hb, "request_method")
    _require_kind(hb, :request, "request_method")
    return _view_at(buf, hb.base, Ptr{Cchar}(UInt(hb.base) + hb.method_off), hb.method_len)
end

"""Request target as a view into `buf`, including any query."""
@inline function request_target(hb::HeaderBuffer, buf::Vector{UInt8})::BufferView
    _require_done(hb, "request_target")
    _require_kind(hb, :request, "request_target")
    return _view_at(buf, hb.base, Ptr{Cchar}(UInt(hb.base) + hb.target_off), hb.target_len)
end

"""Response status code."""
function status_code(hb::HeaderBuffer)::Int
    _require_done(hb, "status_code")
    _require_kind(hb, :response, "status_code")
    return Int(hb.status_code)
end

"""Response reason phrase as a view into `buf`."""
@inline function reason_phrase(hb::HeaderBuffer, buf::Vector{UInt8})::BufferView
    _require_done(hb, "reason_phrase")
    _require_kind(hb, :response, "reason_phrase")
    return _view_at(buf, hb.base, Ptr{Cchar}(UInt(hb.base) + hb.reason_off), hb.reason_len)
end

"""Number of headers parsed into `hb` by the last parse."""
Base.length(hb::HeaderBuffer)::Int = hb.n

"""Whether the last parse produced no headers. Also true while partial or after an
error; use [`ispartial`](@ref)/[`iserror`](@ref) to tell those apart."""
Base.isempty(hb::HeaderBuffer)::Bool = hb.n == 0

"""Name of header `i` as a view into `buf` (1-based). Empty for obs-fold
continuation lines, which picohttpparser reports with a NULL name."""
@inline function header_name(hb::HeaderBuffer, i::Integer, buf::Vector{UInt8})::BufferView
    (1 <= i <= hb.n) || throw(BoundsError(hb, i))
    h = @inbounds hb.raw[i]
    return _view_at(buf, hb.base, h.name, h.name_len)
end

"""Value of header `i` as a view into `buf` (1-based)."""
@inline function header_value(hb::HeaderBuffer, i::Integer, buf::Vector{UInt8})::BufferView
    (1 <= i <= hb.n) || throw(BoundsError(hb, i))
    h = @inbounds hb.raw[i]
    return _view_at(buf, hb.base, h.value, h.value_len)
end

"""Header `i` as a `name => value` pair of views into `buf` (1-based)."""
@inline function Base.getindex(hb::HeaderBuffer, i::Integer, buf::Vector{UInt8})::Pair{BufferView,BufferView}
    return header_name(hb, i, buf) => header_value(hb, i, buf)
end

"""
    header(hb::HeaderBuffer, buf, key) -> Union{BufferView, Nothing}

Case-insensitive lookup of the first header named `key`, without materializing
the header list.
"""
@inline function header(hb::HeaderBuffer, buf::Vector{UInt8}, key::AbstractString)
    for i in 1:hb.n
        if isequal_ascii(header_name(hb, i, buf), key)
            return header_value(hb, i, buf)
        end
    end
    return nothing
end

"""
    header(msg::HTTPMessage, key) -> Union{BufferView, Nothing}

Case-insensitive lookup of the first header named `key`, or `nothing`.
"""
function header(msg::HTTPMessage, key::AbstractString)
    for (k, v) in msg.headers
        if isequal_ascii(k, key)
            return v
        end
    end
    return nothing
end

"""Materialize all parsed headers as `Vector{Pair{BufferView,BufferView}}` (allocating)."""
function headers(hb::HeaderBuffer, buf::Vector{UInt8})::Vector{Pair{BufferView,BufferView}}
    res = Vector{Pair{BufferView,BufferView}}(undef, hb.n)
    @inbounds for i in 1:hb.n
        res[i] = hb[i, buf]
    end
    return res
end

# RFC 9112 `Content-Length = 1*DIGIT`: no sign, no base prefix, no underscores.
# `tryparse(Int, ...)` must not be used here, it accepts Julia literals such as
# "0x10", "0b101", "+5", or "-0".
@inline function _parse_content_length(v::AbstractString)::Union{Int,Nothing}
    n = ncodeunits(v)
    n == 0 && return nothing
    x = 0
    @inbounds for i in 1:n
        d = Int(codeunit(v, i)) - Int(UInt8('0'))
        (0 <= d <= 9) || return nothing
        x > (typemax(Int) - d) ÷ 10 && return nothing   # overflow
        x = x * 10 + d
    end
    return x
end

"""
    content_length(hb, buf) -> Union{Int, Nothing}

Strictly validated `Content-Length` of the parsed head: `nothing` when absent,
otherwise the value. Throws [`HTTPParseError`](@ref) when the value is not a
non-negative decimal integer (`1*DIGIT`, so no signs or base prefixes) or when
more than one `Content-Length` field is present (request-smuggling defense).
"""
function content_length(hb::HeaderBuffer, buf::Vector{UInt8})::Union{Int,Nothing}
    _require_done(hb, "content_length")
    found = nothing
    for i in 1:hb.n
        isequal_ascii(header_name(hb, i, buf), "content-length") || continue
        found === nothing ||
            throw(HTTPParseError(-1, "duplicate Content-Length fields"))
        v = _parse_content_length(header_value(hb, i, buf))
        v === nothing &&
            throw(HTTPParseError(-1, "invalid Content-Length"))
        found = v
    end
    return found
end

# ── Whole-message API (materializing, built on the incremental parsers) ──────

"""
    parse_request(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0) -> Union{Request, Nothing}

Reusable-scratch variant of [`parse_request`](@ref).
"""
function parse_request(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0)
    status = parse_request_head!(hb, buf, prev_len)
    status === :partial && return nothing
    status === :error && throw(HTTPParseError(Int(hb.result), "Failed to parse HTTP request"))
    _reject_transfer_encoding(hb, buf, "parse_request")

    hlen = head_length(hb)
    cl = content_length(hb, buf)
    body_end = hlen + (cl === nothing ? 0 : cl)
    length(buf) < body_end && return nothing   # body incomplete

    return Request(request_method(hb, buf), request_target(hb, buf),
                   minor_version(hb), headers(hb, buf),
                   view(buf, hlen + 1:body_end))
end

function _reject_transfer_encoding(hb::HeaderBuffer, buf::Vector{UInt8}, what::String)
    v = header(hb, buf, "transfer-encoding")
    v === nothing && return
    throw(ArgumentError("$what frames bodies with Content-Length only; " *
                        "Transfer-Encoding \"" * String(v) *
                        "\" requires parse_request_head! + ChunkedDecoder"))
end

# Responses that must not have a body regardless of Content-Length (RFC 9112 §6.3).
@inline _response_body_forbidden(code::Int)::Bool =
    code == 204 || code == 304 || (100 <= code < 200)

"""
    parse_request(buf::Vector{UInt8}, prev_len::Integer=0; max_headers=64) -> Union{Request, Nothing}

Parse a complete request from `buf`. Returns `nothing` if the message is
incomplete (head or body) and throws [`HTTPParseError`](@ref) if it is
malformed. Header values and the body are zero-copy views into `buf`, so keep
the buffer alive and unmodified.

Body framing is `Content-Length` only: a request without it has an empty body,
and `Transfer-Encoding` is rejected with `ArgumentError` (use
[`parse_request_head!`](@ref) with [`decode_chunked!`](@ref) instead). Duplicate
or invalid `Content-Length` throws `HTTPParseError`.

This materializes the header list; servers and other streaming callers should
use [`HeaderBuffer`](@ref) with [`parse_request_head!`](@ref) instead.
"""
parse_request(buf::Vector{UInt8}, prev_len::Integer=0; max_headers::Integer=64) =
    parse_request(HeaderBuffer(max_headers), buf, prev_len)

"""
    parse_response(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0) -> Union{Response, Nothing}

Reusable-scratch variant of [`parse_response`](@ref).
"""
function parse_response(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0)
    status = parse_response_head!(hb, buf, prev_len)
    status === :partial && return nothing
    status === :error && throw(HTTPParseError(Int(hb.result), "Failed to parse HTTP response"))
    _reject_transfer_encoding(hb, buf, "parse_response")

    code = status_code(hb)
    hlen = head_length(hb)
    cl = content_length(hb, buf)
    body_len = _response_body_forbidden(code) ? 0 : (cl === nothing ? 0 : cl)
    body_end = hlen + body_len
    length(buf) < body_end && return nothing   # body incomplete

    return Response(code, reason_phrase(hb, buf),
                    minor_version(hb), headers(hb, buf),
                    view(buf, hlen + 1:body_end))
end

"""
    parse_response(buf::Vector{UInt8}, prev_len::Integer=0; max_headers=64) -> Union{Response, Nothing}

Parse a complete response from `buf`. Returns `nothing` if the message is
incomplete and throws [`HTTPParseError`](@ref) if it is malformed. Views point
into `buf`, so keep it alive and unmodified.

Body framing is `Content-Length` only: responses without it, and 1xx/204/304
responses, have an empty body; `Transfer-Encoding` is rejected with
`ArgumentError`. Responses to HEAD cannot be identified here — the caller must
not wait for a body in that case.

1xx responses are interim: this returns the interim response and the caller must
parse the final response from the remaining bytes.
"""
parse_response(buf::Vector{UInt8}, prev_len::Integer=0; max_headers::Integer=64) =
    parse_response(HeaderBuffer(max_headers), buf, prev_len)

"""
    parse_headers(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0) -> Union{Vector, Nothing}

Reusable-scratch variant of [`parse_headers`](@ref).
"""
function parse_headers(hb::HeaderBuffer, buf::Vector{UInt8}, prev_len::Integer=0)
    status = parse_headers!(hb, buf, prev_len)
    status === :partial && return nothing
    status === :error && throw(HTTPParseError(Int(hb.result), "Failed to parse HTTP headers"))
    return headers(hb, buf)
end

"""
    parse_headers(buf::Vector{UInt8}, prev_len::Integer=0; max_headers=64)

Incrementally parse a standalone field section (for example chunked trailers).
Returns `Vector{Pair{BufferView,BufferView}}`, or `nothing` if partial; throws
[`HTTPParseError`](@ref) if malformed.
"""
parse_headers(buf::Vector{UInt8}, prev_len::Integer=0; max_headers::Integer=64) =
    parse_headers(HeaderBuffer(max_headers), buf, prev_len)

# ── Chunked transfer decoding ───────────────────────────────────────────────

"""
    ChunkedDecoder(; consume_trailer::Bool = true)

Stateful chunked-transfer decoder. Construct once and reuse across
`decode_chunked!` calls; keep one decoder per connection.
"""
mutable struct ChunkedDecoder
    bytes_left_in_chunk::Csize_t
    consume_trailer::Cchar
    _hex_count::Cchar
    _state::Cchar
    _total_read::UInt64
    _total_overhead::UInt64

    function ChunkedDecoder(; consume_trailer::Bool=true)
        return new(0, consume_trailer ? 1 : 0, 0, 0, 0, 0)
    end
end

"""
    ChunkedResult

Outcome of [`decode_chunked!`](@ref):

- `status`: `:partial` (more input required), `:done` (terminal chunk reached),
  or `:error`.
- `decoded_len`: length of the decoded data at the front of the input buffer.
- `leftover`: undecoded bytes following the decoded data; only meaningful when
  `status === :done` (for example a pipelined next request).
"""
struct ChunkedResult
    status::Symbol
    decoded_len::Int
    leftover::Int
end

"""Whether the chunked message was fully decoded (terminal chunk reached)."""
isdone(r::ChunkedResult)::Bool = r.status === :done

"""Whether [`decode_chunked!`](@ref) needs more input to finish the message."""
ispartial(r::ChunkedResult)::Bool = r.status === :partial

"""Whether [`decode_chunked!`](@ref) found malformed chunked framing."""
iserror(r::ChunkedResult)::Bool = r.status === :error

"""View of the decoded data (`1:decoded_len`) inside the in-place buffer."""
decoded(r::ChunkedResult, buf::Vector{UInt8}) = view(buf, 1:r.decoded_len)

"""View of the leftover bytes after the decoded data; valid when `isdone(r)`."""
leftover(r::ChunkedResult, buf::Vector{UInt8}) =
    view(buf, r.decoded_len + 1:r.decoded_len + r.leftover)

"""
    decode_chunked!(decoder::ChunkedDecoder, buf::Vector{UInt8}) -> ChunkedResult

Decode chunked data **in place**. `buf` must contain newly arrived, still-encoded
bytes starting at a chunk boundary or at a mid-chunk continuation; decoded bytes
are compacted to the front of `buf`. On `:done`, any bytes after the chunked
message (for example a pipelined next request) are moved directly after the
decoded data and reported as `leftover`. Hand the decoder a fresh buffer for the
next message.
"""
function decode_chunked!(decoder::ChunkedDecoder, buf::Vector{UInt8})::ChunkedResult
    bufsz = Ref{Csize_t}(length(buf))
    ret = GC.@preserve decoder buf ccall((:phr_decode_chunked, libpicohttpparser), Cssize_t,
        (Ref{ChunkedDecoder}, Ptr{Cchar}, Ref{Csize_t}),
        decoder, pointer(buf), bufsz)
    decoded_len = Int(bufsz[])
    if ret == -1
        return ChunkedResult(:error, 0, 0)
    elseif ret == -2
        return ChunkedResult(:partial, decoded_len, 0)
    end
    return ChunkedResult(:done, decoded_len, Int(ret))
end

end

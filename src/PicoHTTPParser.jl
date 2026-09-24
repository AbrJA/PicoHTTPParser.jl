module PicoHTTPParser

using PicoHTTPParser_jll
using StringViews

export parse_request, parse_response, parse_headers, get_header,
       HeaderBuffer, parse_request_head!, is_done, head_header_len,
       head_minor_version, head_method, head_path,
       header_count, header_name, header_value, header_pairs,
       ChunkedDecoder, decode_chunked!, decoded_data, leftover_data

abstract type HTTPMessage end

const BufferView = StringView{SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}}

"""
    Request

    A parsed HTTP request with zero-copy views into the original buffer.
    The `Request` object KEEPS the original buffer alive.
"""
struct Request <: HTTPMessage
    method::BufferView
    path::BufferView
    minor_version::Int
    headers::Vector{Pair{BufferView,BufferView}}
    body::SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}
end

"""
    Response
"""
struct Response <: HTTPMessage
    status_code::Int
    reason::BufferView
    minor_version::Int
    headers::Vector{Pair{BufferView,BufferView}}
    body::SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}
end

struct Header
    name::Ptr{Cchar}
    name_len::Csize_t
    value::Ptr{Cchar}
    value_len::Csize_t
end

function _ptr_to_view(buf::Vector{UInt8}, ptr::Ptr{Cchar}, len::Csize_t)::BufferView
    if ptr == C_NULL
        if len > 0
            error("Received NULL pointer with non-zero length")
        end
        return StringView(view(buf, 1:0))
    end

    GC.@preserve buf begin
        base_addr = UInt(pointer(buf))
        tgt_addr = UInt(ptr)
        offset = tgt_addr - base_addr
        start_idx = Int(offset) + 1
        end_idx = start_idx + Int(len) - 1

        if start_idx < 1 || end_idx > length(buf)
            error("Pointer falls outside of buffer bounds")
        end

        return StringView(view(buf, start_idx:end_idx))
    end
end

function _parse_headers_to_vec(headers_raw::Vector{Header}, num_headers::Int, buf::Vector{UInt8})
    res = Vector{Pair{BufferView,BufferView}}(undef, num_headers)

    @inbounds for i in 1:num_headers
        h = headers_raw[i]
        name = _ptr_to_view(buf, h.name, h.name_len)
        value = _ptr_to_view(buf, h.value, h.value_len)
        res[i] = Pair(name, value)
    end
    return res
end

"""
    parse_request(buf::Vector{UInt8}, last_len::Integer=0; max_headers=64) -> Union{Request, Nothing}

    Zero-copy parse. Returns `nothing` if the request is incomplete (partial).
    NOTE: Input must be `Vector{UInt8}`.
"""
function parse_request(buf::Vector{UInt8}, last_len::Integer=0; max_headers::Integer=64)
    method_ptr = Ref{Ptr{Cchar}}()
    method_len = Ref{Csize_t}()
    path_ptr = Ref{Ptr{Cchar}}()
    path_len = Ref{Csize_t}()
    minor_ver = Ref{Cint}()

    headers = Vector{Header}(undef, max_headers)
    num_headers = Ref{Csize_t}(max_headers)

    ret = ccall((:phr_parse_request, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
            Ref{Ptr{Cchar}}, Ref{Csize_t},
            Ref{Ptr{Cchar}}, Ref{Csize_t},
            Ref{Cint}, Ptr{Header}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        method_ptr, method_len,
        path_ptr, path_len,
        minor_ver,
        pointer(headers), num_headers,
        last_len)

    if ret == -2
        return nothing # Partial
    elseif ret < 0
        error("Failed to parse HTTP request (result = $ret)")
    end

    method = _ptr_to_view(buf, method_ptr[], method_len[])
    path = _ptr_to_view(buf, path_ptr[], path_len[])
    headers_vec = _parse_headers_to_vec(headers, Int(num_headers[]), buf)

    # Manual lookup for Content-Length to avoid allocations
    content_length = 0
    for (k, v) in headers_vec
        if length(k) == 14 && equals_insensitive(k, "content-length")
            # We can parse the StringView directly
            content_length = tryparse(Int, v)
            if isnothing(content_length)
                content_length = 0
            end
            break
        end
    end

    body_start = ret + 1
    body_end = ret + content_length

    if length(buf) < body_end
        return nothing # Body incomplete
    end

    body = view(buf, body_start:body_end)

    return Request(method, path, Int(minor_ver[]), headers_vec, body)
end

function get_header(msg::HTTPMessage, key::AbstractString)
    for (k, v) in msg.headers
        if equals_insensitive(k, key)
            return v
        end
    end
    return nothing
end

"""
    equals_insensitive(a, b) -> Bool

Allocation-free ASCII case-insensitive comparison. HTTP tokens and header names
are ASCII by definition; non-ASCII bytes compare exactly.
"""
function equals_insensitive(a::AbstractString, b::AbstractString)
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

# ── Allocation-free incremental request-head parsing ────────────────────────

"""
    HeaderBuffer([max_headers::Integer=64])

Caller-owned scratch space for [`parse_request_head!`](@ref). Reuse one per
worker thread (parsing is synchronous; a `HeaderBuffer` is not thread-safe).

Header names and values are exposed lazily as views into the input buffer, so
that buffer must stay alive and unmodified until the parsed result is consumed.
"""
mutable struct HeaderBuffer
    raw::Vector{Header}
    n::Int
    status::Symbol
    header_len::Int
    # Offsets relative to the buffer base at parse time. The input buffer may be
    # appended to (and reallocated) between parsing the head and consuming it
    # (streaming bodies), so absolute pointers would dangle.
    base::Ptr{Cchar}
    method_off::Int
    method_len::Csize_t
    path_off::Int
    path_len::Csize_t
    minor_version::Cint
end

function HeaderBuffer(max_headers::Integer=64)
    max_headers > 0 || throw(ArgumentError("max_headers must be positive"))
    return HeaderBuffer(Vector{Header}(undef, max_headers), 0, :none, 0,
                        C_NULL, 0, 0, 0, 0, 0)
end

@inline function _view_at(buf::Vector{UInt8}, base::Ptr{Cchar}, ptr::Ptr{Cchar}, len::Csize_t)::BufferView
    offset = UInt(ptr) - UInt(base)
    return _ptr_to_view(buf, Ptr{Cchar}(UInt(pointer(buf)) + offset), len)
end

"""
    parse_request_head!(hb::HeaderBuffer, buf::Vector{UInt8}, last_len::Integer=0) -> Symbol

Parse only the request line and headers; the body is never touched (body
framing is the caller's responsibility). Returns `:partial` when the header
block is incomplete, `:error` when the request is malformed or has more than
`length(hb.raw)` headers, and `:done` when the full head is present.

The result is stored in `hb` and nothing is allocated: after `:done`, use
[`head_method`](@ref), [`head_path`](@ref), [`head_header_len`](@ref) and
[`head_minor_version`](@ref).

`last_len` is the number of bytes already scanned in a previous call, so
incremental callers do not rescan the buffer prefix.

Returned views point into `buf`; keep it alive and unmodified until consumed.
"""
function parse_request_head!(hb::HeaderBuffer, buf::Vector{UInt8}, last_len::Integer=0)::Symbol
    # Locals (not fields): ccall can elide stack refs that never escape.
    raw = hb.raw
    method_ptr = Ref{Ptr{Cchar}}(C_NULL)
    method_len = Ref{Csize_t}(0)
    path_ptr = Ref{Ptr{Cchar}}(C_NULL)
    path_len = Ref{Csize_t}(0)
    minor_version = Ref{Cint}(0)
    num_headers = Ref{Csize_t}(length(raw))

    ret = GC.@preserve buf raw ccall((:phr_parse_request, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
         Ref{Ptr{Cchar}}, Ref{Csize_t},
         Ref{Ptr{Cchar}}, Ref{Csize_t},
         Ref{Cint}, Ptr{Header}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        method_ptr, method_len,
        path_ptr, path_len,
        minor_version,
        pointer(raw), num_headers,
        last_len)

    if ret == -2
        hb.n = 0
        hb.status = :partial
        hb.header_len = 0
        return :partial
    elseif ret < 0
        hb.n = 0
        hb.status = :error
        hb.header_len = 0
        return :error
    end

    b = pointer(buf)
    hb.n = Int(num_headers[])
    hb.status = :done
    hb.header_len = Int(ret)
    hb.base = b
    hb.method_off = Int(UInt(method_ptr[]) - UInt(b))
    hb.method_len = method_len[]
    hb.path_off = Int(UInt(path_ptr[]) - UInt(b))
    hb.path_len = path_len[]
    hb.minor_version = minor_version[]
    return :done
end

"""Whether the last [`parse_request_head!`](@ref) call completed the header block."""
is_done(hb::HeaderBuffer)::Bool = hb.status === :done

"""Bytes occupied by the request head (0 unless the last parse returned `:done`)."""
head_header_len(hb::HeaderBuffer)::Int = hb.header_len

"""HTTP minor version of the parsed request (valid when `is_done(hb)`)."""
head_minor_version(hb::HeaderBuffer)::Int = Int(hb.minor_version)

"""Request method as a view into `buf` (valid when `is_done(hb)`)."""
@inline head_method(hb::HeaderBuffer, buf::Vector{UInt8})::BufferView =
    _ptr_to_view(buf, Ptr{Cchar}(UInt(pointer(buf)) + hb.method_off), hb.method_len)

"""Request path as a view into `buf` (valid when `is_done(hb)`)."""
@inline head_path(hb::HeaderBuffer, buf::Vector{UInt8})::BufferView =
    _ptr_to_view(buf, Ptr{Cchar}(UInt(pointer(buf)) + hb.path_off), hb.path_len)

"""Number of headers parsed into `hb` by the last [`parse_request_head!`](@ref)."""
header_count(hb::HeaderBuffer)::Int = hb.n

"""Name of header `i` as a view into `buf` (1-based)."""
@inline function header_name(hb::HeaderBuffer, i::Integer, buf::Vector{UInt8})::BufferView
    h = @inbounds hb.raw[i]
    return _view_at(buf, hb.base, h.name, h.name_len)
end

"""Value of header `i` as a view into `buf` (1-based)."""
@inline function header_value(hb::HeaderBuffer, i::Integer, buf::Vector{UInt8})::BufferView
    h = @inbounds hb.raw[i]
    return _view_at(buf, hb.base, h.value, h.value_len)
end

"""
    get_header(hb::HeaderBuffer, buf, key) -> Union{BufferView, Nothing}

Case-insensitive header lookup without materializing the header list.
"""
@inline function get_header(hb::HeaderBuffer, buf::Vector{UInt8}, key::AbstractString)
    for i in 1:hb.n
        if equals_insensitive(header_name(hb, i, buf), key)
            return header_value(hb, i, buf)
        end
    end
    return nothing
end

"""Materialize all parsed headers as `Vector{Pair{BufferView,BufferView}}` (allocating)."""
function header_pairs(hb::HeaderBuffer, buf::Vector{UInt8})::Vector{Pair{BufferView,BufferView}}
    res = Vector{Pair{BufferView,BufferView}}(undef, hb.n)
    @inbounds for i in 1:hb.n
        res[i] = header_name(hb, i, buf) => header_value(hb, i, buf)
    end
    return res
end

"""
    parse_headers(buf::Vector{UInt8}, last_len::Integer=0; max_headers::Integer=64)

    Incrementally parse headers.
    Returns `Vector{Pair{BufferView, BufferView}}` or `nothing` if partial.
"""
function parse_headers(buf::Vector{UInt8}, last_len::Integer=0; max_headers::Integer=64)
    headers = Vector{Header}(undef, max_headers)
    num_headers = Ref{Csize_t}(max_headers)

    # SAFETY: We must preserve 'buf' so it isn't freed while C reads it
    ret = GC.@preserve buf ccall((:phr_parse_headers, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
            Ptr{Header}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        pointer(headers), num_headers, last_len)

    if ret == -2
        return nothing
    elseif ret < 0
        error("Failed to parse HTTP headers (result = $ret)")
    end

    # The buffer 'buf' is passed down to create the views
    return _parse_headers_to_vec(headers, Int(num_headers[]), buf)
end

"""
    parse_response(buf::Vector{UInt8}; max_headers=64)
"""
function parse_response(buf::Vector{UInt8}; max_headers::Integer=64)
    minor_ver = Ref{Cint}()
    status_code = Ref{Cint}()
    msg_ptr = Ref{Ptr{Cchar}}()
    msg_len = Ref{Csize_t}()

    headers = Vector{Header}(undef, max_headers)
    num_headers = Ref{Csize_t}(max_headers)

    ret = ccall((:phr_parse_response, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
            Ref{Cint}, Ref{Cint},
            Ref{Ptr{Cchar}}, Ref{Csize_t},
            Ptr{Header}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        minor_ver, status_code,
        msg_ptr, msg_len,
        pointer(headers), num_headers,
        0)

    if ret == -2
        return nothing
    elseif ret < 0
        error("Failed to parse HTTP response (result = $ret)")
    end

    reason = _ptr_to_view(buf, msg_ptr[], msg_len[])
    headers_vec = _parse_headers_to_vec(headers, Int(num_headers[]), buf)

    content_length = 0
    for (k, v) in headers_vec
        if length(k) == 14 && equals_insensitive(k, "content-length")
            content_length = tryparse(Int, v)
            if isnothing(content_length)
                content_length = 0
            end
            break
        end
    end

    body_start = ret + 1
    body_end = ret + content_length

    if length(buf) < body_end
        return nothing
    end

    body = view(buf, body_start:body_end)

    return Response(Int(status_code[]), reason, Int(minor_ver[]), headers_vec, body)
end

"""
    ChunkedDecoder(; consume_trailer::Bool = true)

Stateful chunked-transfer decoder. Zero-fill once and reuse across
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

is_done(r::ChunkedResult)::Bool = r.status === :done

"""View of the decoded data (`1:decoded_len`) inside the in-place buffer."""
decoded_data(r::ChunkedResult, buf::Vector{UInt8}) = view(buf, 1:r.decoded_len)

"""View of the leftover bytes after the decoded data; valid when `is_done(r)`."""
leftover_data(r::ChunkedResult, buf::Vector{UInt8}) =
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

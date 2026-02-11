module PicoHTTPParser

using PicoHTTPParser_jll
using StringViews

export parse_request, parse_response, parse_headers, get_header, ChunkedDecoder, decode_chunked!

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

function equals_insensitive(a::AbstractString, b::AbstractString)
    return length(a) == length(b) && all(lowercase(c1) == lowercase(c2) for (c1, c2) in zip(a, b))
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

    Returns:
        ChunkedDecoder
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

struct ChunkedResult
    done::Bool
    # We return a view because the data is IN PLACE in the buffer you passed.
    data::SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}
end

"""
    decode_chunked!(decoder::ChunkedDecoder, buf::Vector{UInt8})

    Decodes chunked data IN-PLACE within `buf`.
    Returns `ChunkedResult`.
"""
function decode_chunked!(decoder::ChunkedDecoder, buf::Vector{UInt8})
    buf_len = Ref{Csize_t}(length(buf))

    ret = ccall((:phr_decode_chunked, libpicohttpparser), Cssize_t,
        (Ref{ChunkedDecoder}, Ptr{Cchar}, Ref{Csize_t}),
        Ref(decoder), pointer(buf), buf_len)

    if ret == -1
        error("Failed to decode chunked data")
    end

    final_len = Int(buf_len[])

    # Check if we are truly done (0-length chunk + trailer consumed)
    done = (decoder.bytes_left_in_chunk == 0 && decoder.consume_trailer != 0)

    return ChunkedResult(done, view(buf, 1:final_len))
end

end

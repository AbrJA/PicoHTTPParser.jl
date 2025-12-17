module PicoHTTPParser

using PicoHTTPParser_jll

export parse_request, parse_response, parse_headers,
    ChunkedDecoder, decode_chunked!

abstract type HTTPMessage end

"""
    Request

    A parsed HTTP request.
"""
struct Request <: HTTPMessage
    method::String
    path::String
    minor_version::Int
    headers::Dict{String,String}
    body::Vector{UInt8}
end

"""
    Response

    A parsed HTTP response.
"""
struct Response <: HTTPMessage
    status_code::Int
    reason::String
    minor_version::Int
    headers::Dict{String,String}
    body::Vector{UInt8}
end

struct Header
    name::Ptr{Cchar}
    name_len::Csize_t
    value::Ptr{Cchar}
    value_len::Csize_t
end

function _parse_headers_to_dict(headers::Vector{Header}, num_headers::Int)
    headers_dict = Dict{String,String}()
    sizehint!(headers_dict, num_headers)

    for i in 1:num_headers
        h = headers[i]
        name = unsafe_string(h.name, h.name_len)
        value = unsafe_string(h.value, h.value_len)
        headers_dict[name] = value
    end

    return headers_dict
end

"""
    parse_request(message::Union{AbstractString, AbstractVector{<:UInt8}}; max_headers::Integer = 64) -> Request

    Parse an HTTP request string using picohttpparser.

    Returns:
        Request
"""

## WIP
# import Base: parse
# function Base.parse(::Type{T}, s::AbstractString; max_headers::Integer = 64) where {T<:HTTPMessage}
#     return parse(T, codeunits(s); max_headers = max_headers)
# end

function parse_request(message::Union{AbstractString,AbstractVector{<:UInt8}}; max_headers::Integer=64)
    buf = message isa AbstractString ? codeunits(message) : message

    method_ptr, method_len = Ref{Ptr{Cchar}}(), Ref{Csize_t}()
    path_ptr, path_len = Ref{Ptr{Cchar}}(), Ref{Csize_t}()
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
        0)

    if ret < 0
        error("Failed to parse HTTP request (result = $ret)")
    end

    method = unsafe_string(method_ptr[], method_len[])
    path = unsafe_string(path_ptr[], path_len[])
    headers_dict = _parse_headers_to_dict(headers, Int(num_headers[]))

    content_length = get(headers_dict, "Content-Length", "0")
    body_len = parse(Int, content_length)
    # Use body_len > 0 case or buf[(ret + 1):end]?
    body = buf[(ret+1):(ret+body_len)]

    return Request(method, path, minor_ver[], headers_dict, body)
end

"""
    parse_headers(message::Union{AbstractString, AbstractVector{<:UInt8}}, last_len::Integer = 0; max_headers::Integer = 64) -> Dict{String, String}

    Incrementally parse headers (like phr_parse_headers).

    Returns:
        Dict{String, String}
"""
function parse_headers(message::Union{AbstractString,AbstractVector{<:UInt8}}, last_len::Integer=0; max_headers::Integer=64)
    buf = message isa AbstractString ? codeunits(message) : message

    headers = Vector{Header}(undef, max_headers)
    num_headers = Ref{Csize_t}(max_headers)

    ret = ccall((:phr_parse_headers, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
            Ptr{Header}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        pointer(headers), num_headers, last_len)

    if ret < 0
        error("Failed to parse HTTP headers (result = $ret)")
    end

    return _parse_headers_to_dict(headers, Int(num_headers[]))
end

"""
    parse_response(message::Union{AbstractString, AbstractVector{<:UInt8}}; max_headers::Integer = 64)

    Parse an HTTP response string using picohttpparser.

    Returns:
        Response
"""
function parse_response(message::Union{AbstractString,AbstractVector{<:UInt8}}; max_headers::Integer=64)
    buf = message isa AbstractString ? codeunits(message) : message

    minor_ver = Ref{Cint}()
    status_code = Ref{Cint}()
    msg_ptr, msg_len = Ref{Ptr{Cchar}}(), Ref{Csize_t}()

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

    if ret < 0
        error("Failed to parse HTTP response (result = $ret)")
    end

    reason = unsafe_string(msg_ptr[], msg_len[])
    headers_dict = _parse_headers_to_dict(headers, Int(num_headers[]))

    content_length = get(headers_dict, "Content-Length", "0")
    body_len = parse(Int, content_length)
    # Use body_len > 0 case?
    body = buf[(ret+1):(ret+body_len)]

    return Response(status_code[], reason, minor_ver[], headers_dict, body)
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
    data::Vector{UInt8}
end

"""
    decode_chunked!(decoder::ChunkedDecoder, buf::Vector{UInt8}) -> ChunkedResult

    Feed a buffer of chunked-encoded data through picohttpparser's `phr_decode_chunked`.

    Returns:
        ChunkedResult
"""
function decode_chunked!(decoder::ChunkedDecoder, message::Union{AbstractString,AbstractVector{<:UInt8}})
    buf = message isa AbstractString ? codeunits(message) : message
    buf_len = Ref{Csize_t}(length(buf))

    ret = ccall((:phr_decode_chunked, libpicohttpparser), Cssize_t,
        (Ref{ChunkedDecoder}, Ptr{Cchar}, Ref{Csize_t}),
        Ref(decoder), pointer(buf), buf_len)

    if ret == -1
        error("Failed to decode chunked data (result = $ret)")
    elseif ret == -2
        return ChunkedResult(false, UInt8[])
    else
        data = buf[1:buf_len[]]
        done = (decoder.bytes_left_in_chunk == 0 && decoder.consume_trailer != 0) ? true : false
        return ChunkedResult(done, data)
    end
end

end

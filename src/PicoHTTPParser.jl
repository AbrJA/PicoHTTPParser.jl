module PicoHTTPParser


using PicoHTTPParser_jll


export parse_request, parse_response, parse_headers,
       PhrChunkedDecoder, decode_chunked!

struct PhrHeader
    name::Ptr{Cchar}
    name_len::Csize_t
    value::Ptr{Cchar}
    value_len::Csize_t
end

"""
    parse_request(req::AbstractString) -> NamedTuple

    Parse an HTTP request string using picohttpparser.

    Returns:
        (method, path, minor_version, headers::Dict)
"""
function parse_request(req::Union{AbstractString, AbstractVector{<:UInt8}}; max_headers::Integer = 64)
    buf = req isa AbstractString ? codeunits(req) : req

    method_ptr, method_len = Ref{Ptr{Cchar}}(), Ref{Csize_t}()
    path_ptr, path_len = Ref{Ptr{Cchar}}(), Ref{Csize_t}()
    minor_ver = Ref{Cint}()

    headers = Vector{PhrHeader}(undef, max_headers)
    num_headers = Ref{Csize_t}(max_headers)

    ret = ccall((:phr_parse_request, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
         Ref{Ptr{Cchar}}, Ref{Csize_t},
         Ref{Ptr{Cchar}}, Ref{Csize_t},
         Ref{Cint}, Ptr{PhrHeader}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        method_ptr, method_len,
        path_ptr, path_len,
        minor_ver,
        pointer(headers), num_headers,
        0)

    if ret < 0
        error("Failed to parse HTTP request (code = $ret)")
    end

    method = unsafe_string(method_ptr[], method_len[])
    path = unsafe_string(path_ptr[], path_len[])
    headers_dict = Dict{String,String}()
    sizehint!(headers_dict, num_headers[])

    for i in 1:num_headers[]
        h = headers[i]
        name = unsafe_string(h.name, h.name_len)
        value = unsafe_string(h.value, h.value_len)
        headers_dict[name] = value
    end

    return (method = method, path = path, minor_version = minor_ver[], headers = headers_dict)
end

"""
    parse_headers(buf::Vector{UInt8}, last_len::Integer=0)

    Incrementally parse headers (like phr_parse_headers).

    Returns:
        (ret, headers)
"""
function parse_headers(buf::AbstractVector{<:UInt8}, last_len::Integer = 0; max_headers::Integer = 64)
    headers = Vector{PhrHeader}(undef, max_headers)
    num_headers = Ref{Csize_t}(max_headers)

    ret = ccall((:phr_parse_headers, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
         Ptr{PhrHeader}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        pointer(headers), num_headers, last_len)

    return (ret = ret, headers = headers[1:num_headers[]])
end

"""
    parse_response(resp::AbstractString) -> NamedTuple

    Parse an HTTP response string using picohttpparser.

    Returns:
        (status_code, reason, minor_version, headers::Dict)
"""
function parse_response(resp::Union{AbstractString, AbstractVector{<:UInt8}}; max_headers::Integer = 64)
    buf = resp isa AbstractString ? codeunits(resp) : resp

    minor_ver = Ref{Cint}()
    status_code = Ref{Cint}()
    msg_ptr = Ref{Ptr{Cchar}}()
    msg_len = Ref{Csize_t}()
    headers = Vector{PhrHeader}(undef, max_headers)
    num_headers = Ref{Csize_t}(max_headers)

    ret = ccall((:phr_parse_response, libpicohttpparser), Cint,
        (Ptr{Cchar}, Csize_t,
         Ref{Cint}, Ref{Cint},
         Ref{Ptr{Cchar}}, Ref{Csize_t},
         Ptr{PhrHeader}, Ref{Csize_t}, Csize_t),
        pointer(buf), length(buf),
        minor_ver, status_code,
        msg_ptr, msg_len,
        pointer(headers), num_headers,
        0)

    if ret < 0
        error("Failed to parse HTTP response (code = $ret)")
    end

    reason = unsafe_string(msg_ptr[], msg_len[])
    headers_dict = Dict{String,String}()

    for i in 1:num_headers[]
        h = headers[i]
        name = unsafe_string(h.name, h.name_len)
        value = unsafe_string(h.value, h.value_len)
        headers_dict[name] = value
    end

    return (status_code = status_code[],
            reason = reason,
            minor_version = minor_ver[],
            headers = headers_dict)
end

mutable struct PhrChunkedDecoder
    bytes_left_in_chunk::Csize_t
    consume_trailer::Cchar
    _hex_count::Cchar
    _state::Cchar

    function PhrChunkedDecoder(; consume_trailer::Bool = true)
        return new(0, consume_trailer ? 1 : 0, 0, 0)
    end
end

"""
    decode_chunked!(decoder::PhrChunkedDecoder, buf::Vector{UInt8}) -> (decoded::Vector{UInt8}, status::Symbol)

    Feed a buffer of chunked-encoded data through picohttpparser's `phr_decode_chunked`.

    Returns:
        (ret, status, decoded_data)
"""
function decode_chunked!(decoder::PhrChunkedDecoder, buf::AbstractVector{<:UInt8})
    buflen = Ref{Csize_t}(length(buf))
    ret = ccall((:phr_decode_chunked, libpicohttpparser), Cssize_t,
                (Ref{PhrChunkedDecoder}, Ptr{Cchar}, Ref{Csize_t}),
                decoder, pointer(buf), buflen)
    if ret == -1
        return (-1, :error, UInt8[])
    elseif ret == -2
        return (-2, :need_more, UInt8[])
    else
        decoded = buf[1:buflen[]]
        status = (decoder.bytes_left_in_chunk == 0 && decoder.consume_trailer != 0) ? :done : :need_more
        return (Int(ret), status, decoded)
    end
end

end

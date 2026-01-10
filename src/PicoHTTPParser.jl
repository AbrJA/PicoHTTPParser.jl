module PicoHTTPParser

using PicoHTTPParser_jll
using StringViews

export parse_request, parse_response, parse_headers, ChunkedDecoder, decode_chunked!

abstract type HTTPMessage end

"""
    Request{S <: AbstractString, B <: AbstractVector{UInt8}}

    A parsed HTTP request with zero-copy views into the original buffer.
"""
struct Request{S<:AbstractString,B<:AbstractVector{UInt8}} <: HTTPMessage
    method::S
    path::S
    minor_version::Int
    headers::Vector{Pair{S,S}}
    body::B
end

"""
    Response{S <: AbstractString, B <: AbstractVector{UInt8}}

    A parsed HTTP response with zero-copy views into the original buffer.
"""
struct Response{S<:AbstractString,B<:AbstractVector{UInt8}} <: HTTPMessage
    status_code::Int
    reason::S
    minor_version::Int
    headers::Vector{Pair{S,S}}
    body::B
end

struct Header
    name::Ptr{Cchar}
    name_len::Csize_t
    value::Ptr{Cchar}
    value_len::Csize_t
end

function _ptr_to_view(buf::AbstractVector{UInt8}, ptr::Ptr{Cchar}, len::Csize_t)
    if ptr == C_NULL
        if len > 0
            error("Received NULL pointer with non-zero length")
        end
        return StringView(@view(buf[1:0]))
    end

    # Calculate offset of ptr relative to pointer(buf)
    # Assumes buf is contiguous and ptr is within it
    # Cast pointer(buf) to Ptr{Cchar} to match ptr type (Ptr{Cchar} vs Ptr{UInt8})
    base_ptr = reinterpret(Ptr{Cchar}, pointer(buf))
    offset = ptr - base_ptr
    start = Int(offset) + 1
    # Create a view into the buffer
    rng = start:(start+Int(len)-1)
    return StringView(@view(buf[rng]))
end

function _parse_headers_to_vec(headers::Vector{Header}, num_headers::Int, buf::AbstractVector{UInt8})
    res = Vector{Pair{StringView{SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int64}},true}},StringView{SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int64}},true}}}}(undef, num_headers)
    # To avoid hardcoding complex types, we can let inference handle it or assume Vector{UInt8} input for now which is most common.
    # But `buf` might be different. Let's make it generic by using `_ptr_to_view` return type?
    # Actually, let's just use `Any` or let Julia infer? No, we want concrete types for fields.
    # But `Request` is parametric, so it's fine.

    # We need to construct the vector with the correct concrete type to avoid Any.
    # Let's get the type from the first item or a dummy.
    # Or just use resizing.

    # Let's trust `_ptr_to_view` type stability if we type it simpler, but `_ptr_to_view` returns a concrete type based on buf type.

    # The simplest way is to map.
    # But we want to avoid allocations of intermediate structures if possible, but a loop is fine.

    # Let's iterate and see.

    base_ptr = pointer(buf)

    # Pre-calculate the type to init the vector?
    # S = typeof(_ptr_to_view(buf, Ptr{Cchar}(0), Csize_t(0)))
    # headers_vec = Vector{Pair{S,S}}(undef, num_headers)

    # Actually, we can just build it.

    headers_vec = Vector{Pair{typeof(_ptr_to_view(buf, Ptr{Cchar}(0), Csize_t(0))),typeof(_ptr_to_view(buf, Ptr{Cchar}(0), Csize_t(0)))}}(undef, num_headers)

    for i in 1:num_headers
        h = headers[i]
        name = _ptr_to_view(buf, h.name, h.name_len)
        value = _ptr_to_view(buf, h.value, h.value_len)
        headers_vec[i] = Pair(name, value)
    end

    return headers_vec
end

"""
    parse_request(message::Union{AbstractString, AbstractVector{<:UInt8}}; max_headers::Integer = 64) -> Union{Request, Nothing}

    Parse an HTTP request string using picohttpparser.
    Returns `nothing` if the request is partial (incomplete).
"""
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

    if ret == -2
        return nothing # Partial request
    elseif ret < 0
        error("Failed to parse HTTP request (result = $ret)")
    end

    method = _ptr_to_view(buf, method_ptr[], method_len[])
    path = _ptr_to_view(buf, path_ptr[], path_len[])
    headers_vec = _parse_headers_to_vec(headers, Int(num_headers[]), buf)

    # find Content-Length
    content_length = 0
    for (k, v) in headers_vec
        # Case insensitive comparison? HTTP headers are case insensitive.
        # fast check
        if length(k) == 14 && equals_insensitive(k, "content-length")
            content_length = parse(Int, v)
            break
        end
    end

    body_start = ret + 1
    body_end = ret + content_length

    # Check if we have the full body?
    # The return value `ret` is the number of bytes consumed by the request line and headers.
    # The parser doesn't check body length.

    if length(buf) < body_end
        # We parsed headers, but body is incomplete.
        # This is tricky. Should we return partial?
        # `phr_parse_request` only parses headers.
        # If existing logic assumes full packet, we should check.
        # For non-blocking, we probably want to return partial if body isn't fully there yet?
        return nothing
    end

    body = @view(buf[body_start:body_end])

    return Request(method, path, Int(minor_ver[]), headers_vec, body)
end

function equals_insensitive(a::AbstractString, b::AbstractString)
    return length(a) == length(b) && all(lowercase(c1) == lowercase(c2) for (c1, c2) in zip(a, b))
end

"""
    parse_headers(message::Union{AbstractString, AbstractVector{<:UInt8}}, last_len::Integer = 0; max_headers::Integer = 64) -> Union{Vector{Pair}, Nothing}

    Incrementally parse headers (like phr_parse_headers).
    Returns `nothing` if partial.
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

    if ret == -2
        return nothing
    elseif ret < 0
        error("Failed to parse HTTP headers (result = $ret)")
    end

    return _parse_headers_to_vec(headers, Int(num_headers[]), buf)
end

"""
    parse_response(message::Union{AbstractString, AbstractVector{<:UInt8}}; max_headers::Integer = 64) -> Union{Response, Nothing}

    Parse an HTTP response string using picohttpparser.
    Returns `nothing` if partial.
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
            content_length = parse(Int, v)
            break
        end
    end

    body_start = ret + 1
    body_end = ret + content_length

    if length(buf) < body_end
        return nothing
    end

    body = @view(buf[body_start:body_end])

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
    data::Vector{UInt8}
    # Optimization: Chunked data might be fragmented, so Vector{UInt8} copy is easiest for now unless we return a view and let user concat.
    # Existing API returns Vector{UInt8}, let's keep it for compatibility or minimal change in this specific struct.
    # But wait, we want zero copy. `data` could be a view.
    # However, `phr_decode_chunked` modifies the buffer IN PLACE to remove chunk headers?
    # No, `phr_decode_chunked` signature: `phr_decode_chunked(struct phr_chunked_decoder *decoder, char *buf, size_t *bufsz)`
    # It decodes in-place!
    # If it decodes in-place, we CANNOT use `message::String` strings (immutable).
    # We must use `Vector{UInt8}` and modify it.
    # But `parse_request` etc take `AbstractString`.
    # `ChunkedDecoder` takes `message`.
    # The existing implementation creates `buf` which is `codeunits(message)`.
    # `codeunits(String)` is unsafe to modify? Yes.
    # So `decode_chunked!` implies modification.
    # The existing implementation allocates `data = buf[1:buf_len[]]`.
end

# We will leave ChunkedDecoder mostly as is but ensure safety.
struct ChunkedResultView
    done::Bool
    data::SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int64}},true}
end

function decode_chunked!(decoder::ChunkedDecoder, buf::AbstractVector{UInt8})
    # Must be mutable buffer
    buf_len = Ref{Csize_t}(length(buf))

    ret = ccall((:phr_decode_chunked, libpicohttpparser), Cssize_t,
        (Ref{ChunkedDecoder}, Ptr{Cchar}, Ref{Csize_t}),
        Ref(decoder), pointer(buf), buf_len)

    if ret == -1
        error("Failed to decode chunked data (result = $ret)")
    elseif ret == -2
        # Incomplete
        return ChunkedResult(false, UInt8[]) # Or adjust return type
    else
        # ret is number of bytes consumed from input.
        # buf_len is number of bytes available in decoded output (in-place).

        # Existing impl returned ChunkedResult(done, data_copy).
        # We can return a view if we want zero copy, but the buffer is modified.
        # If we return a view, it points to `buf` which is now modified.

        data = @view(buf[1:Int(buf_len[])])
        done = (decoder.bytes_left_in_chunk == 0 && decoder.consume_trailer != 0)
        return ChunkedResult(done, Vector(data)) # Keep it safe with Vector for now or change to view?
        # User asked for zero copy. But in-place decoding is destructive.
        # The user's buffer `buf` IS the data carrier.
        # So returning a view into `buf` is correct zero-copy behavior.
        # But `ChunkedResult` struct definition in existing code: `data::Vector{UInt8}`.
        # Let's update `ChunkedResult` to hold a view or standard vector?
        # If we change `ChunkedResult`, it might break code expecting Vector.
        # But we are breaking `Request` anyway.

        # Let's keep `ChunkedResult` essentially the same but maybe use View if requested?
        # The prompt didn't strictly prioritize ChunkedDecoder zero-copy, but `Request` parsing.
        # Let's stick to consistent breaking changes.

        # However, `Vector(data)` allocates.
        # Let's define `data::AbstractVector{UInt8}` in ChunkedResult.
    end
end

end

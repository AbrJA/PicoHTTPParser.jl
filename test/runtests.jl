using Test
using PicoHTTPParser
using PicoHTTPParser: header, headers   # intentionally not exported (generic names)
using StringViews

@testset "PicoHTTPParser Tests" begin

    # Helper to create a mutable buffer for tests
    # (The zero-copy parser requires Vector{UInt8}, not Strings)
    make_buf(str) = Vector{UInt8}(str)

    @testset "Parse Request" begin
        # 1. Standard Simple Request
        raw = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nUser-Agent: Julia\r\n\r\n"
        buf = make_buf(raw)

        req = parse_request(buf)

        @test req !== nothing
        @test req.method == "GET"
        @test req.target == "/index.html"
        @test req.minor_version == 1

        # Test Header retrieval helper
        @test header(req, "Host") == "example.com"
        @test header(req, "User-Agent") == "Julia"
        @test isnothing(header(req, "Accept")) # Missing header

        # Test Body (Empty)
        @test isempty(req.body)
    end

    @testset "Parse Request with Body" begin
        content = "Hello World"
        raw = "POST /submit HTTP/1.1\r\nContent-Length: 11\r\n\r\n$content"
        buf = make_buf(raw)

        req = parse_request(buf)

        @test req !== nothing
        @test req.method == "POST"
        @test String(req.body) == "Hello World"
    end

    @testset "Partial Requests (Streaming)" begin
        # Simulate a packet split in the middle
        raw_part1 = "GET /index.html HTTP/1.1\r\nHost: exam"
        buf = make_buf(raw_part1)

        req = parse_request(buf)
        @test isnothing(req) # Should return nothing, not error
    end

    @testset "Full Streaming Request Flow" begin
        # 1. Initialize a buffer
        # In a real server, this would be a persistent buffer per connection
        buf = Vector{UInt8}()
        prev_len = 0

        # 2. Receive Part 1 (Incomplete)
        part1 = "GET /async HTTP/1.1\r\nUser-A"
        append!(buf, Vector{UInt8}(part1))

        # Try to parse. Pass prev_len (which is 0 initially).
        req = parse_request(buf, prev_len)
        @test isnothing(req)

        # Update prev_len. We know the first part didn't contain the full headers,
        # so next time we can skip scanning these bytes.
        prev_len = length(buf)

        # 3. Receive Part 2 (Still Incomplete Headers)
        part2 = "gent: Julia\r\nHost: test"
        append!(buf, Vector{UInt8}(part2))

        req = parse_request(buf, prev_len)
        @test isnothing(req)

        prev_len = length(buf)

        # 4. Receive Part 3 (Complete Headers + Body)
        # Note: We need \r\n\r\n to finish headers
        part3 = ".com\r\nContent-Length: 5\r\n\r\nHello"
        append!(buf, Vector{UInt8}(part3))

        req = parse_request(buf, prev_len)

        # 5. Success!
        @test req !== nothing
        @test req.target == "/async"
        @test header(req, "User-Agent") == "Julia"
        @test String(req.body) == "Hello"
    end

    @testset "Parse Response" begin
        raw = "HTTP/1.1 200 OK\r\nServer: Pico\r\nContent-Length: 4\r\n\r\nWiki"
        buf = make_buf(raw)

        res = parse_response(buf)

        @test res !== nothing
        @test res.status_code == 200
        @test res.reason_phrase == "OK"
        @test header(res, "Server") == "Pico"
        @test String(res.body) == "Wiki"
    end

    @testset "Parse Headers (Standalone & Incremental)" begin
        # 1. Simple Complete Case
        # Note: phr_parse_headers expects pure headers, usually after the request line
        raw = "Host: example.com\r\nContent-Type: text/plain\r\n\r\n"
        buf = make_buf(raw)

        headers = parse_headers(buf)

        @test headers !== nothing
        @test length(headers) == 2
        @test headers[1].first == "Host"
        @test headers[1].second == "example.com"
        @test headers[2].first == "Content-Type"
        @test headers[2].second == "text/plain"

        # 2. Partial / Incomplete Headers (Returns nothing)
        raw_partial = "Host: examp" # No CRLF yet
        buf_partial = make_buf(raw_partial)

        h_partial = parse_headers(buf_partial)
        @test h_partial === nothing

        # 3. Incremental Parsing Optimization (using prev_len)
        # This tests the `prev_len` parameter which tells the parser
        # "I already scanned this many bytes, don't rescan them."

        # Step A: Receive first part
        part1 = "Host: example"
        buf_stream = make_buf(part1)

        # Try to parse, it fails (incomplete)
        @test parse_headers(buf_stream) === nothing

        # Record how much we have scanned so far
        len_scanned = length(buf_stream)

        # Step B: Receive the rest
        part2 = ".com\r\nAccept: */*\r\n\r\n"
        append!(buf_stream, make_buf(part2)) # Mutate buffer to append

        # Try to parse again, passing 'len_scanned' to optimize
        h_final = parse_headers(buf_stream, len_scanned)

        @test h_final !== nothing
        @test length(h_final) == 2
        @test h_final[1].second == "example.com"
        @test h_final[2].first == "Accept"
    end

    @testset "Chunked Decoding (In-Place)" begin
        # Chunked encoding: size\r\ndata\r\n ... 0\r\n\r\n
        # "Wiki" in chunks: "4\r\nWiki\r\n0\r\n\r\n"
        raw_chunked = "4\r\nWiki\r\n0\r\n\r\n"
        buf = make_buf(raw_chunked)

        decoder = ChunkedDecoder()

        # decode_chunked! modifies 'buf' in-place!
        result = decode_chunked!(decoder, buf)

        @test isdone(result)
        @test result.status === :done
        @test result.leftover == 0
        @test String(decoded(result, buf)) == "Wiki"

        # The decoded data is compacted to the front of the buffer.
        @test String(buf[1:4]) == "Wiki"
    end

    @testset "Chunked Decoding - Fragmented" begin
        # Simulate receiving chunks in two parts:
        # Part 1: "4\r\nWi"   → 2 decoded bytes, chunk still open
        # Part 2: "ki\r\n0\r\n\r\n" → completes the message
        decoder = ChunkedDecoder()

        buf1 = make_buf("4\r\nWi")
        res1 = decode_chunked!(decoder, buf1)
        @test res1.status === :partial
        @test ispartial(res1)
        @test !isdone(res1)
        @test String(decoded(res1, buf1)) == "Wi"

        buf2 = make_buf("ki\r\n0\r\n\r\n")
        res2 = decode_chunked!(decoder, buf2)
        @test isdone(res2)
        @test String(decoded(res2, buf2)) == "ki"
    end

    @testset "Chunked Decoding - Leftover (pipelining)" begin
        # Bytes that follow the terminal chunk are reported as leftover.
        trailer = "GET /next HTTP/1.1\r\n\r\n"
        buf = make_buf("4\r\nWiki\r\n0\r\n\r\n" * trailer)
        result = decode_chunked!(ChunkedDecoder(), buf)

        @test isdone(result)
        @test String(decoded(result, buf)) == "Wiki"
        @test result.leftover == length(trailer)
        @test String(leftover(result, buf)) == trailer
    end

    @testset "Chunked Decoding - Error" begin
        buf = make_buf("Z\r\nWiki\r\n0\r\n\r\n")   # 'Z' is not a hex chunk size
        result = decode_chunked!(ChunkedDecoder(), buf)
        @test result.status === :error
        @test iserror(result)
        @test !isdone(result)
    end

    @testset "Request Head - allocation-free API" begin
        raw = "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nHello"
        buf = make_buf(raw)
        hb = HeaderBuffer(16)

        @test parse_request_head!(hb, buf) === :done
        @test isdone(hb)
        @test !ispartial(hb)
        @test !iserror(hb)
        @test request_method(hb, buf) == "POST"
        @test request_target(hb, buf) == "/submit"
        @test minor_version(hb) == 1
        @test head_length(hb) == findfirst("\r\n\r\n", raw)[1] + 3
        @test length(hb) == 2
        @test header_name(hb, 1, buf) == "Host"
        @test header_value(hb, 1, buf) == "example.com"
        @test hb[1, buf] == ("Host" => "example.com")
        @test hb[2, buf].first == "Content-Length"
        @test header(hb, buf, "content-length") == "5"
        @test header(hb, buf, "CONTENT-LENGTH") == "5"
        @test header(hb, buf, "missing") === nothing

        pairs = headers(hb, buf)
        @test length(pairs) == 2
        @test pairs[2].first == "Content-Length"
        @test pairs[2].second == "5"
    end

    @testset "Request Head - incremental with prev_len" begin
        hb = HeaderBuffer(8)
        buf = Vector{UInt8}("GET /async HTTP/1.1\r\nUser-A")
        first_len = length(buf)

        @test parse_request_head!(hb, buf, 0) === :partial
        @test !isdone(hb)
        @test ispartial(hb)
        @test !iserror(hb)
        @test length(hb) == 0

        append!(buf, Vector{UInt8}("gent: Julia\r\n\r\n"))
        @test parse_request_head!(hb, buf, first_len) === :done
        @test isdone(hb)
        @test !ispartial(hb)
        @test request_method(hb, buf) == "GET"
        @test request_target(hb, buf) == "/async"
        @test head_length(hb) == length(buf)
        @test header(hb, buf, "user-agent") == "Julia"
    end

    @testset "Request Head - survives buffer growth" begin
        hb = HeaderBuffer(8)
        raw = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n"
        buf = make_buf(raw)
        @test parse_request_head!(hb, buf) === :done

        # Growing/reallocating the buffer must not invalidate parsed views:
        # they are offset-based, not absolute pointers.
        append!(buf, make_buf("data"))
        sizehint!(buf, 1_000_000)
        resize!(buf, 1_000_000)

        @test request_method(hb, buf) == "POST"
        @test request_target(hb, buf) == "/upload"
        @test head_length(hb) == findfirst("\r\n\r\n", raw)[1] + 3
        @test header(hb, buf, "host") == "x"
        @test header(hb, buf, "content-length") == "4"
        @test length(hb) == 2
    end

    @testset "Request Head - malformed" begin
        hb = HeaderBuffer(8)
        buf = make_buf("GET / HTTP/1.1\r\nNotAHeader\r\n\r\n")
        @test parse_request_head!(hb, buf) === :error
        @test iserror(hb)
        @test !isdone(hb)
        @test !ispartial(hb)
        @test length(hb) == 0
    end

    @testset "Malformed input throws HTTPParseError" begin
        @test_throws HTTPParseError parse_request(make_buf("NOT A REQUEST\r\n\r\n"))
        @test_throws HTTPParseError parse_headers(make_buf("NotAHeader\r\n\r\n"))
        @test_throws HTTPParseError parse_response(make_buf("NOT A RESPONSE\r\n\r\n"))
    end

    @testset "Response Head - incremental" begin
        hb = HeaderBuffer(8)
        raw = "HTTP/1.1 201 Created\r\nServer: Pico\r\nContent-Length: 4\r\n\r\nWiki"
        buf = make_buf(raw)

        @test parse_response_head!(hb, buf) === :done
        @test isdone(hb)
        @test status_code(hb) == 201
        @test reason_phrase(hb, buf) == "Created"
        @test minor_version(hb) == 1
        @test head_length(hb) == findfirst("\r\n\r\n", raw)[1] + 3
        @test length(hb) == 2
        @test header(hb, buf, "server") == "Pico"
        @test isempty(HeaderBuffer(4))

        # whole-message parse reusing caller scratch
        res = parse_response(hb, buf)
        @test res !== nothing
        @test res.status_code == 201
        @test res.reason_phrase == "Created"
        @test String(res.body) == "Wiki"
    end

    @testset "Response Head - partial and malformed" begin
        hb = HeaderBuffer(8)
        buf = make_buf("HTTP/1.1 200 O")
        first_len = length(buf)
        @test parse_response_head!(hb, buf) === :partial
        @test ispartial(hb)

        append!(buf, make_buf("K\r\nServer: x\r\n\r\n"))
        @test parse_response_head!(hb, buf, first_len) === :done
        @test status_code(hb) == 200
        @test reason_phrase(hb, buf) == "OK"

        @test parse_response_head!(HeaderBuffer(4), make_buf("NOT A RESPONSE\r\n\r\n")) === :error
    end

    @testset "Field section parsing (!)" begin
        hb = HeaderBuffer(4)
        raw = "Host: example.com\r\nAccept: */*\r\n\r\n"
        buf = make_buf(raw)

        @test parse_headers!(hb, buf) === :done
        @test isdone(hb)
        @test length(hb) == 2
        @test hb[1, buf] == ("Host" => "example.com")
        @test length(parse_headers(hb, buf)) == 2

        @test parse_headers!(HeaderBuffer(4), make_buf("Host: exam")) === :partial
    end

    @testset "Response views survive buffer growth" begin
        hb = HeaderBuffer(8)
        buf = make_buf("HTTP/1.1 200 OK\r\nServer: Pico\r\n\r\n")
        @test parse_response_head!(hb, buf) === :done

        sizehint!(buf, 1_000_000)
        resize!(buf, 1_000_000)

        @test status_code(hb) == 200
        @test reason_phrase(hb, buf) == "OK"
        @test header(hb, buf, "server") == "Pico"
    end

    @testset "Obs-fold continuation lines" begin
        hb = HeaderBuffer(8)
        raw = "GET / HTTP/1.1\r\nX-A: 1\r\n\tcontinued\r\nHost: x\r\n\r\n"
        buf = make_buf(raw)

        @test parse_request_head!(hb, buf) === :done
        @test length(hb) == 3
        @test header_name(hb, 2, buf) == ""          # NULL name → empty view
        @test header_value(hb, 2, buf) == "\tcontinued"  # raw, leading whitespace kept
        @test header(hb, buf, "host") == "x"

        # Whole-message path is fold-safe too.
        req = parse_request(buf)
        @test req !== nothing
        @test header(req, "Host") == "x"
    end

    @testset "Accessors reject stale state" begin
        hb = HeaderBuffer(8)
        respbuf = make_buf("HTTP/1.1 200 OK\r\nServer: x\r\n\r\n")
        reqbuf = make_buf("GET / HTTP/1.1\r\nHost: x\r\n\r\n")

        @test parse_response_head!(hb, respbuf) === :done
        @test status_code(hb) == 200

        # Switching parse kind clears response results.
        @test parse_request_head!(hb, reqbuf) === :done
        @test request_method(hb, reqbuf) == "GET"
        @test_throws ArgumentError status_code(hb)
        @test_throws ArgumentError reason_phrase(hb, reqbuf)

        # Partial and error states expose no results.
        partial = make_buf("GET / HTTP/1.1\r\nHos")
        @test parse_request_head!(hb, partial) === :partial
        @test ispartial(hb)
        @test isempty(hb)
        @test_throws ArgumentError head_length(hb)
        @test_throws ArgumentError request_method(hb, partial)

        bad = make_buf("GET / HTTP/1.1\r\nNotAHeader\r\n\r\n")
        @test parse_request_head!(hb, bad) === :error
        @test_throws ArgumentError request_method(hb, bad)

        # Field sections carry no HTTP version.
        @test parse_headers!(hb, make_buf("Host: x\r\n\r\n")) === :done
        @test_throws ArgumentError minor_version(hb)
    end

    @testset "Header index bounds" begin
        hb = HeaderBuffer(8)
        buf = make_buf("GET / HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\n")
        @test parse_request_head!(hb, buf) === :done
        @test_throws BoundsError header_name(hb, 0, buf)
        @test_throws BoundsError header_name(hb, 3, buf)
        @test_throws BoundsError header_value(hb, 3, buf)
        @test_throws BoundsError hb[3, buf]
    end

    @testset "Whole-message framing (Content-Length only)" begin
        # No Content-Length → empty body.
        req = parse_request(make_buf("GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
        @test req !== nothing
        @test isempty(req.body)

        # Reusable-scratch whole-message request path.
        hb = HeaderBuffer(8)
        req2 = parse_request(hb, make_buf("POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc"))
        @test req2 !== nothing
        @test String(req2.body) == "abc"

        # Chunked is rejected, not silently body-less.
        @test_throws ArgumentError parse_request(make_buf(
            "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))
        @test_throws ArgumentError parse_response(make_buf(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))

        # Responses without Content-Length and bodyless statuses.
        res = parse_response(make_buf("HTTP/1.1 200 OK\r\n\r\n"))
        @test res !== nothing && isempty(res.body)

        res304 = parse_response(make_buf("HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n"))
        @test res304 !== nothing
        @test res304.status_code == 304
        @test isempty(res304.body)

        # Duplicate / invalid Content-Length are rejected.
        @test_throws HTTPParseError parse_request(make_buf(
            "POST /x HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na"))
        @test_throws HTTPParseError parse_request(make_buf(
            "POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n"))

        # Strict helper.
        hbuf = make_buf("Content-Length: 5\r\n\r\n")
        hb3 = HeaderBuffer(4)
        @test parse_headers!(hb3, hbuf) === :done
        @test content_length(hb3, hbuf) == 5

        nbuf = make_buf("Host: x\r\n\r\n")
        @test parse_headers!(hb3, nbuf) === :done
        @test content_length(hb3, nbuf) === nothing
    end

    @testset "Content-Length strictness (1*DIGIT)" begin
        function cl(v)
            buf = make_buf("Content-Length: " * v * "\r\n\r\n")
            h = HeaderBuffer(4)
            @test parse_headers!(h, buf) === :done
            return content_length(h, buf)
        end

        @test cl("0") == 0
        @test cl("5") == 5
        @test cl("005") == 5
        @test cl("9223372036854775807") == typemax(Int)

        # tryparse(Int, ...) would accept these Julia literals; HTTP must not.
        for bad in ("+5", "-0", "-5", "0x5", "0b101", "0o17", "1_0",
                    "5, 5", "5,5", "abc", "", " ", "9223372036854775808",
                    "99999999999999999999")
            @test_throws HTTPParseError cl(bad)
        end

        # Whitespace around the value is OWS and still accepted.
        @test cl("5 ") == 5
        @test cl("\t5") == 5   # pico skips leading OWS after the colon
    end

    @testset "Head parsers - steady-state zero allocation" begin
        hb = HeaderBuffer(16)
        reqbuf = make_buf("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        respbuf = make_buf("HTTP/1.1 200 OK\r\nServer: x\r\n\r\n")
        hdrsbuf = make_buf("Host: x\r\nAccept: */*\r\n\r\n")
        parse_request_head!(hb, reqbuf)    # warmup
        parse_response_head!(hb, respbuf)
        parse_headers!(hb, hdrsbuf)

        @test (@allocated parse_request_head!(hb, reqbuf)) == 0
        @test (@allocated parse_response_head!(hb, respbuf)) == 0
        @test (@allocated parse_headers!(hb, hdrsbuf)) == 0
    end

    @testset "Request Head - steady-state zero allocation" begin
        hb = HeaderBuffer(16)
        buf = make_buf("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        parse_request_head!(hb, buf)   # warmup

        @test (@allocated parse_request_head!(hb, buf)) == 0
        @test (@allocated request_method(hb, buf)) == 0

        # Views consumed in place must not allocate either.
        function _sum_header_bytes(hb, buf)
            n = 0
            for i in 1:length(hb)
                n += ncodeunits(header_name(hb, i, buf))
                n += ncodeunits(header_value(hb, i, buf))
            end
            return n
        end
        function _header_len(hb, buf, key)
            v = header(hb, buf, key)
            return v === nothing ? 0 : ncodeunits(v)
        end
        _sum_header_bytes(hb, buf)   # warmup
        _header_len(hb, buf, "host")
        @test (@allocated _sum_header_bytes(hb, buf)) == 0
        @test (@allocated _header_len(hb, buf, "host")) == 0
    end

    @testset "Zero-Copy Safety (GC Pressure)" begin
        # This test tries to force a GC crash if the pointer logic is wrong.
        raw = "GET /gc-test HTTP/1.1\r\nHeader: Value\r\n\r\n"
        buf = make_buf(raw)

        # Force GC before and after parsing
        GC.gc()
        req = parse_request(buf)
        GC.gc()

        # Access the views after GC to ensure memory is still valid
        @test req.method == "GET"
        @test req.target == "/gc-test"

        # Create "memory pressure" to trigger GC aggressive cleanup
        x = [zeros(1000) for _ in 1:100]
        GC.gc()

        @test header(req, "Header") == "Value"
    end
end

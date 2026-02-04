using Test
using PicoHTTPParser
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
        @test req.path == "/index.html"
        @test req.minor_version == 1

        # Test Header retrieval helper
        @test get_header(req, "Host") == "example.com"
        @test get_header(req, "User-Agent") == "Julia"
        @test isnothing(get_header(req, "Accept")) # Missing header

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
        @test req.path == "/async"
        @test get_header(req, "User-Agent") == "Julia"
        @test String(req.body) == "Hello"
    end

    @testset "Parse Response" begin
        raw = "HTTP/1.1 200 OK\r\nServer: Pico\r\nContent-Length: 4\r\n\r\nWiki"
        buf = make_buf(raw)

        res = parse_response(buf)

        @test res !== nothing
        @test res.status_code == 200
        @test res.reason == "OK"
        @test get_header(res, "Server") == "Pico"
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

        # 3. Incremental Parsing Optimization (using last_len)
        # This tests the 'last_len' parameter which tells the parser
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

        @test result.done == true
        @test String(result.data) == "Wiki"

        # Verify buffer modification (optional check)
        # The parser typically moves bytes to the front.
        # The first 4 bytes of buf should now be "Wiki".
        @test String(buf[1:4]) == "Wiki"
    end

    @testset "Chunked Decoding - Fragmented" begin
        # Simulate receiving chunks in two parts
        # Part 1: "4\r\nWi"
        # Part 2: "ki\r\n0\r\n\r\n"

        decoder = ChunkedDecoder()

        # --- Part 1 ---
        buf1 = make_buf("4\r\nWi")
        res1 = decode_chunked!(decoder, buf1)

        @test res1.done == false
        @test String(res1.data) == "Wi" # It decoded the available bytes

        # --- Part 2 ---
        # Note: In a real server, you handle the state.
        # Here we just feed the next buffer.
        buf2 = make_buf("ki\r\n0\r\n\r\n")

        # We need to tell the decoder we are continuing?
        # PicoHTTPParser stores state in `decoder.bytes_left_in_chunk`

        res2 = decode_chunked!(decoder, buf2)

        @test res2.done == true
        @test String(res2.data) == "ki"

        # Total data would be concatenation of res1.data and res2.data
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
        @test req.path == "/gc-test"

        # Create "memory pressure" to trigger GC aggressive cleanup
        x = [zeros(1000) for _ in 1:100]
        GC.gc()

        @test get_header(req, "Header") == "Value"
    end
end

using Test
using PicoHTTPParser

@testset "PicoHTTPParser Tests" begin

    # -------------------------------------------------
    # 1. parse_request()
    # -------------------------------------------------
    @testset "parse_request" begin
        message = """GET /index.html HTTP/1.1\r
        Host: example.com\r
        User-Agent: TestClient/1.0\r
        Accept: */*\r
        \r
        """
        parsed = parse_request(message)

        @test parsed.method == "GET"
        @test parsed.path == "/index.html"
        @test parsed.minor_version == 1
        @test parsed.headers["Host"] == "example.com"
        @test parsed.headers["User-Agent"] == "TestClient/1.0"
        @test parsed.headers["Accept"] == "*/*"

        # Error case: incomplete request
        bad_req = "GET / HTTP/1."
        @test_throws ErrorException parse_request(bad_req)
    end

    # -------------------------------------------------
    # 2. parse_response()
    # -------------------------------------------------
    @testset "parse_response" begin
        message = """HTTP/1.1 200 OK\r
        Content-Type: text/plain\r
        Content-Length: 5\r
        \r
        Hello"""
        parsed = parse_response(message)

        @test parsed.status_code == 200
        @test parsed.reason == "OK"
        @test parsed.minor_version == 1
        @test parsed.headers["Content-Type"] == "text/plain"
        @test parsed.headers["Content-Length"] == "5"

        # Error case
        bad_resp = "HTTP/1.1"
        @test_throws ErrorException parse_response(bad_resp)
    end

    # -------------------------------------------------
    # 3. parse_headers()
    # -------------------------------------------------
    @testset "parse_headers" begin
        message = """Host: example.com\r
        User-Agent: curl/7.68.0\r
        \r
        """
        parsed = parse_headers(message)

        @test parsed["Host"] == "example.com"
        @test parsed["User-Agent"] == "curl/7.68.0"
    end

    # -------------------------------------------------
    # 4. decode_chunked!()
    # -------------------------------------------------
    @testset "decode_chunked!" begin
        # Example chunked body:
        # "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n" => "Wikipedia"
        data = Vector{UInt8}("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n")
        decoder = ChunkedDecoder()
        decoded = decode_chunked!(decoder, data)

        @test decoded.done == true
        @test String(decoded.data) == "Wikipedia"

        # Incomplete chunk (need more data)
        partial_data = Vector{UInt8}("4\r\nWi")
        decoder2 = ChunkedDecoder()
        decoded2 = decode_chunked!(decoder2, partial_data)
        @test decoded2.done == false
    end

    # -------------------------------------------------
    # 5. Edge cases
    # -------------------------------------------------
    @testset "Edge cases" begin
        # Empty input
        @test_throws ErrorException parse_request("")
        @test_throws ErrorException parse_response("")
    end

end

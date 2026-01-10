using Test
using PicoHTTPParser
using StringViews

function get_header(headers, key)
    for (k, v) in headers
        if lowercase(String(k)) == lowercase(key)
            return v
        end
    end
    return nothing
end

@testset "PicoHTTPParser Tests" begin

    # -------------------------------------------------
    # 1. parse_request()
    # -------------------------------------------------
    @testset "parse_request" begin
        # PicoHTTPParser is strict about \r\n
        message_clean = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nUser-Agent: TestClient/1.0\r\nAccept: */*\r\n\r\n"

        parsed = parse_request(message_clean)

        @test parsed !== nothing
        @test parsed.method == "GET"
        @test parsed.path == "/index.html"
        @test parsed.minor_version == 1

        # Check types
        @test parsed.method isa StringView

        @test get_header(parsed.headers, "Host") == "example.com"
        @test get_header(parsed.headers, "User-Agent") == "TestClient/1.0"
        @test get_header(parsed.headers, "Accept") == "*/*"

        # Partial request
        partial = "GET /index.html HTTP/1.1\r\nHost: exam"
        @test parse_request(partial) === nothing

        # Test body
        body_req = "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nHello"
        parsed_body = parse_request(body_req)
        @test parsed_body.body == Vector{UInt8}("Hello") # Comparison works with View? (Vector == View works?)
        @test String(parsed_body.body) == "Hello"

        # Partial body
        partial_body = "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nHello"
        @test parse_request(partial_body) === nothing
    end

    # -------------------------------------------------
    # 2. parse_response()
    # -------------------------------------------------
    @testset "parse_response" begin
        message = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nHello"
        parsed = parse_response(message)

        @test parsed !== nothing
        @test parsed.status_code == 200
        @test parsed.reason == "OK"
        @test parsed.minor_version == 1
        @test get_header(parsed.headers, "Content-Type") == "text/plain"
        @test get_header(parsed.headers, "Content-Length") == "5"
        @test String(parsed.body) == "Hello"

        # Partial
        bad_resp = "HTTP/1.1 200 OK\r\nContent-Type: text"
        @test parse_response(bad_resp) === nothing
    end

    # -------------------------------------------------
    # 3. parse_headers()
    # -------------------------------------------------
    @testset "parse_headers" begin
        message = "Host: example.com\r\nUser-Agent: curl/7.68.0\r\n\r\n"
        parsed = parse_headers(message)

        @test parsed !== nothing
        @test get_header(parsed, "Host") == "example.com"
        @test get_header(parsed, "User-Agent") == "curl/7.68.0"

        # Partial
        @test parse_headers("Host: exa") === nothing
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
        @test parse_request("") === nothing
        @test parse_response("") === nothing
    end

end

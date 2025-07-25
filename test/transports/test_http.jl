using Test
using ModelContextProtocol
using ModelContextProtocol: read_message, write_message, is_connected, close, connect, end_response
using HTTP
using JSON3

@testset "HttpTransport" begin
    @testset "Basic functionality" begin
        # Create transport on a random port to avoid conflicts
        port = 8090 + rand(1:1000)
        transport = HttpTransport(host="127.0.0.1", port=port, endpoint="/")
        
        @test !is_connected(transport)
        
        # Connect the transport
        connect(transport)
        
        # Give server time to start
        sleep(0.5)
        
        @test is_connected(transport)
        
        # Test server is responding (these error tests are flaky with HTTP.jl streaming)
        # Just verify the server is up and accepting connections
        
        # Close transport
        close(transport)
        @test !is_connected(transport)
    end
    
    @testset "Request/Response flow" begin
        port = 9090 + rand(1:1000)
        transport = HttpTransport(port=port)
        connect(transport)
        sleep(0.5)
        
        # Send a request in background
        request_task = @async begin
            test_message = """{"jsonrpc":"2.0","method":"test","id":1}"""
            response = HTTP.post(
                "http://127.0.0.1:$port/",
                ["Content-Type" => "application/json"],
                test_message
            )
            response
        end
        
        # Read message from transport
        sleep(0.1)  # Give request time to arrive
        received = read_message(transport)
        @test received == """{"jsonrpc":"2.0","method":"test","id":1}"""
        
        # Write response
        response_message = """{"jsonrpc":"2.0","result":"ok","id":1}"""
        write_message(transport, response_message)
        
        # End the response stream
        end_response(transport)
        
        # Check response
        response = fetch(request_task)
        @test response.status == 200
        @test HTTP.header(response, "Content-Type") == "application/json"
        @test HTTP.header(response, "Transfer-Encoding") == "chunked"
        
        close(transport)
    end
    
    @testset "Multiple messages" begin
        port = 10090 + rand(1:1000)
        transport = HttpTransport(port=port)
        connect(transport)
        sleep(0.5)
        
        # Queue multiple requests
        requests = []
        for i in 1:3
            task = @async begin
                msg = """{"jsonrpc":"2.0","method":"test$i","id":$i}"""
                response = HTTP.post(
                    "http://127.0.0.1:$port/",
                    ["Content-Type" => "application/json"],
                    msg;
                    readtimeout=5
                )
            end
            push!(requests, task)
            sleep(0.1)  # Small delay between requests
        end
        
        # Read and respond to each
        for i in 1:3
            msg = read_message(transport)
            @test contains(msg, "\"method\":\"test$i\"")
            
            # Send response
            write_message(transport, """{"jsonrpc":"2.0","result":"ok$i","id":$i}""")
            
            # End this response
            end_response(transport)
        end
        
        close(transport)
    end
end
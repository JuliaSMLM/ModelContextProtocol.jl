using Test
using ModelContextProtocol
using ModelContextProtocol: read_message, write_message, is_connected, close, connect
using ModelContextProtocol: send_notification, broadcast_to_sse, format_sse_event
using HTTP
using JSON3

@testset "Streamable HTTP Transport" begin
    @testset "SSE Event Formatting" begin
        # Test basic event formatting
        event = format_sse_event("test data")
        @test event == "data: test data\n\n"
        
        # Test with event type
        event = format_sse_event("test data", event="message")
        @test contains(event, "event: message")
        @test contains(event, "data: test data")
        
        # Test with ID
        event = format_sse_event("test data", id=123)
        @test contains(event, "id: 123")
        @test contains(event, "data: test data")
        
        # Test multiline data
        multiline = "line1\nline2\nline3"
        event = format_sse_event(multiline)
        @test contains(event, "data: line1")
        @test contains(event, "data: line2")
        @test contains(event, "data: line3")
    end
    
    @testset "Session Management" begin
        port = 11090 + rand(1:1000)
        transport = HttpTransport(port=port)
        connect(transport)
        sleep(0.5)
        
        # Initially no session
        @test isnothing(transport.session_id)
        
        # Send initialization request
        init_request = """{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}"""
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json"],
            init_request
        )
        
        # Check session ID is generated
        @test !isnothing(transport.session_id)
        
        # Check session ID in response header
        session_header = HTTP.header(response, "Mcp-Session-Id", "")
        @test !isempty(session_header)
        @test session_header == transport.session_id
        
        close(transport)
    end
    
    @testset "Notification Handling (202 Accepted)" begin
        port = 12090 + rand(1:1000)
        transport = HttpTransport(port=port)
        connect(transport)
        sleep(0.5)
        
        # Send a notification (no ID field)
        notification = """{"jsonrpc":"2.0","method":"test_notification","params":{}}"""
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json"],
            notification
        )
        
        # Should return 202 Accepted for notifications
        @test response.status == 202
        
        # Response body should be empty for notifications
        @test isempty(String(response.body))
        
        close(transport)
    end
    
    @testset "SSE Stream Connection" begin
        port = 13090 + rand(1:1000)
        transport = HttpTransport(port=port)
        connect(transport)
        sleep(0.5)
        
        # Connect SSE stream in background
        sse_task = @async begin
            events = String[]
            try
                HTTP.get(
                    "http://127.0.0.1:$port/",
                    ["Accept" => "text/event-stream"];
                    readtimeout=3
                ) do stream
                    # Read a few events
                    for line in eachline(stream)
                        push!(events, line)
                        if length(events) > 5
                            break
                        end
                    end
                end
            catch e
                # Expected timeout or connection close
            end
            events
        end
        
        # Give SSE connection time to establish
        sleep(1)
        
        # Broadcast a test message
        test_message = """{"test":"message"}"""
        broadcast_to_sse(transport, test_message, event="test")
        
        # Give time for message to be sent
        sleep(1)
        
        # Close transport to end SSE stream
        close(transport)
        
        # Check if we received events
        events = fetch(sse_task)
        @test length(events) > 0
        
        # Should have received connection event and our test message
        event_text = join(events, "\n")
        @test contains(event_text, "event: connection") || contains(event_text, "event: test")
    end
    
    @testset "Origin Validation" begin
        port = 14090 + rand(1:1000)
        # Create transport with restricted origins
        transport = HttpTransport(
            port=port,
            allowed_origins=["http://localhost:3000"]
        )
        connect(transport)
        sleep(0.5)
        
        # Request with allowed origin
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            [
                "Content-Type" => "application/json",
                "Origin" => "http://localhost:3000"
            ],
            """{"jsonrpc":"2.0","method":"test","id":1}"""
        )
        @test response.status != 403
        
        # Request with disallowed origin
        try
            response = HTTP.post(
                "http://127.0.0.1:$port/",
                [
                    "Content-Type" => "application/json",
                    "Origin" => "http://evil.com"
                ],
                """{"jsonrpc":"2.0","method":"test","id":1}"""
            )
            @test response.status == 403
        catch e
            if e isa HTTP.ExceptionRequest.StatusError
                @test e.response.status == 403
            else
                rethrow(e)
            end
        end
        
        close(transport)
    end
    
    @testset "Session Validation" begin
        port = 15090 + rand(1:1000)
        transport = HttpTransport(port=port)
        connect(transport)
        sleep(0.5)
        
        # Generate session through initialization
        transport.session_id = "test-session-123"
        
        # Request with correct session ID
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            [
                "Content-Type" => "application/json",
                "Mcp-Session-Id" => "test-session-123"
            ],
            """{"jsonrpc":"2.0","method":"test","id":1}"""
        )
        @test response.status != 401
        
        # Request with wrong session ID
        try
            response = HTTP.post(
                "http://127.0.0.1:$port/",
                [
                    "Content-Type" => "application/json",
                    "Mcp-Session-Id" => "wrong-session"
                ],
                """{"jsonrpc":"2.0","method":"test","id":1}"""
            )
            @test response.status == 401
        catch e
            if e isa HTTP.ExceptionRequest.StatusError
                @test e.response.status == 401
            else
                rethrow(e)
            end
        end
        
        close(transport)
    end
end
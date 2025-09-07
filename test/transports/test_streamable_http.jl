@testset "Streamable HTTP Transport" begin
    @testset "SSE Event Formatting" begin
        # Test basic event formatting
        event = ModelContextProtocol.format_sse_event("test data")
        @test event == "data: test data\n\n"
        
        # Test with event type
        event = ModelContextProtocol.format_sse_event("test data", event="message")
        @test contains(event, "event: message")
        @test contains(event, "data: test data")
        
        # Test with ID
        event = ModelContextProtocol.format_sse_event("test data", id=123)
        @test contains(event, "id: 123")
        @test contains(event, "data: test data")
        
        # Test multiline data
        multiline = "line1\nline2\nline3"
        event = ModelContextProtocol.format_sse_event(multiline)
        @test contains(event, "data: line1")
        @test contains(event, "data: line2")
        @test contains(event, "data: line3")
    end
    
    @testset "Session ID Generation" begin
        # Test session ID generation
        session_id = ModelContextProtocol.generate_session_id()
        @test !isempty(session_id)
        @test ModelContextProtocol.is_valid_session_id(session_id)
        
        # Test invalid session IDs
        @test !ModelContextProtocol.is_valid_session_id("")
        @test !ModelContextProtocol.is_valid_session_id("has spaces")
        @test !ModelContextProtocol.is_valid_session_id("has\nnewline")
        @test !ModelContextProtocol.is_valid_session_id("has\ttab")
        
        # Test valid session IDs
        @test ModelContextProtocol.is_valid_session_id("valid-session-123")
        @test ModelContextProtocol.is_valid_session_id("UUID-1234-5678-90AB")
    end
    
    @testset "SSE Streaming" begin
        port = 13090 + rand(1:1000)
        
        transport = HttpTransport(port=port)
        
        # Create a tool that simulates streaming
        stream_tool = MCPTool(
            name = "stream_test",
            description = "Test streaming",
            handler = function(params)
                return TextContent(text = "Stream response")
            end,
            parameters = []  # No parameters for this tool
        )
        
        server = mcp_server(
            name = "sse-test-server",
            version = "1.0.0",
            tools = [stream_tool]
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        
        server_task = @async start!(server)
        sleep(2)
        
        # Initialize first
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-06-18",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        
        @test response.status == 200
        session_id = HTTP.header(response, "Mcp-Session-Id", "")
        
        # Test SSE connection
        sse_task = @async begin
            events = String[]
            try
                HTTP.open("GET", "http://127.0.0.1:$port/",
                         ["Accept" => "text/event-stream"]) do io
                    # Read up to 10 lines or timeout
                    for i in 1:10
                        if eof(io)
                            break
                        end
                        line = readline(io)
                        if !isempty(line)
                            push!(events, line)
                        end
                    end
                end
            catch e
                # Expected timeout or connection close
            end
            events
        end
        
        # Give SSE time to connect
        sleep(0.5)
        
        # SSE should have received connection event
        events = fetch(sse_task)
        @test length(events) > 0
        event_text = join(events, "\n")
        @test contains(event_text, "event: connection") || contains(event_text, "connected")
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
    
    @testset "Origin Validation" begin
        port = 14090 + rand(1:1000)
        
        # Create transport with restricted origins
        transport = HttpTransport(
            port=port,
            allowed_origins=["http://localhost:3000", "http://127.0.0.1:3000"]
        )
        
        server = mcp_server(
            name = "origin-test",
            version = "1.0.0"
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        
        server_task = @async start!(server)
        sleep(2)
        
        # Request with allowed origin
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Origin" => "http://localhost:3000",
             "MCP-Protocol-Version" => "2025-06-18",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        
        @test response.status == 200
        
        # Request with disallowed origin
        try
            response = HTTP.post(
                "http://127.0.0.1:$port/",
                ["Content-Type" => "application/json",
                 "Origin" => "http://evil.com",
                 "MCP-Protocol-Version" => "2025-06-18",
                 "Accept" => "application/json, text/event-stream"],
                JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "method" => "initialize",
                    "params" => Dict(
                        "protocolVersion" => "2025-06-18",
                        "capabilities" => Dict(),
                        "clientInfo" => Dict("name" => "test", "version" => "1.0")
                    ),
                    "id" => 2
                ))
            )
            @test response.status == 403
        catch e
            if e isa HTTP.ExceptionRequest.StatusError
                @test e.response.status == 403
            else
                # Rethrow unexpected errors
                rethrow(e)
            end
        end
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
    
    @testset "Protocol Version Validation" begin
        port = 15090 + rand(1:1000)
        
        transport = HttpTransport(port=port, protocol_version="2025-06-18")
        
        server = mcp_server(
            name = "version-test",
            version = "1.0.0"
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        
        server_task = @async start!(server)
        sleep(2)
        
        # First, properly initialize the server
        init_response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-06-18",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 0
            ))
        )
        @test init_response.status == 200
        session_id = HTTP.header(init_response, "Mcp-Session-Id", "")
        
        # Request with wrong protocol version header - should fail
        try
            response = HTTP.post(
                "http://127.0.0.1:$port/",
                ["Content-Type" => "application/json",
                 "MCP-Protocol-Version" => "2024-11-05",  # Wrong version
                 "Accept" => "application/json, text/event-stream"],
                JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "method" => "initialize",
                    "params" => Dict(
                        "protocolVersion" => "2025-06-18",
                        "capabilities" => Dict(),
                        "clientInfo" => Dict("name" => "test", "version" => "1.0")
                    ),
                    "id" => 1
                ))
            )
            @test false  # Should not succeed
        catch e
            if e isa HTTP.ExceptionRequest.StatusError
                @test e.response.status == 400  # Should return 400 for wrong protocol version
                # Verify the error message
                body = String(e.response.body)
                msg = JSON3.read(body)
                @test msg["error"]["code"] == -32602
                @test contains(msg["error"]["message"], "protocol version")
            else
                rethrow(e)
            end
        end
        
        # Request with wrong protocol version in params (but correct header)
        # This is a different case - the transport accepts it but the server should reject
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-06-18",
             "Mcp-Session-Id" => session_id,
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2024-11-05",  # Wrong version
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 2
            ))
        )
        
        # Should return error
        @test response.status == 200  # Still 200 for JSON-RPC errors
        result = JSON3.read(String(response.body))
        @test haskey(result, "error")
        @test result["error"]["code"] == -32602  # Invalid params
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
    
    @testset "Multiple Concurrent Requests" begin
        port = 16090 + rand(1:1000)
        
        transport = HttpTransport(port=port)
        
        # Create a slow tool to test concurrency
        slow_tool = MCPTool(
            name = "slow_tool",
            description = "Slow tool",
            handler = function(params)
                delay = get(params, "delay", 0.1)
                sleep(delay)
                return TextContent(text = "Done after $(delay)s")
            end,
            parameters = [
                ToolParameter(
                    name = "delay",
                    type = "number",
                    description = "Delay in seconds",
                    required = false
                )
            ]
        )
        
        server = mcp_server(
            name = "concurrent-test",
            version = "1.0.0",
            tools = [slow_tool]
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        
        server_task = @async start!(server)
        sleep(2)
        
        # Initialize
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-06-18",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        
        session_id = HTTP.header(response, "Mcp-Session-Id", "")
        
        # Send multiple concurrent requests
        tasks = []
        for i in 1:3
            task = @async begin
                response = HTTP.post(
                    "http://127.0.0.1:$port/",
                    ["Content-Type" => "application/json",
                     "Mcp-Session-Id" => session_id,
                     "Accept" => "application/json, text/event-stream"],
                    JSON3.write(Dict(
                        "jsonrpc" => "2.0",
                        "method" => "tools/call",
                        "params" => Dict(
                            "name" => "slow_tool",
                            "arguments" => Dict("delay" => 0.1)
                        ),
                        "id" => i + 1
                    ))
                )
                JSON3.read(String(response.body))
            end
            push!(tasks, task)
        end
        
        # Wait for all responses
        results = [fetch(task) for task in tasks]
        
        # All should succeed
        for (i, result) in enumerate(results)
            @test result["id"] == i + 1
            @test haskey(result, "result")
            @test result["result"]["content"][1]["text"] == "Done after 0.1s"
        end
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
end
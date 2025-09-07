@testset "HttpTransport" begin
    @testset "Basic HTTP Server" begin
        # Create a unique port to avoid conflicts
        port = 8090 + rand(1:1000)
        
        # Create transport 
        transport = HttpTransport(port=port)
        
        # Create server with tool
        test_tool = MCPTool(
            name = "test_tool",
            description = "Test tool",
            handler = function(params)
                return TextContent(text = "test response")
            end,
            parameters = []  # No parameters for this tool
        )
        
        server = mcp_server(
            name = "test-http-server",
            version = "1.0.0",
            tools = [test_tool]
        )
        
        # Set transport
        server.transport = transport
        
        # Connect transport
        ModelContextProtocol.connect(transport)
        
        # Start server in background
        server_task = @async start!(server)
        
        # Give server time to start (JIT compilation)
        sleep(2)
        
        # Test initialization
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
                    "clientInfo" => Dict("name" => "test-client", "version" => "1.0.0")
                ),
                "id" => 1
            ))
        )
        
        @test response.status == 200
        @test HTTP.header(response, "Content-Type") == "application/json"
        
        # Parse response
        result = JSON3.read(String(response.body))
        @test result["jsonrpc"] == "2.0"
        @test result["id"] == 1
        @test haskey(result, "result")
        @test result["result"]["protocolVersion"] == "2025-06-18"
        @test result["result"]["serverInfo"]["name"] == "test-http-server"
        
        # Get session ID for subsequent requests
        session_id = HTTP.header(response, "Mcp-Session-Id", "")
        @test !isempty(session_id)
        
        # Test tools/list
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Mcp-Session-Id" => session_id,
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "tools/list",
                "params" => Dict(),
                "id" => 2
            ))
        )
        
        @test response.status == 200
        result = JSON3.read(String(response.body))
        @test result["id"] == 2
        @test length(result["result"]["tools"]) == 1
        @test result["result"]["tools"][1]["name"] == "test_tool"
        
        # Stop server
        server.active = false
        ModelContextProtocol.close(transport)
        
        # Wait for server task to complete (with timeout)
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
    
    @testset "Tool Execution" begin
        port = 9090 + rand(1:1000)
        
        transport = HttpTransport(port=port)
        
        # Create a tool with parameters
        echo_tool = MCPTool(
            name = "echo",
            description = "Echo tool",
            parameters = [
                ToolParameter(
                    name = "message",
                    type = "string",
                    description = "Message to echo",
                    required = true
                )
            ],
            handler = function(params)
                msg = params["message"]
                return TextContent(text = "Echo: $msg")
            end
        )
        
        server = mcp_server(
            name = "test-server",
            version = "1.0.0",
            tools = [echo_tool]
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
        
        session_id = HTTP.header(response, "Mcp-Session-Id", "")
        
        # Call the tool
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Mcp-Session-Id" => session_id,
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "echo",
                    "arguments" => Dict("message" => "Hello MCP")
                ),
                "id" => 2
            ))
        )
        
        @test response.status == 200
        result = JSON3.read(String(response.body))
        @test result["id"] == 2
        @test result["result"]["content"][1]["text"] == "Echo: Hello MCP"
        @test result["result"]["is_error"] == false
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
    
    @testset "Session Management" begin
        port = 10090 + rand(1:1000)
        
        # Create transport with session requirement
        transport = HttpTransport(port=port, session_required=true)
        
        server = mcp_server(
            name = "session-test-server",
            version = "1.0.0"
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        server_task = @async start!(server)
        sleep(2)
        
        # First initialize to get session
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
        @test !isempty(session_id)
        
        # Try request without session (should fail)
        try
            response = HTTP.post(
                "http://127.0.0.1:$port/",
                ["Content-Type" => "application/json",
                 "Accept" => "application/json, text/event-stream"],
                JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "method" => "ping",
                    "params" => Dict(),
                    "id" => 2
                ))
            )
            @test response.status == 400  # Bad request without session
        catch e
            if e isa HTTP.ExceptionRequest.StatusError
                @test e.response.status == 400
            else
                # Unexpected error
                @test false
            end
        end
        
        # Try with wrong session
        try
            response = HTTP.post(
                "http://127.0.0.1:$port/",
                ["Content-Type" => "application/json",
                 "Mcp-Session-Id" => "wrong-session-id",
                 "Accept" => "application/json, text/event-stream"],
                JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "method" => "ping",
                    "params" => Dict(),
                    "id" => 3
                ))
            )
            @test response.status == 401  # Unauthorized with wrong session
        catch e
            if e isa HTTP.ExceptionRequest.StatusError
                @test e.response.status == 401
            else
                @test false
            end
        end
        
        # Try with correct session (should work)
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Mcp-Session-Id" => session_id,
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "ping",
                "params" => Dict(),
                "id" => 4
            ))
        )
        
        @test response.status == 200
        result = JSON3.read(String(response.body))
        @test result["id"] == 4
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
    
    @testset "Notification Handling" begin
        port = 11090 + rand(1:1000)
        
        transport = HttpTransport(port=port)
        
        server = mcp_server(
            name = "notification-test",
            version = "1.0.0"
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        server_task = @async start!(server)
        sleep(2)
        
        # Send a notification (no id field)
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-06-18",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "notifications/initialized",
                "params" => Dict()
                # No id field - this is a notification
            ))
        )
        
        # Notifications should return 202 Accepted with no body
        @test response.status == 202
        @test isempty(String(response.body))
        
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
using Test
using ModelContextProtocol
using JSON3

@testset "Transport Defaults and Protocol Validation" begin
    @testset "Server defaults to StdioTransport" begin
        # Create a simple server
        config = ServerConfig(
            name = "test-server",
            version = "1.0.0"
        )
        server = Server(config)
        
        # Transport should be nothing initially
        @test isnothing(server.transport)
        
        # After start! is called (in a controlled way), it should use StdioTransport
        # We'll mock this by checking the behavior without actually starting the loop
        
        # Create custom IO for testing with CORRECT protocol version
        input = IOBuffer("""{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}""")
        output = IOBuffer()
        
        # Create server with custom transport
        test_transport = StdioTransport(input=input, output=output)
        server2 = Server(config, transport=test_transport)
        @test server2.transport === test_transport
    end
    
    @testset "mcp_server works without transport specification" begin
        # Test that the high-level API still works
        server = mcp_server(
            name = "backward-compat-test",
            tools = [
                MCPTool(
                    name = "test_tool",
                    description = "A test tool",
                    parameters = [],
                    handler = (params) -> TextContent(text = "test result")
                )
            ]
        )
        
        @test server isa Server
        @test server.config.name == "backward-compat-test"
        @test length(server.tools) == 1
        @test isnothing(server.transport)  # Should be set when start! is called
    end
    
    @testset "Server can process messages with transport abstraction" begin
        # Create a test server
        config = ServerConfig(name = "test-server")
        server = Server(config)
        
        # Create a simple tool
        tool = MCPTool(
            name = "echo",
            description = "Echo input",
            parameters = [
                ToolParameter(name = "message", type = "string", description = "Message to echo")
            ],
            handler = (params) -> TextContent(text = get(params, "message", ""))
        )
        register!(server, tool)
        
        # Test message processing
        state = ModelContextProtocol.ServerState()
        
        # Initialize request with correct protocol version
        init_msg = """{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
        response = ModelContextProtocol.process_message(server, state, init_msg)

        @test !isnothing(response)
        parsed = JSON3.read(response)
        @test parsed.jsonrpc == "2.0"
        @test parsed.id == 1
        @test haskey(parsed, :result)
        @test parsed.result.protocolVersion == "2025-11-25"
    end

    @testset "Protocol Version Negotiation" begin
        # Per MCP spec: If server supports client's version, respond with same version.
        # Otherwise respond with server's latest and let client decide.
        config = ServerConfig(name = "test-server")
        server = Server(config)
        state = ModelContextProtocol.ServerState()

        # Test with supported old version - server responds with SAME version
        old_protocol_msg = """{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
        response = ModelContextProtocol.process_message(server, state, old_protocol_msg)

        @test !isnothing(response)
        parsed = JSON3.read(response)
        @test parsed.jsonrpc == "2.0"
        @test parsed.id == 1
        @test haskey(parsed, :result)
        # Server responds with client's requested version (backwards compatible)
        @test parsed.result.protocolVersion == "2024-11-05"

        # Test with 2025-06-18 - should also be supported
        state2 = ModelContextProtocol.ServerState()
        june_msg = """{"jsonrpc":"2.0","method":"initialize","id":2,"params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
        response2 = ModelContextProtocol.process_message(server, state2, june_msg)
        parsed2 = JSON3.read(response2)
        @test parsed2.result.protocolVersion == "2025-06-18"

        # Test with unknown version - server responds with its latest
        state3 = ModelContextProtocol.ServerState()
        unknown_msg = """{"jsonrpc":"2.0","method":"initialize","id":3,"params":{"protocolVersion":"9999-99-99","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
        response3 = ModelContextProtocol.process_message(server, state3, unknown_msg)
        parsed3 = JSON3.read(response3)
        @test parsed3.result.protocolVersion == "2025-11-25"
    end
end
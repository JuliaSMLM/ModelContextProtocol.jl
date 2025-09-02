#!/usr/bin/env julia

# Simple Streamable HTTP MCP server for testing with inspector
# Implements MCP protocol version 2025-06-18

using ModelContextProtocol
using ModelContextProtocol: HttpTransport

# Create a simple echo tool
echo_tool = MCPTool(
    name = "echo",
    description = "Echo back the provided message",
    parameters = [
        ToolParameter(
            name = "message",
            type = "string",
            description = "Message to echo back",
            required = true
        )
    ],
    handler = function(params)
        message = params["message"]
        return TextContent(text = "Echo: $message")
    end
)

# Create a greeting tool with default parameter
greet_tool = MCPTool(
    name = "greet",
    description = "Generate a greeting message",
    parameters = [
        ToolParameter(
            name = "name",
            type = "string", 
            description = "Name to greet",
            required = true
        ),
        ToolParameter(
            name = "language",
            type = "string",
            description = "Language for greeting",
            required = false,
            default = "english"
        )
    ],
    handler = function(params)
        user_name = params["name"]
        language = get(params, "language", "english")
        
        greeting = if language == "spanish"
            "¡Hola, $(user_name)!"
        elseif language == "french"
            "Bonjour, $(user_name)!"
        else
            "Hello, $(user_name)!"
        end
        
        return TextContent(text = greeting)
    end
)

# Create Streamable HTTP transport
transport = HttpTransport(
    port = 3000,
    protocol_version = "2025-06-18"  # Current MCP protocol
)

# Create server with tools
server = mcp_server(
    name = "simple-streamable-http-server",
    version = "1.0.0",
    description = "Simple Streamable HTTP MCP server for testing",
    tools = [echo_tool, greet_tool]
)

# Set the transport
server.transport = transport

# Connect the transport (starts HTTP server)
ModelContextProtocol.connect(transport)

println("Starting Simple Streamable HTTP MCP Server on port 3000...")
println("Protocol Version: 2025-06-18")
println()
println("Test with MCP Inspector:")
println("  npx @modelcontextprotocol/inspector")
println("  Then connect to: http://localhost:3000/")
println()
println("Or test manually:")
println("  curl -X POST http://localhost:3000/ -H 'Content-Type: application/json' \\")
println("    -H 'MCP-Protocol-Version: 2025-06-18' \\")
println("    -d '{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{},\"id\":1}'")
println()
println("Press Ctrl+C to stop")

# Start the server
start!(server)
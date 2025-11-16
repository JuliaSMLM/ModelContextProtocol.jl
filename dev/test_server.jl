#!/usr/bin/env julia

# Quick test server for MCP client demonstration

using ModelContextProtocol
using ModelContextProtocol: HttpTransport
using Dates

# Create a simple calculator tool
add_tool = MCPTool(
    name = "add",
    description = "Add two numbers",
    parameters = [
        ToolParameter(
            name = "a",
            type = "number",
            description = "First number",
            required = true
        ),
        ToolParameter(
            name = "b",
            type = "number",
            description = "Second number",
            required = true
        )
    ],
    handler = function(params)
        a = params["a"]
        b = params["b"]
        result = a + b
        return TextContent(text = "Result: $result")
    end
)

# Create a time tool
get_time_tool = MCPTool(
    name = "get_current_time",
    description = "Get the current time",
    parameters = [],
    handler = function(params)
        current_time = now()
        return TextContent(text = "Current time: $current_time")
    end
)

# Create Streamable HTTP transport without session requirement initially
transport = HttpTransport(
    port = 8765,  # Using 8765 - less common than 8080, unlikely to conflict
    protocol_version = "2025-06-18",
    session_required = false  # Don't require session initially
)

# Create server with tools
server = mcp_server(
    name = "test-server",
    version = "1.0.0",
    description = "Test server for MCP client demonstration",
    tools = [add_tool, get_time_tool]
)

# Set the transport
server.transport = transport

# Connect the transport (starts HTTP server)
ModelContextProtocol.connect(transport)

println("Test MCP Server started on port 8765")
println("Ready for client connections...")
println()

# Start the server
start!(server)
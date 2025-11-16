#!/usr/bin/env julia

# Simple stdio MCP server for testing

using ModelContextProtocol
using Dates

# Create tools
add_tool = MCPTool(
    name = "add",
    description = "Add two numbers",
    parameters = [
        ToolParameter(name = "a", type = "number", description = "First number", required = true),
        ToolParameter(name = "b", type = "number", description = "Second number", required = true)
    ],
    handler = function(params)
        result = params["a"] + params["b"]
        return TextContent(text = "The sum is: $result")
    end
)

multiply_tool = MCPTool(
    name = "multiply",
    description = "Multiply two numbers",
    parameters = [
        ToolParameter(name = "x", type = "number", description = "First number", required = true),
        ToolParameter(name = "y", type = "number", description = "Second number", required = true)
    ],
    handler = function(params)
        result = params["x"] * params["y"]
        return TextContent(text = "The product is: $result")
    end
)

time_tool = MCPTool(
    name = "get_time",
    description = "Get current time",
    parameters = [],
    handler = function(params)
        return TextContent(text = "Current time: $(now())")
    end
)

# Create server
server = mcp_server(
    name = "test-stdio-server",
    version = "1.0.0",
    description = "Test stdio MCP server",
    tools = [add_tool, multiply_tool, time_tool]
)

# Start with stdio transport (default)
start!(server)
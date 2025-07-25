#!/usr/bin/env julia

# Example of running an MCP server with HTTP+SSE transport

using ModelContextProtocol

# Create a simple server with some tools
server = mcp_server(
    name = "http-example-server",
    version = "1.0.0",
    tools = [
        MCPTool(
            name = "echo",
            description = "Echo the input message",
            parameters = [
                ToolParameter(
                    name = "message",
                    type = "string", 
                    description = "Message to echo"
                )
            ],
            handler = function(params)
                message = get(params, "message", "No message provided")
                TextContent(text = "Echo: $message")
            end
        ),
        
        MCPTool(
            name = "get_time",
            description = "Get the current time",
            parameters = [],
            handler = function(params)
                TextContent(text = "Current time: $(now())")
            end
        )
    ]
)

# Create HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000,
    endpoint = "/"
)

println("Starting HTTP MCP server on http://127.0.0.1:3000")
println("Endpoint: POST http://127.0.0.1:3000/")
println()
println("Press Ctrl+C to stop the server")

# Start the server with HTTP transport
try
    # Start the server
    start!(server, transport=transport)
    
    # Keep the server running
    while ModelContextProtocol.is_connected(transport)
        sleep(1)
    end
catch e
    if !(e isa InterruptException)
        @error "Server error" exception=e
    end
finally
    # Ensure cleanup
    stop!(server)
end
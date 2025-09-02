#!/usr/bin/env julia

# Streamable HTTP MCP server demonstrating SSE streaming and sessions
# Following MCP protocol version 2025-03-26

using ModelContextProtocol
using ModelContextProtocol: HttpTransport, send_notification, broadcast_to_sse
using JSON3

# Create a tool that sends notifications
notification_tool = MCPTool(
    name = "send_notification",
    description = "Send a notification to all connected SSE clients",
    parameters = [
        ToolParameter(
            name = "message",
            type = "string",
            description = "Notification message to send",
            required = true
        ),
        ToolParameter(
            name = "type",
            type = "string",
            description = "Notification type",
            required = false,
            default = "info"
        )
    ],
    handler = function(params, ctx)
        message = params["message"]
        notif_type = get(params, "type", "info")
        
        # Create notification payload
        notification = JSON3.write(Dict(
            "jsonrpc" => "2.0",
            "method" => "notifications/custom",
            "params" => Dict(
                "type" => notif_type,
                "message" => message,
                "timestamp" => string(now())
            )
        ))
        
        # Send notification via SSE
        if isa(ctx.server.transport, HttpTransport)
            broadcast_to_sse(ctx.server.transport, notification, event="notification")
        end
        
        return TextContent(text = "Notification sent: $message")
    end
)

# Create a tool that demonstrates session awareness
session_info_tool = MCPTool(
    name = "get_session_info",
    description = "Get information about the current session",
    parameters = [],
    handler = function(params, ctx)
        transport = ctx.server.transport
        
        if isa(transport, HttpTransport)
            session_id = transport.session_id
            num_sse_streams = length(transport.sse_streams)
            event_count = transport.event_counter
            
            info = """
            Session ID: $(isnothing(session_id) ? "none" : session_id)
            Active SSE Streams: $num_sse_streams
            Events Sent: $event_count
            """
            
            return TextContent(text = info)
        else
            return TextContent(text = "Not using HTTP transport")
        end
    end
)

# Create a streaming data tool
stream_data_tool = MCPTool(
    name = "stream_data",
    description = "Stream data updates via SSE",
    parameters = [
        ToolParameter(
            name = "count",
            type = "number",
            description = "Number of updates to stream",
            required = false,
            default = 5
        ),
        ToolParameter(
            name = "interval",
            type = "number",
            description = "Interval between updates in seconds",
            required = false,
            default = 1.0
        )
    ],
    handler = function(params, ctx)
        count = Int(get(params, "count", 5))
        interval = get(params, "interval", 1.0)
        
        transport = ctx.server.transport
        if !isa(transport, HttpTransport)
            return TextContent(text = "Streaming requires HTTP transport")
        end
        
        # Start streaming in background
        @async begin
            for i in 1:count
                data = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "method" => "streaming/data",
                    "params" => Dict(
                        "index" => i,
                        "value" => rand(),
                        "timestamp" => string(now())
                    )
                ))
                
                broadcast_to_sse(transport, data, event="stream-data")
                sleep(interval)
            end
            
            # Send completion notification
            completion = JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "streaming/complete",
                "params" => Dict(
                    "total" => count,
                    "timestamp" => string(now())
                )
            ))
            broadcast_to_sse(transport, completion, event="stream-complete")
        end
        
        return TextContent(text = "Started streaming $count updates with $(interval)s interval")
    end
)

# Create Streamable HTTP transport with security settings
transport = HttpTransport(
    port = 3001,
    endpoint = "/",
    allowed_origins = ["http://localhost:3000", "http://localhost:3001"],  # Restrict origins
    protocol_version = "2025-03-26",  # Current MCP protocol version
    session_required = false  # Will be set to true after initialization
)

# Create server with tools
server = mcp_server(
    name = "streamable-http-demo",
    version = "1.0.0",
    description = "Streamable HTTP MCP server with SSE streaming and session management",
    tools = [notification_tool, session_info_tool, stream_data_tool]
)

# Set the transport
server.transport = transport

# Connect the transport (starts HTTP server)
ModelContextProtocol.connect(transport)

println("Starting Streamable HTTP MCP Server on port 3001...")
println("Protocol Version: 2025-03-26")
println()
println("Features demonstrated:")
println("  - Streamable HTTP transport (replaces deprecated HTTP+SSE)")
println("  - Server-Sent Events (SSE) for streaming")
println("  - Session management with Mcp-Session-Id header")
println("  - Protocol version negotiation (MCP-Protocol-Version)")
println("  - Origin validation for security")
println("  - Notification support (202 Accepted)")
println("  - Session validation (400 Bad Request for missing/invalid)")
println()
println("Test SSE stream:")
println("  curl -N -H 'Accept: text/event-stream' http://localhost:3001/")
println()
println("Test with session:")
println("  # Initialize and get session ID")
println("  curl -X POST http://localhost:3001/ -H 'Content-Type: application/json' \\")
println("    -d '{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{},\"id\":1}' -v")
println()
println("  # Use session ID in subsequent requests")
println("  curl -X POST http://localhost:3001/ -H 'Content-Type: application/json' \\")
println("    -H 'Mcp-Session-Id: <session-id-from-response>' \\")
println("    -d '{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":2}'")
println()
println("Test streaming:")
println("  # Open SSE connection in one terminal:")
println("  curl -N -H 'Accept: text/event-stream' http://localhost:3001/")
println()
println("  # In another terminal, trigger streaming:")
println("  curl -X POST http://localhost:3001/ -H 'Content-Type: application/json' \\")
println("    -d '{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"stream_data\",\"arguments\":{\"count\":10}},\"id\":3}'")
println()
println("Press Ctrl+C to stop")

# Start the server
start!(server)
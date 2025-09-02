# Transport Layer

ModelContextProtocol.jl supports multiple transport mechanisms for client-server communication, following the MCP specification.

## Overview

All transports use JSON-RPC 2.0 as the message format but differ in how messages are transmitted. The package provides a clean abstraction layer allowing servers to work with any transport implementation.

## Available Transports

### stdio Transport

The default transport for subprocess-based communication:

```julia
using ModelContextProtocol

# Create server with default stdio transport
server = mcp_server(
    name = "my-server",
    version = "1.0.0"
)

# Start server (uses StdioTransport by default)
start!(server)
```

**Features:**
- Reads from stdin, writes to stdout
- Newline-delimited JSON messages
- Simple subprocess model
- No configuration required

### Streamable HTTP Transport

A full-featured Streamable HTTP transport with Server-Sent Events (SSE) support following MCP protocol version 2025-03-26:

```julia
using ModelContextProtocol
using ModelContextProtocol: HttpTransport

# Create Streamable HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000,
    endpoint = "/",
    allowed_origins = ["http://localhost:3000"],
    protocol_version = "2025-03-26",  # Current MCP protocol version
    session_required = false  # Set to true to require sessions
)

# Create and start server
server = mcp_server(
    name = "http-server",
    version = "1.0.0"
)
server.transport = transport
ModelContextProtocol.connect(transport)
start!(server)
```

**Features:**
- Multiple concurrent client connections
- Server-Sent Events (SSE) for streaming
- Session management with `Mcp-Session-Id` header
- Protocol version negotiation via `MCP-Protocol-Version` header
- Origin validation for security
- Notification support (202 Accepted)
- Session ID validation (visible ASCII 0x21-0x7E)
- 400 Bad Request for missing/invalid sessions

## Streamable HTTP Transport Features

### Server-Sent Events (SSE)

SSE enables real-time streaming from server to clients:

```julia
# Client establishes SSE connection
curl -N -H 'Accept: text/event-stream' http://localhost:3000/

# Server can broadcast to all SSE clients
broadcast_to_sse(transport, message, event="notification")
```

### Session Management

Sessions provide connection persistence and state tracking:

1. Server generates session ID on initialization
2. Client includes `Mcp-Session-Id` header in requests
3. Server validates session for each request

```bash
# Initialize and get session
response=$(curl -X POST http://localhost:3000/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}')

# Extract session ID from response headers
session_id=$(echo "$response" | grep -i 'mcp-session-id' | cut -d' ' -f2)

# Use session in subsequent requests
curl -X POST http://localhost:3000/ \
  -H 'Content-Type: application/json' \
  -H "Mcp-Session-Id: $session_id" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":2}'
```

### Security Features

#### Origin Validation

Restrict which origins can connect:

```julia
transport = HttpTransport(
    port = 3000,
    allowed_origins = [
        "http://localhost:3000",
        "https://myapp.com"
    ]
)
```

#### Best Practices

1. **Bind to localhost** for local-only access:
   ```julia
   transport = HttpTransport(host="127.0.0.1")
   ```

2. **Use HTTPS in production** (configure via reverse proxy)

3. **Implement authentication** for sensitive operations

### Response Patterns

The Streamable HTTP transport follows MCP specification (2025-03-26) for responses:

- **Requests**: Return 200 OK with JSON-RPC response
- **Notifications**: Return 202 Accepted with no body
- **SSE Streams**: Return 200 OK with `text/event-stream`
- **Errors**: Return appropriate HTTP status with error details

## Streaming Data

Send real-time updates to clients via SSE:

```julia
# In a tool handler
function stream_updates(params, ctx)
    transport = ctx.server.transport
    
    # Send multiple updates
    for i in 1:10
        data = JSON3.write(Dict(
            "index" => i,
            "value" => rand()
        ))
        broadcast_to_sse(transport, data, event="data-update")
        sleep(0.5)
    end
    
    return TextContent(text="Streaming complete")
end
```

## Transport Selection

### Use stdio when:
- Building CLI tools
- Simple subprocess model sufficient
- Single client-server relationship
- Minimal setup required

### Use Streamable HTTP when:
- Multiple clients need to connect
- Server runs as standalone service
- Real-time streaming via SSE required
- Web-based clients need access
- Session persistence needed
- Protocol version negotiation required

## Custom Transports

Implement the `Transport` interface to create custom transports:

```julia
mutable struct MyTransport <: Transport
    # Transport state
end

# Required methods
read_message(t::MyTransport)::Union{String,Nothing}
write_message(t::MyTransport, msg::String)::Nothing
is_connected(t::MyTransport)::Bool
close(t::MyTransport)::Nothing

# Optional methods
connect(t::MyTransport)::Nothing
flush(t::MyTransport)::Nothing
```

## Examples

See the `examples/` directory for complete examples:
- `simple_http_server.jl` - Basic Streamable HTTP server
- `streamable_http_demo.jl` - Streamable HTTP with SSE streaming and sessions
- `time_server.jl` - stdio transport example

## Specification

The complete MCP transport specification is available at:
- Online: https://modelcontextprotocol.io/docs/concepts/transports
- Local: `docs/spec/mcp-transport-spec-v1.0.md`
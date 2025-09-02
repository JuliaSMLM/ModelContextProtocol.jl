# Transport Protocols

ModelContextProtocol.jl supports two transport protocols for communication between MCP servers and clients.

## stdio Transport

The stdio transport uses standard input and output streams for communication. This is the simplest transport method and works well for command-line applications and process-to-process communication.

### Basic Usage

```julia
using ModelContextProtocol

# Create a server with stdio transport (default)
server = mcp_server(
    name = "my-server",
    version = "1.0.0",
    tools = [my_tool]
)

# Start the server (uses stdio by default)
start!(server)
```

The server will read JSON-RPC messages from stdin and write responses to stdout.

## Streamable HTTP Transport

The Streamable HTTP transport implements the MCP protocol over HTTP with Server-Sent Events (SSE) support. This enables web-based clients and provides real-time streaming capabilities.

### Basic HTTP Server

```julia
using ModelContextProtocol
using ModelContextProtocol: HttpTransport

# Create HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000,
    protocol_version = "2025-06-18"
)

# Create server
server = mcp_server(
    name = "http-server",
    version = "1.0.0", 
    tools = [my_tool]
)

# Set transport and start
server.transport = transport
ModelContextProtocol.connect(transport)
start!(server)
```

### Configuration Options

The `HttpTransport` constructor accepts several configuration options:

```julia
transport = HttpTransport(
    host = "127.0.0.1",           # Bind address (localhost by default)
    port = 3000,                  # Port number
    endpoint = "/",               # Base endpoint path
    protocol_version = "2025-06-18",  # MCP protocol version
    session_required = true,      # Require session validation
    allowed_origins = ["http://localhost:8080"],  # CORS origins
    enable_sse = true            # Enable Server-Sent Events
)
```

### Session Management

HTTP transport uses session-based communication for security and state tracking:

1. **Initialization**: Client sends initialization request
2. **Session Creation**: Server responds with `Mcp-Session-Id` header  
3. **Subsequent Requests**: Client includes session ID in `Mcp-Session-Id` header

```bash
# Initialize and get session ID
curl -X POST http://localhost:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}' \
  -i

# Use session ID in subsequent requests  
curl -X POST http://localhost:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Mcp-Session-Id: <session-id-from-response>' \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}'
```

### Server-Sent Events (SSE)

The HTTP transport supports real-time streaming via Server-Sent Events:

```julia
# SSE is enabled by default in HttpTransport
transport = HttpTransport(enable_sse = true)
```

SSE streams provide:
- Real-time notifications to clients
- Progress updates for long-running operations  
- Event-based communication patterns
- Automatic reconnection support

### Security Features

#### Origin Validation

Control which origins can access your server:

```julia
transport = HttpTransport(
    allowed_origins = [
        "http://localhost:3000",
        "https://my-app.com"
    ]
)
```

#### Session Validation

Sessions provide security and state isolation:

```julia
# Require valid sessions for all non-initialization requests
transport = HttpTransport(session_required = true)

# Disable session requirement (less secure)
transport = HttpTransport(session_required = false)
```

### Error Handling

The HTTP transport returns appropriate HTTP status codes:

- `200 OK` - Successful requests with JSON response
- `202 Accepted` - Notification requests (no response body)
- `400 Bad Request` - Invalid session or malformed requests
- `404 Not Found` - Unknown endpoints
- `500 Internal Server Error` - Server-side errors

### Performance Considerations

For production deployments:

1. **Binding**: Use `host = "0.0.0.0"` to accept external connections
2. **Port Selection**: Avoid common ports; use application-specific ports
3. **Session Management**: Monitor session count and implement cleanup
4. **SSE Connections**: Limit concurrent SSE streams per client
5. **Origin Validation**: Always configure allowed origins in production

### Troubleshooting

#### Connection Issues

```julia
# Check if server is listening
using Sockets
@assert isopen(connect(transport.host, transport.port))
```

#### Session Problems

- Ensure `Mcp-Session-Id` header is included after initialization
- Check that session ID contains only visible ASCII characters (0x21-0x7E)
- Verify server hasn't restarted (sessions are lost on restart)

#### Protocol Version Mismatches

- Use `MCP-Protocol-Version: 2025-06-18` header in all requests
- Check server logs for protocol version negotiation messages
- Ensure client and server support the same protocol version

### Migration from stdio

To migrate from stdio to HTTP transport:

```julia
# Before (stdio)
server = mcp_server(name = "my-server", tools = [my_tool])
start!(server)

# After (HTTP)
transport = HttpTransport(port = 3000)
server = mcp_server(name = "my-server", tools = [my_tool])
server.transport = transport
ModelContextProtocol.connect(transport)
start!(server)
```

Key changes:
1. Create and configure `HttpTransport`
2. Set `server.transport` before starting
3. Call `ModelContextProtocol.connect(transport)` to start HTTP server
4. Update client code to use HTTP requests with session management

### Examples

See the `examples/` directory for complete working examples:
- `examples/streamable_http_basic.jl` - Simple HTTP server setup
- `examples/streamable_http_demo.jl` - Full-featured server with SSE
- `examples/streamable_http_advanced.jl` - Advanced configuration and usage
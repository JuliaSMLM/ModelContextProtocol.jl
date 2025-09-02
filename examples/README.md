# MCP Server Examples

This directory contains example implementations of MCP servers demonstrating various features and transport mechanisms.

## Transport Examples

### stdio Transport
- **`time_server.jl`** - Basic stdio server that provides time-related tools
  - Simple subprocess communication model
  - Good starting point for local MCP servers

### Streamable HTTP Transport
Following the MCP Streamable HTTP specification (protocol version 2025-03-26):

- **`simple_http_server.jl`** - Simplest Streamable HTTP server
  - Basic tools (echo, greet)
  - Minimal configuration
  - Good for testing with MCP Inspector

- **`streamable_http_basic.jl`** - Basic Streamable HTTP setup
  - Shows standard server configuration
  - Simple tool registration

- **`streamable_http_demo.jl`** - Full-featured Streamable HTTP demonstration
  - Server-Sent Events (SSE) streaming
  - Session management with `Mcp-Session-Id`
  - Protocol version negotiation
  - Security features (Origin validation)
  - Notification support (202 Accepted)
  - Real-time data streaming examples

- **`streamable_http_advanced.jl`** - Advanced HTTP usage
  - Direct HTTP API interaction
  - Low-level transport control
  - Custom request/response handling

## Feature Examples

- **`multi_content_tool.jl`** - Demonstrates tools returning multiple content types
  - Shows how to return text, images, and mixed content
  - Useful for complex tool responses

- **`test_http_client.jl`** - HTTP client for testing servers
  - Shows how to interact with MCP servers via HTTP
  - Useful for debugging and testing

- **`reg_dir.jl`** - Directory registration example
  - Shows resource management patterns

## Running Examples

### stdio Server
```bash
julia --project examples/time_server.jl
```

### Streamable HTTP Server
```bash
# Start the server
julia --project examples/simple_http_server.jl

# In another terminal, test with curl:
curl -X POST http://localhost:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-03-26' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}'

# Or use MCP Inspector:
npx @modelcontextprotocol/inspector
# Then connect to: http://localhost:3000/
```

### Testing SSE Streaming
```bash
# Start the streaming demo
julia --project examples/streamable_http_demo.jl

# Connect SSE client
curl -N -H 'Accept: text/event-stream' http://localhost:3001/

# Trigger streaming in another terminal
curl -X POST http://localhost:3001/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"stream_data"},"id":1}'
```

## Protocol Information

These examples implement the **Streamable HTTP** transport specification, which replaced the deprecated HTTP+SSE transport from protocol version 2024-11-05.

Current protocol version: **2025-03-26**

Key features of Streamable HTTP:
- Single endpoint for POST and GET
- Optional SSE for streaming
- Session management via headers
- Protocol version negotiation
- 202 Accepted for notifications

## Development Tips

1. Start with `simple_http_server.jl` for basic HTTP setup
2. Use `streamable_http_demo.jl` to understand advanced features
3. Test with MCP Inspector for visual debugging
4. Use curl for manual testing and debugging
5. Check server logs (stderr) for debugging information

## Security Notes

When deploying Streamable HTTP servers:
- Bind to localhost (127.0.0.1) for local-only access
- Implement Origin validation for web clients
- Use HTTPS in production (via reverse proxy)
- Add authentication as needed
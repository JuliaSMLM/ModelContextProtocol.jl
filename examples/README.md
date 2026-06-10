# MCP Server Examples

This directory contains example implementations of MCP servers demonstrating various features and transport mechanisms.

## Transport Examples

### stdio Transport
- **`time_server.jl`** - Basic stdio server that provides time-related tools
  - Simple subprocess communication model
  - Good starting point for local MCP servers

### Streamable HTTP Transport
Following the MCP Streamable HTTP specification (latest protocol version 2025-11-25):

- **`simple_http_server.jl`** - Simplest Streamable HTTP server
  - Basic tools (echo, greet)
  - Minimal configuration
  - Good for testing with MCP Inspector

- **`reg_dir_http.jl`** - Auto-registration over Streamable HTTP
  - Loads tools/resources/prompts from the `mcp_tools/` directory
  - Same component model as `reg_dir.jl`, served over HTTP

## Feature Examples

- **`multi_content_tool.jl`** - Demonstrates tools returning multiple content types
  - Shows how to return text, images, and mixed content
  - Useful for complex tool responses

- **`complex_schema_server.jl`** - Advanced JSON Schema tool inputs
  - Raw `input_schema` with arrays, enums, and nested objects

- **`task_server.jl`** - MCP Tasks demo (experimental)
  - Long-running tool executed in the background (`task_support = :optional`)
  - Status polling, blocking result retrieval, cooperative cancellation, progress

- **`reg_dir.jl`** - Directory registration example (stdio)
  - Auto-registers components from `mcp_tools/` subdirectories

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
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}'

# Or use MCP Inspector:
npx @modelcontextprotocol/inspector
# Then connect to: http://localhost:3000/
```

### Testing SSE Streaming
```bash
# Start an HTTP server
julia --project examples/simple_http_server.jl

# Connect an SSE client for server-to-client notifications
curl -N -H 'Accept: text/event-stream' http://localhost:3000/
```

## Protocol Information

These examples implement the **Streamable HTTP** transport specification, which replaced the deprecated HTTP+SSE transport from protocol version 2024-11-05.

Current protocol version: **2025-11-25** (negotiated per client, down to 2024-11-05)

Key features of Streamable HTTP:
- Single endpoint for POST and GET
- Optional SSE for streaming
- Session management via headers
- Protocol version negotiation
- 202 Accepted for notifications

## Development Tips

1. Start with `simple_http_server.jl` for basic HTTP setup
2. Use `reg_dir_http.jl` to understand component auto-registration over HTTP
3. Test with MCP Inspector for visual debugging
4. Use curl for manual testing and debugging
5. Check server logs (stderr) for debugging information

## Security Notes

When deploying Streamable HTTP servers:
- Bind to localhost (127.0.0.1) for local-only access
- Implement Origin validation for web clients
- Use HTTPS in production (via reverse proxy)
- Add authentication as needed
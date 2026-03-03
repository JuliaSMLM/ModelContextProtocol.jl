# Simple HTTP MCP Server - No OAuth
# Run: julia --project examples/simple_test_server.jl

using ModelContextProtocol
using ModelContextProtocol: HttpTransport

# Create a simple tool
echo_tool = MCPTool(
    name = "echo",
    description = "Echo a message",
    parameters = [ToolParameter(name = "message", type = "string", description = "Message")],
    handler = (params) -> TextContent(text = "Echo: $(params["message"])")
)

# Create HTTP transport WITHOUT OAuth
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3001
)

# Create server
server = mcp_server(
    name = "simple-test",
    version = "1.0.0",
    tools = [echo_tool]
)
server.transport = transport

println("""
Simple HTTP MCP Server on http://127.0.0.1:3001

Test with curl:
  curl -X POST http://127.0.0.1:3001/ \\
    -H 'Content-Type: application/json' \\
    -H 'MCP-Protocol-Version: 2025-11-25' \\
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

Press Ctrl+C to stop.
""")

ModelContextProtocol.connect(transport)
start!(server)

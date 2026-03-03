# Auth test server - creates a pre-authorized token for testing
# Run: julia --project examples/auth_test_server.jl

using ModelContextProtocol
using ModelContextProtocol: store_token!, IssuedToken, AuthenticatedUser,
    OAuthServerValidator, InMemoryTokenStorage, OAuthConfig, AuthMiddleware, HttpTransport
using Dates

# Create shared storage so we can pre-insert a token
storage = InMemoryTokenStorage()

# Pre-create a test token (bypasses OAuth flow for testing)
test_token = "test-token-12345"
user = AuthenticatedUser(
    subject = "github|12345",
    provider = "github",
    username = "testuser"
)
issued = IssuedToken(
    access_token = test_token,
    user = user,
    client_id = "test-client",
    resource = "http://127.0.0.1:3000",
    expires_at = Dates.now(Dates.UTC) + Dates.Hour(1)
)
store_token!(storage, issued)

# Create auth middleware using the same storage
config = OAuthConfig(
    issuer = "http://127.0.0.1:3000",
    audience = "http://127.0.0.1:3000"
)
validator = OAuthServerValidator(storage)
auth = AuthMiddleware(
    config = config,
    validator = validator,
    enabled = true
)

# Create tools
secret_tool = MCPTool(
    name = "secret_data",
    description = "Returns secret data (requires auth)",
    handler = (params) -> TextContent(text = "SECRET: The answer is 42")
)

echo_tool = MCPTool(
    name = "echo",
    description = "Echo a message",
    parameters = [ToolParameter(name = "message", type = "string", description = "Message to echo")],
    handler = (params) -> TextContent(text = "Echo: $(params["message"])")
)

# Create HTTP transport with auth
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000,
    auth = auth
)

# Create MCP server
server = mcp_server(
    name = "auth-test",
    version = "1.0.0",
    tools = [secret_tool, echo_tool]
)
server.transport = transport

# Connect transport
ModelContextProtocol.connect(transport)

println("""
Auth Test Server Running on http://127.0.0.1:3000

Pre-authorized test token: $test_token

Test commands:

1. Without auth (should fail with 401):
   curl -X POST http://127.0.0.1:3000/ -H "Content-Type: application/json" -H "MCP-Protocol-Version: 2025-11-25" -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

2. With auth (should work):
   curl -X POST http://127.0.0.1:3000/ -H "Content-Type: application/json" -H "Authorization: Bearer $test_token" -H "MCP-Protocol-Version: 2025-11-25" -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

Press Ctrl+C to stop.
""")

start!(server)

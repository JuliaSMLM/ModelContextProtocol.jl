# Test OAuth Server - No external credentials required
#
# This server uses TestUpstreamProvider to test OAuth flows without GitHub.
# Perfect for testing with Claude Code or other MCP clients.
#
# Run: julia --project examples/test_oauth_server.jl
#
# The OAuth flow:
# 1. Client discovers auth requirements via /.well-known/oauth-protected-resource
# 2. Client gets auth server metadata via /.well-known/oauth-authorization-server
# 3. Client registers itself via POST /register (DCR)
# 4. Client starts OAuth flow via /authorize -> auto-approves -> /callback
# 5. Client exchanges code for token via POST /token
# 6. Client uses token to access MCP endpoints

using ModelContextProtocol

# Create test upstream provider (auto-approves auth requests)
test_provider = TestUpstreamProvider(
    username = "testuser",
    user_id = "test-123",
    auto_approve = true,  # Set to false to show login form
    base_url = "http://127.0.0.1:3000"
)

# Create OAuth server with test provider
oauth = OAuthServer(
    issuer = "http://127.0.0.1:3000",
    upstream = test_provider
)

# Create tools
whoami_tool = MCPTool(
    name = "whoami",
    description = "Returns the authenticated user's info",
    handler = (params) -> TextContent(text = "Authenticated user: testuser")
)

echo_tool = MCPTool(
    name = "echo",
    description = "Echo a message",
    parameters = [ToolParameter(name = "message", type = "string", description = "Message to echo")],
    handler = (params) -> TextContent(text = "Echo: $(params["message"])")
)

secret_tool = MCPTool(
    name = "get_secret",
    description = "Returns a secret value (requires auth)",
    handler = (params) -> TextContent(text = "SECRET: The answer is 42")
)

# Create HTTP transport with OAuth
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000,
    auth = create_oauth_auth_middleware(oauth),
    oauth_server = oauth,
    resource_metadata = create_oauth_resource_metadata(oauth, scopes = ["mcp:tools"])
)

println("""
Test OAuth MCP Server Starting...

This server uses TestUpstreamProvider - no GitHub credentials needed!
OAuth requests are auto-approved for testing.

Endpoints:
  - Authorization Server Metadata: http://127.0.0.1:3000/.well-known/oauth-authorization-server
  - Protected Resource Metadata:   http://127.0.0.1:3000/.well-known/oauth-protected-resource
  - Client Registration (DCR):     http://127.0.0.1:3000/register
  - Authorize:                     http://127.0.0.1:3000/authorize
  - Token:                         http://127.0.0.1:3000/token

Manual Test Flow:

1. Get auth server metadata:
   curl http://127.0.0.1:3000/.well-known/oauth-authorization-server | jq .

2. Register a client (DCR):
   curl -X POST http://127.0.0.1:3000/register \\
     -H "Content-Type: application/json" \\
     -d '{"client_name":"Test Client","redirect_uris":["http://127.0.0.1:8080/callback"]}' | jq .

3. The authorization flow is auto-approved, so you can directly get a token.
   For manual testing with the full flow, use the MCP Inspector or Claude Code.

Claude Code Configuration (add to ~/.claude/claude_desktop_config.json):

{
  "mcpServers": {
    "test-oauth": {
      "command": "npx",
      "args": ["mcp-remote", "http://127.0.0.1:3000", "--allow-http"]
    }
  }
}

Press Ctrl+C to stop.
""")

# Create MCP server
server = mcp_server(
    name = "test-oauth",
    version = "1.0.0",
    tools = [whoami_tool, echo_tool, secret_tool]
)
server.transport = transport

# Connect transport and start
ModelContextProtocol.connect(transport)
start!(server)

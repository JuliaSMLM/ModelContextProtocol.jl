# OAuth 2.1 Authorization Server Example with Dynamic Client Registration
#
# This server supports:
# - Dynamic Client Registration (RFC 7591) - clients can auto-register
# - GitHub as upstream identity provider
# - PKCE (S256) for secure authorization
#
# Prerequisites:
# 1. Create GitHub OAuth App at https://github.com/settings/developers
#    - Callback URL: http://localhost:3000/callback
# 2. Set environment variables:
#    export GITHUB_CLIENT_ID="your_client_id"
#    export GITHUB_CLIENT_SECRET="your_client_secret"
#
# Run: julia --project examples/oauth_server_example.jl
#
# Claude Desktop will:
# 1. Discover auth requirements via /.well-known/oauth-protected-resource
# 2. Get auth server metadata via /.well-known/oauth-authorization-server
# 3. Register itself via POST /register (DCR)
# 4. Start OAuth flow via /authorize -> GitHub login -> /callback
# 5. Exchange code for token via POST /token
# 6. Use token to access MCP endpoints

using ModelContextProtocol

# Get credentials from environment
client_id = get(ENV, "GITHUB_CLIENT_ID", "")
client_secret = get(ENV, "GITHUB_CLIENT_SECRET", "")

if isempty(client_id) || isempty(client_secret)
    error("""
    Missing GitHub OAuth credentials!

    Set environment variables:
        export GITHUB_CLIENT_ID="your_client_id"
        export GITHUB_CLIENT_SECRET="your_client_secret"
    """)
end

# Create GitHub upstream provider
github = GitHubUpstreamProvider(
    client_id = client_id,
    client_secret = client_secret,
    scopes = ["read:user"]  # Minimal scope for user info
)

# Create OAuth server
oauth = OAuthServer(
    issuer = "http://localhost:3000",
    upstream = github
    # Optional: allowed_users = ["your-github-username"]
    # Optional: required_org = "YourOrg"
)

# Create tools
whoami_tool = MCPTool(
    name = "whoami",
    description = "Returns the authenticated user's info",
    handler = (params) -> TextContent(text = "Authenticated via OAuth")
)

echo_tool = MCPTool(
    name = "echo",
    description = "Echo a message",
    parameters = [ToolParameter(name = "message", type = "string", description = "Message to echo")],
    handler = (params) -> TextContent(text = "Echo: $(params["message"])")
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
OAuth MCP Server Starting...

Endpoints:
  - Authorization Server Metadata: http://localhost:3000/.well-known/oauth-authorization-server
  - Protected Resource Metadata:   http://localhost:3000/.well-known/oauth-protected-resource
  - Client Registration (DCR):     http://localhost:3000/register
  - Authorize:                     http://localhost:3000/authorize
  - Token:                         http://localhost:3000/token
  - Callback (internal):           http://localhost:3000/callback

Test Dynamic Client Registration (what Claude Desktop does):

1. Get auth server metadata:
   curl http://localhost:3000/.well-known/oauth-authorization-server | jq .

2. Register a client (DCR):
   curl -X POST http://localhost:3000/register \\
     -H "Content-Type: application/json" \\
     -d '{"client_name":"My MCP Client","redirect_uris":["http://localhost:8080/callback"]}' | jq .

   (Save the client_id from response)

3. Start authorization (open in browser with your client_id):
   http://localhost:3000/authorize?client_id=YOUR_CLIENT_ID&redirect_uri=http://localhost:8080/callback&response_type=code&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=mystate123

4. After GitHub login, you'll be redirected to:
   http://localhost:8080/callback?code=AUTHORIZATION_CODE&state=mystate123

   (This will fail since localhost:8080 isn't running, but copy the 'code' parameter)

3. Exchange code for token:
   curl -X POST http://localhost:3000/token \\
     -H "Content-Type: application/x-www-form-urlencoded" \\
     -d "grant_type=authorization_code" \\
     -d "code=AUTHORIZATION_CODE" \\
     -d "redirect_uri=http://localhost:8080/callback" \\
     -d "client_id=test-client" \\
     -d "code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

4. Use the access token:
   curl -X POST http://localhost:3000/ \\
     -H "Content-Type: application/json" \\
     -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \\
     -H "MCP-Protocol-Version: 2025-11-25" \\
     -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

Press Ctrl+C to stop.
""")

# Create MCP server
server = mcp_server(
    name = "oauth-example",
    version = "1.0.0",
    tools = [whoami_tool, echo_tool]
)
server.transport = transport

# Connect transport and start
ModelContextProtocol.connect(transport)
start!(server)

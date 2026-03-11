# DCR Test Server - Tests Dynamic Client Registration without needing GitHub
# Run: julia --project examples/dcr_test_server.jl

using ModelContextProtocol
using ModelContextProtocol: HttpTransport, OAuthServer, GitHubUpstreamProvider,
    create_oauth_auth_middleware, create_oauth_resource_metadata

# Create a dummy upstream provider (DCR doesn't need actual GitHub)
github = GitHubUpstreamProvider(
    client_id = "dummy",
    client_secret = "dummy"
)

# Create OAuth server with DCR support
oauth = OAuthServer(
    issuer = "http://127.0.0.1:3000",
    upstream = github
)

# Create tools
echo_tool = MCPTool(
    name = "echo",
    description = "Echo a message",
    parameters = [ToolParameter(name = "message", type = "string", description = "Message")],
    handler = (params) -> TextContent(text = "Echo: $(params["message"])")
)

# Create HTTP transport with OAuth
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000,
    oauth_server = oauth,
    resource_metadata = create_oauth_resource_metadata(oauth)
)

# Create server
server = mcp_server(
    name = "dcr-test",
    version = "1.0.0",
    tools = [echo_tool]
)
server.transport = transport

println("""
DCR Test Server on http://127.0.0.1:3000

Test Dynamic Client Registration:

1. Get authorization server metadata:
   curl -s http://127.0.0.1:3000/.well-known/oauth-authorization-server | jq .

2. Register a client:
   curl -s -X POST http://127.0.0.1:3000/register \\
     -H "Content-Type: application/json" \\
     -d '{"client_name":"Claude Desktop","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}' | jq .

3. Verify registration_endpoint is in metadata:
   curl -s http://127.0.0.1:3000/.well-known/oauth-authorization-server | jq .registration_endpoint

Press Ctrl+C to stop.
""")

ModelContextProtocol.connect(transport)
start!(server)

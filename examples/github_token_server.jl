# Simple MCP server that validates GitHub Personal Access Tokens
# No GitHub OAuth App needed - users provide their own PAT
#
# Run: julia --project examples/github_token_server.jl
#
# Client provides: Authorization: Bearer ghp_xxxxx (GitHub PAT)
# Server validates by calling GitHub API

using ModelContextProtocol
using ModelContextProtocol: HttpTransport, GitHubOAuthValidator, OAuthConfig, AuthMiddleware

# Create GitHub token validator (validates PATs by calling GitHub API)
github_validator = GitHubOAuthValidator()

# Auth config
config = OAuthConfig(
    issuer = "https://github.com",
    audience = "http://127.0.0.1:3000"
)

# Auth middleware using GitHub validator
auth = AuthMiddleware(
    config = config,
    validator = github_validator,
    enabled = true
)

# Create tools
secret_tool = MCPTool(
    name = "secret_data",
    description = "Returns secret data (requires GitHub auth)",
    handler = (params) -> TextContent(text = "SECRET: The answer is 42")
)

# Create transport with auth
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000,
    auth = auth
)

# Create server
server = mcp_server(
    name = "github-token-server",
    version = "1.0.0",
    tools = [secret_tool]
)
server.transport = transport
ModelContextProtocol.connect(transport)

println("""
GitHub Token Auth Server on http://127.0.0.1:3000

This server validates GitHub Personal Access Tokens (PATs).
No OAuth App registration needed.

To test:
1. Create a GitHub PAT at: https://github.com/settings/tokens
   (only needs 'read:user' scope)

2. Test with your PAT:
   curl -X POST http://127.0.0.1:3000/ \\
     -H "Content-Type: application/json" \\
     -H "Authorization: Bearer ghp_YOUR_TOKEN_HERE" \\
     -H "MCP-Protocol-Version: 2025-11-25" \\
     -H "Accept: application/json, text/event-stream" \\
     -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

Press Ctrl+C to stop.
""")

start!(server)

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

# Create HTTP transport (the MCP protocol version is negotiated per client;
# the server speaks 2025-11-25 down to 2024-11-05)
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000
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
    session_required = true,      # Require session validation
    allowed_origins = ["http://localhost:8080"],  # CORS origins
    auth = nothing,               # Optional AuthMiddleware (see Authentication below)
    resource_metadata = nothing   # Optional RFC 9728 Protected Resource Metadata
)
```

The advertised MCP protocol version defaults to the latest supported (`2025-11-25`) and is
negotiated per client during `initialize`; response headers echo the negotiated version.
SSE is always available via `GET` with `Accept: text/event-stream` — there is no switch.

### Session Management

HTTP transport uses session-based communication for security and state tracking:

1. **Initialization**: Client sends initialization request
2. **Session Creation**: Server responds with `Mcp-Session-Id` header  
3. **Subsequent Requests**: Client includes session ID in `Mcp-Session-Id` header

```bash
# Initialize and get session ID
curl -X POST http://localhost:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}' \
  -i

# Use session ID in subsequent requests  
curl -X POST http://localhost:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -H 'Mcp-Session-Id: <session-id-from-response>' \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}'
```

### Server-Sent Events (SSE)

The HTTP transport streams server-to-client notifications via Server-Sent Events. Clients
open the stream with a `GET` request:

```bash
curl -N -H 'Accept: text/event-stream' http://127.0.0.1:3000/
```

SSE streams carry:
- Server notifications (`notifications/message` log events)
- Progress updates for long-running tool calls (`notifications/progress`)
- Responses, when the client requested SSE delivery

### Security Features

#### Authentication (OAuth Resource Server)

The HTTP transport can require a bearer token on every request. Validators include GitHub
tokens (validated against the GitHub API with optional allowlist/organization checks),
JWTs verified against a JWKS endpoint, JWT claims, and RFC 7662 token introspection:

```julia
using ModelContextProtocol

auth = create_github_auth(
    allowed_users = ["alice", "bob"],   # empty list = any authenticated GitHub user
    required_org  = "MyLab",            # optional organization gate
)
meta = create_github_resource_metadata("https://mcp.example.org")

transport = HttpTransport(host = "0.0.0.0", port = 3000,
                          auth = auth, resource_metadata = meta)
```

For JWTs issued by an external authorization server (Keycloak, Auth0, etc.), use
`JWKSValidator` — it verifies token signatures against the server's published JSON Web
Key Set (RFC 7517) and then applies the standard claim checks (issuer, audience,
expiry, scopes), all fail-closed:

```julia
auth = create_auth_middleware(
    OAuthConfig(
        issuer   = "https://auth.example.org/realms/lab",
        audience = "https://mcp.example.org",
    ),
    validator = JWKSValidator("https://auth.example.org/realms/lab/protocol/openid-connect/certs"),
)
```

Keys are fetched lazily and re-fetched on unknown key ids (rotation), rate-limited to
one fetch per `refresh_interval_seconds` (default 300) so attacker-supplied `kid`
values cannot hammer the JWKS endpoint. The `alg` allowlist defaults to the RSA family
(`RS256`/`RS384`/`RS512`) and rejects `alg=none` outright.

Clients send `Authorization: Bearer <token>`; unauthorized requests get `401`/`403` with an
RFC 6750 `WWW-Authenticate` header, and discovery metadata is served at
`/.well-known/oauth-protected-resource` (RFC 9728). Tool handlers can read the verified
identity by accepting the request context: `handler = (args, ctx) -> ...` and using
`ctx.authenticated_user`. Note: `JWTValidator` checks claims only (no signature
verification); prefer `JWKSValidator` for tokens from external issuers, or the GitHub /
introspection validators when tokens must be verified against an authority.

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

- The server accepts any supported version (`2025-11-25`, `2025-06-18`, `2025-03-26`,
  `2024-11-05`) in the `MCP-Protocol-Version` header and negotiates during `initialize`
- Response headers echo the **negotiated** version after initialization
- Check server logs for protocol version negotiation messages

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
- `examples/simple_http_server.jl` - Simple HTTP server setup
- `examples/reg_dir_http.jl` - HTTP server with directory auto-registration
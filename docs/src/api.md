# API Reference

```@index
Pages = ["api.md"]
```

## Primary Interface

```@docs
mcp_server
```

## Server Operations

```@docs
start!
stop!
register!
```

## Component Types

### Tools

```@docs
MCPTool
ToolParameter
MCPIcon
```

### Resources

```@docs
MCPResource
ResourceTemplate
```

### Prompts

```@docs
MCPPrompt
PromptArgument
PromptMessage
```

## Content Types

### Abstract Types

```@docs
Content
ResourceContents
```

### Concrete Content Types

```@docs
TextContent
ImageContent
AudioContent
EmbeddedResource
ResourceLink
```

### Resource Content Types

```@docs
TextResourceContents
BlobResourceContents
```

### Tool Results

```@docs
CallToolResult
```

## Transport Configuration

```@docs
Transport
StdioTransport
HttpTransport
connect
```

## Server Type

```@docs
Server
```

## Resource Subscriptions

```@docs
subscribe!
unsubscribe!
notify_list_changed
notify_resource_updated
```

## Handler Context Helpers

```@docs
send_progress
task_cancelled
```

## Multi Round-Trip Requests (MRTR)

```@docs
InputRequired
elicit_request
sampling_request
roots_request
input_responses
input_state
```

## Tasks Extension

```@docs
task_detach
task_await_input
TaskCancelledException
```

## Protocol Version Negotiation

```@docs
LATEST_PROTOCOL_VERSION
SUPPORTED_PROTOCOL_VERSIONS
FEATURE_VERSIONS
negotiate_version
supports
is_supported_version
```

## Authentication (OAuth Resource Server)

### Configuration and Middleware

```@docs
OAuthConfig
AuthMiddleware
AuthResult
AuthenticatedUser
create_auth_middleware
create_simple_auth
disable_auth
is_auth_enabled
```

### Token Validators

```@docs
AuthProvider
TokenValidator
SimpleTokenValidator
JWTValidator
JWKSValidator
IntrospectionValidator
GitHubOAuthValidator
create_github_auth
clear_cache!
```

### Protected Resource Metadata (RFC 9728)

```@docs
ProtectedResourceMetadata
create_protected_resource_metadata
create_github_resource_metadata
```

### Request Authentication

```@docs
authenticate_request
validate_token
extract_bearer_token
```

## Utility Functions

```@docs
content2dict
```

## Transport Options

ModelContextProtocol.jl supports multiple transport mechanisms:

### STDIO Transport (Default)
```julia
server = mcp_server(name = "my-server")
start!(server)  # Uses StdioTransport by default
```

### HTTP Transport
```julia
server = mcp_server(name = "my-http-server")
transport = HttpTransport(; port = 3000)
connect(transport)   # binds the port and starts the listener
start!(server; transport = transport)

# With custom configuration
transport = HttpTransport(;
    host = "127.0.0.1",  # Important for Windows
    port = 8080,         # Default port
    endpoint = "/"       # Default endpoint
)
connect(transport)
start!(server; transport = transport)
```

**Note**: HTTP transport currently supports HTTP only, not HTTPS. For production use:
- Use `mcp-remote` with `--allow-http` flag for secure connections
- Or deploy behind a reverse proxy (nginx, Apache) for TLS termination

## Internal API

The following internal types and functions are documented for developers working on the package itself.

### Protocol Types

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["protocol/messages.jl", "protocol/jsonrpc.jl", "protocol/handlers.jl",
         "protocol/versioning.jl", "protocol/modern.jl", "protocol/mrtr.jl",
         "protocol/tasks_ext.jl", "protocol/subscriptions.jl"]
Public = false
```

### Core Implementation

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["core/server.jl", "core/capabilities.jl", "core/init.jl",
         "types.jl", "server_types.jl", "features/tasks.jl", "features/subscriptions.jl"]
Public = false
```

### Transport Implementation

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["transports/base.jl", "transports/stdio.jl", "transports/http.jl"]
Public = false
```

### Authentication Implementation

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["auth/auth.jl", "auth/token.jl", "auth/middleware.jl", "auth/metadata.jl",
         "auth/providers/github.jl"]
Public = false
```

### Utilities

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["utils/errors.jl", "utils/logging.jl", "utils/serialization.jl"]
Public = false
```
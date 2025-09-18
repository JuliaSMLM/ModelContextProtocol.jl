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
EmbeddedResource
```

!!! note "ResourceLink"
    `ResourceLink` is part of the 2025-06-18 protocol but not yet exported.
    It will be available in a future release.

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

!!! note "Transport Types"
    Transport types (`StdioTransport`, `HttpTransport`) are internal implementation details
    and are not exported. Use `mcp_server` with appropriate options to configure transport.

## Server Type

```@docs
Server
```

## Resource Subscriptions

```@docs
subscribe!
unsubscribe!
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
start!(server; transport = HttpTransport(; port = 3000))

# With custom configuration
start!(server; transport = HttpTransport(;
    host = "127.0.0.1",  # Important for Windows
    port = 8080,         # Default port
    endpoint = "/"       # Default endpoint
))
```

**Note**: HTTP transport currently supports HTTP only, not HTTPS. For production use:
- Use `mcp-remote` with `--allow-http` flag for secure connections
- Or deploy behind a reverse proxy (nginx, Apache) for TLS termination

## All Exported Symbols

### Types

```@autodocs
Modules = [ModelContextProtocol]
Order = [:type]
Public = true
Private = false
```

### Functions

```@autodocs
Modules = [ModelContextProtocol]
Order = [:function]
Public = true
Private = false
```

### Constants

```@autodocs
Modules = [ModelContextProtocol]
Order = [:constant]
Public = true
Private = false
```

### Macros

```@autodocs
Modules = [ModelContextProtocol]
Order = [:macro]
Public = true
Private = false
```

## Internal API

The following internal types and functions are documented for developers working on the package itself.

### Protocol Types

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["protocol/messages.jl", "protocol/jsonrpc.jl"]
Public = false
```

### Core Implementation

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["core/server.jl", "core/capabilities.jl", "core/init.jl"]
Public = false
```

### Transport Implementation

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["transports/base.jl", "transports/stdio.jl", "transports/http.jl"]
Public = false
```

### Utilities

```@autodocs
Modules = [ModelContextProtocol]
Pages = ["utils/errors.jl", "utils/logging.jl", "utils/serialization.jl"]
Public = false
```
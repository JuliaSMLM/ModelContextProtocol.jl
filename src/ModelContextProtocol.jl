"""
    ModelContextProtocol

Julia implementation of the Model Context Protocol (MCP), enabling standardized
communication between AI applications and external tools, resources, and data sources.

# Quick Start

Create and start an MCP server:

```julia
using ModelContextProtocol

# Create a simple server with a tool
server = mcp_server(
    name = "my-server",
    tools = [
        MCPTool(
            name = "hello",
            description = "Say hello",
            parameters = [],
            handler = (p) -> TextContent(text = "Hello, world!")
        )
    ]
)

start!(server)
```

# API Overview

For a comprehensive overview of the API, use the help mode on `api`:

    ?ModelContextProtocol.api

Or access the complete API documentation programmatically:

    docs = ModelContextProtocol.api()

# See Also

- `mcp_server` - Create an MCP server instance
- `MCPTool` - Define tools that can be invoked by clients
- `MCPResource` - Define resources that can be accessed by clients
- `MCPPrompt` - Define prompt templates for LLMs
"""
module ModelContextProtocol

using JSON3, URIs, DataStructures, OrderedCollections, Logging, Dates, StructTypes, MacroTools, Base64

# 1. All Types (consolidated in dependency order)
include("types.jl")

# 2. Protocol Messages
include("protocol/messages.jl")

# 3. Authentication (OAuth 2.0 framework - needed by HTTP transport)
include("auth/auth.jl")

# 4. Transport Layer
include("transports/base.jl")
include("transports/stdio.jl")
include("transports/http.jl")

# 5. Server Type (depends on Transport)
include("server_types.jl")

# 6. Utils
include("utils/errors.jl")
include("utils/logging.jl")

# 7. Implementation
include("protocol/jsonrpc.jl")
include("core/capabilities.jl")
include("core/server.jl")
include("core/init.jl")
include("protocol/handlers.jl")

# 8. Serialization (needs all types)
include("utils/serialization.jl")

# 9. Features (types are now in types.jl, no separate feature files needed)

# 9. API documentation
include("api.jl")

# Export only the essential public API
export 

    # Primary interface function 
    mcp_server,
    
    # Server operations
    start!, stop!, register!,
    
    # Component types for defining MCP components
    MCPTool, ToolParameter,
    MCPResource, ResourceTemplate,
    MCPPrompt, PromptArgument, PromptMessage,
    
    # Content types for tool/resource responses
    Content, ResourceContents,  # Abstract types for type annotations
    TextContent, ImageContent,
    TextResourceContents, BlobResourceContents,
    EmbeddedResource, ResourceLink,
    CallToolResult,  # For explicit error handling in tools
    
    # Transport types for server configuration
    Transport,  # Abstract type for type annotations
    StdioTransport, HttpTransport,
    connect,  # For HTTP transport initialization
    get_authenticated_user, is_auth_enabled,  # HTTP auth helpers
    
    # Advanced features
    Server,  # For type annotations in user code
    subscribe!, unsubscribe!,  # Resource subscription management
    content2dict,  # Utility for debugging/testing

    # Authentication (OAuth 2.0)
    AuthProvider, TokenValidator, AuthenticatedUser,
    OAuthConfig, AuthResult, AuthMiddleware,
    ProtectedResourceMetadata,
    SimpleTokenValidator, JWTValidator, IntrospectionValidator,
    create_auth_middleware, create_simple_auth, disable_auth,
    create_protected_resource_metadata, create_github_resource_metadata,
    authenticate_request, validate_token, extract_bearer_token,

    # GitHub OAuth Provider
    GitHubOAuthValidator, GitHubAuthConfig, create_github_auth, clear_cache!

end # module
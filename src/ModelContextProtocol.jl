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

# 2b. Protocol version negotiation (dependency-free; used by transport + handlers)
include("protocol/versioning.jl")

# 2c. Authentication — OAuth Resource Server (defines the auth types the HTTP transport references)
include("auth/auth.jl")

# 3. Transport Layer
include("transports/base.jl")
include("transports/stdio.jl")
include("transports/http.jl")

# 3b. Task store for MCP Tasks (SEP-1686, experimental; Server holds a TaskStore)
include("features/tasks.jl")

# 4. Server Type (depends on Transport)
include("server_types.jl")

# 5. Utils
include("utils/errors.jl")
include("utils/logging.jl")

# 5. Implementation
include("protocol/jsonrpc.jl")
include("core/capabilities.jl")
include("core/server.jl")
include("core/init.jl")
include("protocol/handlers.jl")

# 6. Serialization (needs all types)
include("utils/serialization.jl")

# 7. Features (types are now in types.jl, no separate feature files needed)

# 9. API documentation
include("api.jl")

# Export only the essential public API
export 

    # Primary interface function 
    mcp_server,
    
    # Server operations
    start!, stop!, register!,
    
    # Component types for defining MCP components
    MCPTool, ToolParameter, MCPIcon,
    MCPResource, ResourceTemplate,
    MCPPrompt, PromptArgument, PromptMessage,
    
    # Content types for tool/resource responses
    Content, ResourceContents,  # Abstract types for type annotations
    TextContent, ImageContent, AudioContent,
    TextResourceContents, BlobResourceContents,
    EmbeddedResource, ResourceLink,
    CallToolResult,  # For explicit error handling in tools
    
    # Transport types for server configuration
    Transport,  # Abstract type for type annotations
    StdioTransport, HttpTransport,
    connect,  # For HTTP transport initialization
    
    # Advanced features
    Server,  # For type annotations in user code
    send_progress,  # Progress reporting from tool handlers (RequestContext is intentionally not exported)
    task_cancelled,  # Cooperative cancellation check inside task-augmented tool handlers
    subscribe!, unsubscribe!,  # Resource subscription management
    content2dict,  # Utility for debugging/testing

    # Protocol version negotiation and feature gating (MCP 2025-11-25)
    LATEST_PROTOCOL_VERSION, SUPPORTED_PROTOCOL_VERSIONS, FEATURE_VERSIONS,
    negotiate_version, supports, is_supported_version,

    # Authentication — OAuth Resource Server (MCP 2025-11-25 authorization)
    AuthProvider, TokenValidator, AuthenticatedUser,
    OAuthConfig, AuthResult, AuthMiddleware, ProtectedResourceMetadata,
    SimpleTokenValidator, JWTValidator, IntrospectionValidator,
    create_auth_middleware, create_simple_auth, disable_auth,
    create_protected_resource_metadata, create_github_resource_metadata,
    authenticate_request, validate_token, extract_bearer_token,
    GitHubOAuthValidator, create_github_auth, clear_cache!,
    is_auth_enabled

# Precompile the request hot path (parse -> dispatch -> serialize) so a fresh server
# answers its first real request without paying runtime JIT. Sockets can't precompile;
# this covers everything up to the transport write.
using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    _pc_tool = MCPTool(
        name = "echo",
        description = "precompile echo",
        parameters = [ToolParameter(name = "message", description = "msg", type = "string", required = true)],
        handler = args -> TextContent(text = String(args["message"])),
    )
    _pc_prompt = MCPPrompt(
        name = "pc_prompt",
        description = "precompile prompt",
        arguments = [PromptArgument(name = "x", description = "x")],
        messages = [PromptMessage(content = TextContent(text = "hello {x}"))],
    )
    _pc_resource = MCPResource(uri = "precompile://r", name = "r", data_provider = () -> Dict("ok" => true))
    _pc_msgs = [
        """{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"pc","version":"1"}},"id":1}""",
        """{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}""",
        """{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{"message":"hi"}},"id":3}""",
        """{"jsonrpc":"2.0","method":"prompts/list","params":{},"id":4}""",
        """{"jsonrpc":"2.0","method":"prompts/get","params":{"name":"pc_prompt","arguments":{"x":"y"}},"id":5}""",
        """{"jsonrpc":"2.0","method":"resources/list","params":{},"id":6}""",
        """{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"precompile://r"},"id":7}""",
        """{"jsonrpc":"2.0","method":"ping","id":8}""",
    ]
    @compile_workload begin
        _pc_server = mcp_server(
            name = "precompile", version = "1.0.0",
            tools = [_pc_tool], prompts = [_pc_prompt], resources = [_pc_resource],
        )
        _pc_state = ServerState()
        for m in _pc_msgs
            process_message(_pc_server, _pc_state, m)
        end
    end
end

end # module
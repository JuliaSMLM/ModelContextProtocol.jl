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

# 1. Foundation
include("core/types.jl")

# 2. Features
include("features/tools.jl")
include("features/resources.jl") 
include("features/prompts.jl")

# 3. Protocol Types
include("protocol/messages.jl")

# 4. Transport Layer
include("transports/base.jl")
include("transports/stdio.jl")
include("transports/http.jl")

# 5. Server Types
include("core/server_types.jl")  

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

# 9. API documentation
include("api.jl")

# Export all public interfaces
export 

    # Primary interface function 
    mcp_server,
    
    # Core types & enums
    Role, RequestId, ProgressToken,
    MCPMessage, Request, Response, Notification,
    RequestParams, ResponseResult,
    Content, ResourceContents,
    TextContent, ImageContent, TextResourceContents, BlobResourceContents,
    EmbeddedResource,

    # Server types
    Server, ServerConfig,
    Tool, Resource, Capability,
    
    # Transport types
    Transport, TransportError, StdioTransport, HttpTransport,
    send_notification, broadcast_to_sse, format_sse_event,
    
    # Feature types
    ToolParameter, MCPTool, MCPResource, 
    ResourceTemplate,
    
    # Prompt types
    PromptArgument, MCPPrompt, PromptMessage,
    
    # Server operations
    start!, stop!, register!,
    
    # Capabilities
    ResourceCapability, ToolCapability, PromptCapability,
    
    # Server management
    subscribe!, unsubscribe!,
    
    # Protocol message types
    RequestMeta, ClientCapabilities, Implementation,
    InitializeParams, InitializeResult,
    ListResourcesParams, ListResourcesResult,
    ReadResourceParams, ReadResourceResult,
    ListToolsParams, ListToolsResult,
    CallToolParams, CallToolResult,
    ListPromptsParams, ListPromptsResult,
    GetPromptParams, GetPromptResult,
    ProgressParams, ErrorInfo,
    JSONRPCRequest, JSONRPCResponse, JSONRPCError, JSONRPCNotification,
    
    # Protocol functions
    parse_message, serialize_message,
    
    # Utils
    MCPLogger, init_logging,
    ErrorCodes,  # Export error codes module
    content2dict,  # Export content serialization function

    # Handlers
    HandlerResult, RequestContext

end # module
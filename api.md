# ModelContextProtocol.jl API Reference

## Table of Contents

- [Overview](#overview)
- [Quick Reference](#quick-reference)
- [Quick Start](#quick-start)
- [Core Functions](#core-functions)
- [Component Types](#component-types)
  - [Tools](#tools)
  - [Resources](#resources)
  - [Prompts](#prompts)
- [Content Types](#content-types)
- [Transport Types](#transport-types)
- [Auto-Registration](#auto-registration-system)
- [Common Patterns](#common-patterns)
- [Error Handling](#error-types-and-handling)
- [Debugging](#debugging-techniques)
- [Performance](#performance-considerations)
- [Troubleshooting](#troubleshooting)

## Overview

ModelContextProtocol.jl provides a Julia implementation of the Model Context Protocol (MCP) version 2025-06-18, enabling standardized communication between AI applications and external tools, resources, and data sources.

### Version Information

⚠️ **Critical Distinction - Two Different Versions:**

| Version Type | Example | Who Sets It | Purpose |
|-------------|---------|------------|----------|
| **Protocol Version** | `"2025-06-18"` | MCP Specification | Protocol compatibility (fixed) |
| **Server Version** | `"1.0.0"` | You (developer) | Your server's version |

```julia
# The protocol version is handled internally - you don't set it
# You only set YOUR server's version:
server = mcp_server(
    name = "my-server",
    version = "2.3.1",  # ← YOUR server version, not the protocol!
    tools = my_tools
)
```

### Breaking Changes and Migration

**From Earlier Versions:**
- Protocol version 2025-06-18 is strictly enforced (no negotiation)
- JSON-RPC batching is no longer supported
- ResourceLink is a new content type
- Session management added for HTTP transport

**Migration Tips:**
- Update all protocol version references to "2025-06-18"
- Split batch requests into individual calls
- Use ResourceLink for resource references instead of embedding

## Quick Reference

### Essential Functions
- `mcp_server(name="...", version="1.0.0", tools=..., resources=..., prompts=...)` - Create server
- `start!(server, transport=...)` - Start server (blocks for HTTP)
- `connect(transport)` - Initialize HTTP transport (required before start!)
- `register!(server, component)` - Add components dynamically

### Key Types
- `MCPTool` - Define executable tools
- `MCPResource` - Provide data resources
- `MCPPrompt` - Create prompt templates
- `TextContent` / `ImageContent` - Return content from handlers
- `StdioTransport` / `HttpTransport` - Communication transports

### Common Patterns
```julia
# Minimal tool
tool = MCPTool(
    name = "example",
    description = "Example tool",
    parameters = [],  # Required, even if empty!
    handler = (p) -> TextContent(text = "Result")
)

# Tool with multiple return types
multi_tool = MCPTool(
    name = "multi",
    description = "Returns multiple content items",
    parameters = [],
    handler = function(params)
        # Return array of different content types
        return [
            TextContent(text = "Analysis results"),
            ImageContent(data = image_bytes, mime_type = "image/png"),
            TextContent(text = "Summary: Process complete")
        ]
    end
)

# Start server
server = mcp_server(
    name = "my-server",
    version = "1.0.0",  # Your server version
    tools = [tool, multi_tool]
)
start!(server)  # Uses stdio by default
```

## Design Philosophy

### Core Principles

1. **Protocol-First Design**: Strict compliance with MCP 2025-06-18 specification. No version negotiation complexity, no legacy support.

2. **Layered Architecture**: 
   - **Transport Layer**: Abstract interface with stdio and HTTP implementations
   - **Protocol Layer**: JSON-RPC message handling and routing
   - **Features Layer**: Tools, resources, and prompts implementation
   - **Core Layer**: Server state management and initialization

3. **Type System Design**:
   - Abstract types (`Content`, `Transport`, `Resource`) for extensibility and type annotations
   - Concrete types with `@kwdef` for ergonomic construction with defaults
   - Module isolation for safe dynamic component loading
   - Small maps use `LittleDict` for performance (automatically imported from DataStructures.jl)

4. **Handler Design**:
   - Tool handlers receive `Dict{String,Any}` parameters for JSON flexibility
   - Support multiple return types with automatic conversion
   - `CallToolResult` for explicit control when needed

5. **Minimal Public API**: Only essential types and functions are exported. Internal complexity remains internal.

## Quick Start

### Create Your First Tool

```julia
using ModelContextProtocol

# Create a simple tool that says hello
hello_tool = MCPTool(
    name = "hello",
    description = "Say hello to someone",
    parameters = [
        ToolParameter(
            name = "name",
            type = "string",
            description = "Name to greet",
            required = true
        )
    ],
    handler = function(params)
        name = params["name"]
        return TextContent(text = "Hello, $name! Welcome to MCP.")
    end
)
```

### Step 3: Create and Start Server

```julia
# Create server with your tool
server = mcp_server(
    name = "hello-server",
    version = "1.0.0",  # YOUR server version (not protocol version!)
    tools = hello_tool
)

# Start the server (uses stdio by default)
start!(server)
```

### Step 4: Test Your Server

```bash
# Test with a simple echo command
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | julia --project your_server.jl

# Or use MCP Inspector for interactive testing
julia --project your_server.jl | npx @modelcontextprotocol/inspector
```

## Core Architecture

### Transport Hierarchy

```julia
abstract type Transport end
├── StdioTransport    # Standard input/output
└── HttpTransport     # HTTP with SSE support
```

### Content Type Hierarchy

```julia
abstract type Content end
├── TextContent       # Text-based content
├── ImageContent      # Binary image data
├── EmbeddedResource  # Embedded resource content
└── ResourceLink      # Reference to a resource
```

### Resource Contents Hierarchy

```julia
abstract type ResourceContents end
├── TextResourceContents  # Text-based resource data
└── BlobResourceContents  # Binary resource data
```

## Core Functions

### `mcp_server`

Create an MCP server instance with tools, resources, and prompts.

```julia
mcp_server(;
    name::String,                        # Required: Server name
    version::String = "1.0.0",           # Your server version (defaults to "1.0.0", NOT the protocol version)
    description::String = "",            # Server description
    tools = nothing,                     # Single tool or Vector{MCPTool}
    resources = nothing,                 # Single resource or Vector{MCPResource}
    prompts = nothing,                   # Single prompt or Vector{MCPPrompt}
    capabilities = default_capabilities(), # Protocol capabilities (usually use default)
    auto_register_dir = nothing         # Directory for auto-registration
) -> Server
```

**Protocol Version:** This implementation exclusively supports MCP protocol version `2025-06-18`.

**Examples:**

```julia
# Simple server
server = mcp_server(name = "simple")  # Uses default version "1.0.0"

# Server with explicit version
server = mcp_server(
    name = "simple",
    version = "2.1.0"  # Your custom server version
)

# Server with components
# Define components first
tool1 = MCPTool(
    name = "tool1",
    description = "First tool",
    parameters = [],  # Empty array for no parameters
    handler = (p) -> TextContent(text = "Tool 1 result")
)

tool2 = MCPTool(
    name = "tool2",
    description = "Second tool",
    parameters = [],
    handler = (p) -> TextContent(text = "Tool 2 result")
)

my_resource = MCPResource(
    uri = "resource://example",
    name = "Example Resource",
    data_provider = () -> Dict("data" => "value")
)

prompt1 = MCPPrompt(
    name = "greeting",
    description = "Greeting prompt"
)

prompt2 = MCPPrompt(
    name = "analysis",
    description = "Analysis prompt"
)

server = mcp_server(
    name = "full-server",
    version = "1.0.0",  # Your server's version
    tools = [tool1, tool2],
    resources = my_resource,
    prompts = [prompt1, prompt2]
)

# Auto-registration from directory
server = mcp_server(
    name = "auto-server",
    version = "1.0.0",  # Your server version
    auto_register_dir = "mcp_components"
)
```

### Server Operations

#### `start!(server::Server; transport::Union{Transport,Nothing}=nothing)`

Start the MCP server and begin processing requests.

```julia
# Default stdio transport
start!(server)

# Custom transport
transport = HttpTransport(port = 3000)
connect(transport)  # Required for HTTP only
start!(server, transport = transport)
```

**Behavior:**
- For stdio: Processes messages from stdin, responds to stdout
- For HTTP: Blocks and runs server until interrupted

#### `stop!(server::Server)`

Stop a running MCP server and clean up resources.

```julia
stop!(server)
```

**Behavior:**
- Closes active connections
- Releases bound ports (HTTP)
- Sets server.active to false
- Safe to call multiple times

#### `connect(transport::HttpTransport)`

Initialize HTTP server and bind to port. **Required before `start!` for HTTP transport only.**

**Note:** This function is only needed for `HttpTransport`. `StdioTransport` does not require `connect()`.

```julia
transport = HttpTransport(port = 3000)
connect(transport)  # Binds port, starts HTTP server
```

#### `register!(server::Server, component)`

Register components after server creation.

```julia
# Define components
new_tool = MCPTool(name = "new_tool", description = "New tool", parameters = [], handler = (p) -> TextContent(text = "Done"))
new_resource = MCPResource(uri = "resource://new", name = "New Resource", data_provider = () -> Dict())
new_prompt = MCPPrompt(name = "new_prompt", description = "New prompt")

# Register them
register!(server, new_tool)      # Add tool
register!(server, new_resource)  # Add resource
register!(server, new_prompt)    # Add prompt
```

## Component Types

**Note:** All component type definitions are located in `src/types.jl`.

### Tools

#### `MCPTool`

Define a tool that can be invoked by clients.

```julia
MCPTool(;
    name::String,                          # Unique identifier
    description::String,                   # Human-readable description
    parameters::Vector{ToolParameter},    # Input parameters (required, use [] for none)
    handler::Function,                     # (Dict -> Content) handler
    return_type::Type = Vector{Content}    # Expected return type (default: Vector{Content})
)
```

**Handler Return Types:**
- Single `Content` subtype (auto-wrapped in vector)
- `Vector{<:Content}` for multiple items
- `CallToolResult` for explicit control (ignores return_type)
- `String` (auto-wrapped in TextContent)
- `Dict` (converted to JSON string and wrapped in TextContent)
- `Nothing` or `missing` (returns empty content array)

**Return Type Validation:**
The `return_type` field validates handler returns:
```julia
# Default: accepts any Content or Vector{Content}
return_type = Content  # Most flexible

# Specific type: validates single content type
return_type = TextContent  # Only accepts TextContent
return_type = ImageContent  # Only accepts ImageContent

# Note: CallToolResult bypasses validation
```

#### `ToolParameter`

Define tool parameters with optional defaults.

```julia
ToolParameter(;
    name::String,                    # Parameter name
    type::String,                    # JSON Schema type (e.g., "string", "number", "boolean")
    description::String,             # Description (required)
    required::Bool = false,          # Whether required
    default::Any = nothing          # Default value if not provided
)
```

**Example:**

```julia
calc_tool = MCPTool(
    name = "calculate",
    description = "Evaluate math expressions",
    parameters = [
        ToolParameter(
            name = "expression",
            type = "string",
            description = "Math expression to evaluate",
            required = true
        ),
        ToolParameter(
            name = "precision",
            type = "number",
            description = "Decimal places",
            default = 2
        )
    ],
    handler = function(params)
        result = eval(Meta.parse(params["expression"]))
        precision = get(params, "precision", 2)  # Uses default
        TextContent(text = string(round(result, digits=Int(precision))))
    end
)
```

### Resources

#### `MCPResource`

Define a resource that provides data.

```julia
MCPResource(;
    uri::Union{String, URI},              # Resource identifier
    name::String,                         # Human-readable name
    description::String = "",             # Description
    mime_type::String = "application/json", # MIME type
    data_provider::Function,              # () -> data function
    annotations::AbstractDict = LittleDict{String,Any}()  # Metadata (uses LittleDict for performance)
)
```

**Note:** The `uri` is stored internally as a `URI` object but accepts strings for convenience.

#### `ResourceTemplate`

Templates for dynamic resources.

```julia
ResourceTemplate(;
    name::String,                       # Template name
    uri_template::String,               # URI pattern with placeholders
    mime_type::Union{String,Nothing} = nothing,
    description::String = ""
)
```

**Example:**

```julia
using Dates  # Required for now()

# Static resource with dynamic data
data_resource = MCPResource(
    uri = "data://metrics",
    name = "System Metrics",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "cpu" => 45.2,
        "memory" => 8192,
        "timestamp" => now()
    )
)

# Dynamic resource template with placeholders
template = ResourceTemplate(
    name = "User Profile Template",
    uri_template = "user://{user_id}/profile",
    mime_type = "application/json",
    description = "Template for accessing user profiles by ID"
)
```

### Prompts

#### `MCPPrompt`

Define prompt templates.

```julia
MCPPrompt(;
    name::String,                              # Identifier
    description::String = "",                  # Description
    arguments::Vector{PromptArgument} = [],   # Arguments
    messages::Vector{PromptMessage} = []      # Messages
)
```

#### `PromptArgument`

Prompt input arguments.

```julia
PromptArgument(;
    name::String,                    # Argument name  
    description::String = "",        # Description
    required::Bool = false           # Whether required
)
```

**Dynamic Prompt Example:**

```julia
# Prompt with error handling and validation
validated_prompt = MCPPrompt(
    name = "sql_query",
    description = "Generate SQL query with validation",
    arguments = [
        PromptArgument(
            name = "table",
            description = "Table name",
            required = true
        ),
        PromptArgument(
            name = "columns",
            description = "Comma-separated column names",
            required = false
        )
    ],
    messages = [
        PromptMessage(
            content = TextContent(
                text = "Generate a SELECT query for table {table} with columns {columns}."
            ),
            role = user
        )
    ]
)

# Using the prompt (conceptual - actual usage depends on client)
function apply_prompt(prompt::MCPPrompt, args::Dict)
    # Validate required arguments
    for arg in prompt.arguments
        if arg.required && !haskey(args, arg.name)
            error("Missing required argument: $(arg.name)")
        end
    end
    
    # Apply arguments to messages
    # ... template replacement logic ...
end
```

#### `PromptMessage`

Messages in prompts.

```julia
PromptMessage(;
    content::Union{TextContent, ImageContent},  # Message content (text or image only)
    role::Role = user                           # Role (user or assistant)
)
```

**Note:** The `Role` enum has values `user` and `assistant`. When creating a `PromptMessage`, the role defaults to `user` if not specified.

```julia
# Using the Role enum (requires explicit import)
using ModelContextProtocol: user, assistant  # Import role constants explicitly

message_user = PromptMessage(
    content = TextContent(text = "User message"),
    role = user  # Explicit user role
)

message_assistant = PromptMessage(
    content = TextContent(text = "Assistant response"),
    role = assistant  # Assistant role
)
```

**Example:**

```julia
analysis_prompt = MCPPrompt(
    name = "analyze_code",
    description = "Code review prompt",
    arguments = [
        PromptArgument(
            name = "language",
            required = true,
            description = "Programming language"
        )
    ],
    messages = [
        PromptMessage(
            content = TextContent(text = "Review this {language} code:")
        )
    ]
)
```

## Content Types

### Basic Content

#### `TextContent`

```julia
TextContent(;
    type::String = "text",                # Content type identifier (always "text")
    text::String,                          # Text content
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

#### `ImageContent`

```julia
ImageContent(;
    type::String = "image",               # Content type identifier (always "image")
    data::Vector{UInt8},                   # Raw binary data (NOT base64)
    mime_type::String,                     # e.g., "image/png"
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

**Important:** Pass raw bytes, not base64. Encoding happens automatically during serialization.

### Advanced Content

#### `EmbeddedResource`

```julia
EmbeddedResource(;
    type::String = "resource",            # Content type identifier (always "resource")
    resource::Dict{String,Any},           # The embedded resource data
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

#### `ResourceLink`

```julia
ResourceLink(;
    type::String = "link",                # Content type identifier (always "link")
    href::String,                          # URL or URI of the linked resource
    title::Union{String,Nothing} = nothing,  # Optional human-readable title
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

### Resource Contents

#### `TextResourceContents`

```julia
# Note: URI field accepts strings which auto-convert to URI internally
TextResourceContents(;
    uri::URI,                             # Resource URI (accepts strings, stored as URI)
    mime_type::String = "text/plain",     # MIME type of the text content
    text::String                          # Text content
)
```

#### `BlobResourceContents`

```julia
# Note: URI field accepts strings which auto-convert to URI internally
BlobResourceContents(;
    uri::URI,                             # Resource URI (accepts strings, stored as URI)
    mime_type::String = "application/octet-stream",  # MIME type of the binary content
    blob::Vector{UInt8}                   # Binary data
)
```

## Control Types

### `CallToolResult`

Return explicit results or errors from tool handlers.

```julia
CallToolResult(;
    content::Vector{Dict{String,Any}},    # Serialized content dicts
    is_error::Bool = false                # Whether this is an error
)
```

**Important:** Content must be pre-serialized dictionaries, not Content objects.

**Example:**

```julia
file_tool = MCPTool(
    name = "read_file",
    description = "Read file contents",
    parameters = [
        ToolParameter(
            name = "path", 
            type = "string", 
            description = "Path to list files from",
            required = true
        )
    ],
    handler = function(params)
        path = params["path"]
        if !isfile(path)
            # Return error result
            return CallToolResult(
                content = [Dict(
                    "type" => "text",
                    "text" => "File not found: $path"
                )],
                is_error = true
            )
        end
        # Normal return
        TextContent(text = read(path, String))
    end
)
```

## Transport Types

### `StdioTransport`

Standard input/output transport (default).

```julia
StdioTransport(;
    input::IO = stdin,
    output::IO = stdout
)
```

### `HttpTransport`

HTTP transport with Server-Sent Events support.

```julia
HttpTransport(;
    host::String = "127.0.0.1",          # Bind address
    port::Int = 8080,                    # Port number
    endpoint::String = "/",              # Endpoint path
    protocol_version::String = "2025-06-18",  # Must be this value
    session_required::Bool = false,      # Require session validation
    allowed_origins::Vector{String} = [] # CORS origins
)
```

**Critical HTTP Transport Notes:**
1. Always call `connect(transport)` before `start!(server)`
2. Server blocks on `start!` and runs until interrupted
3. Use `127.0.0.1` instead of `localhost` on Windows

**Example:**

```julia
# Create transport and server
transport = HttpTransport(port = 3000)

# Define tools first
tools = [
    MCPTool(name = "tool1", description = "Tool 1", parameters = [], handler = (p) -> TextContent(text = "Result 1")),
    MCPTool(name = "tool2", description = "Tool 2", parameters = [], handler = (p) -> TextContent(text = "Result 2"))
]

server = mcp_server(
    name = "http-server",
    version = "1.0.0",  # Your server version
    tools = tools
)

# Connect first (binds port)
connect(transport)

# Start server with transport (blocks here)
start!(server, transport)  # Server runs until Ctrl+C
```

## Auto-Registration System

Automatically discover and load components from a directory structure.

**Path Resolution:** Relative paths provided to `auto_register_dir` are resolved relative to the project root directory.

```
components/
├── tools/
│   ├── calculator.jl    # Define MCPTool objects
│   └── file_ops.jl
├── resources/
│   └── data.jl         # Define MCPResource objects
└── prompts/
    └── templates.jl     # Define MCPPrompt objects
```

**Component File Requirements:**
- Each `.jl` file is loaded in an isolated module
- Define component variables (no exports needed)
- Components are auto-discovered by type

**Example component file:**

```julia
# tools/math.jl
add = MCPTool(
    name = "add",
    description = "Add two numbers",
    parameters = [
        ToolParameter(name = "a", type = "number", required = true),
        ToolParameter(name = "b", type = "number", required = true)
    ],
    handler = (p) -> TextContent(text = string(p["a"] + p["b"]))
)

multiply = MCPTool(
    name = "multiply",
    description = "Multiply two numbers",
    parameters = [
        ToolParameter(name = "x", type = "number", required = true),
        ToolParameter(name = "y", type = "number", required = true)
    ],
    handler = (p) -> TextContent(text = string(p["x"] * p["y"]))
)
```

**Usage:**

```julia
server = mcp_server(
    name = "auto-server",
    version = "1.0.0",  # Your server version
    auto_register_dir = "components"
)
start!(server)
```

## Multi-Content Responses

Tools can return multiple content items of different types:

```julia
analysis_tool = MCPTool(
    name = "analyze",
    description = "Analyze with text and visuals",
    parameters = [],  # Required field, use empty array for no parameters
    handler = function(params)
        # Example: generate chart data (in practice, use your chart library)
        chart_data = UInt8[0x89, 0x50, 0x4E, 0x47]  # PNG header bytes
        
        # Return multiple content types
        return [
            TextContent(text = "Analysis complete"),
            ImageContent(
                data = chart_data,  # Must be Vector{UInt8}
                mime_type = "image/png"
            ),
            TextContent(text = "See chart above")
        ]
    end
)
```

## Utility Functions

### `content2dict(content::Content) -> Dict{String,Any}`

Convert Content objects to dictionary representation for JSON serialization.

```julia
# Text content
text = TextContent(text = "Hello")
dict = content2dict(text)
# Returns: Dict("type" => "text", "text" => "Hello")

# Image (automatically base64 encodes)
image = ImageContent(data = [0x89, 0x50], mime_type = "image/png")
dict = content2dict(image)
# Returns: Dict("type" => "image", "data" => "iVA=", "mimeType" => "image/png")

# Resource link
link = ResourceLink(href = "resource://data", title = "Data Resource")
dict = content2dict(link)
# Returns: Dict("type" => "link", "href" => "resource://data", "title" => "Data Resource")

# Embedded resource
embedded = EmbeddedResource(
    resource = Dict(
        "uri" => "resource://text",
        "text" => "Content",
        "mimeType" => "text/plain"
    )
)
dict = content2dict(embedded)
# Returns: Dict("type" => "resource", "resource" => Dict(...))
```

**Use cases:**
- Debugging content objects
- Custom serialization
- Building CallToolResult content
- Testing and validation

## Advanced Features

### Progress Monitoring (Limited Support)

**Current Status:** Infrastructure exists but has significant limitations.

```julia
# Progress type definition
Progress(;
    token::Union{String,Int},      # Operation identifier
    current::Float64,              # Current progress value
    total::Union{Float64,Nothing}, # Total expected value (optional)
    message::Union{String,Nothing} = nothing  # Optional status message
)
```

**⚠️ Important Limitations:**
- No outbound notification mechanism from tool handlers
- Progress trackers maintained but not utilized
- Cannot emit progress updates during operations
- Consider polling-based alternatives for now

### Resource Subscriptions (Limited Implementation)

**Note:** Subscription methods exist but have limited functionality:
```julia
# Subscribe to resource updates (stores subscription but no notification mechanism yet)
subscribe!(server, "resource://data", callback_function)

# Unsubscribe from resource updates
unsubscribe!(server, "resource://data", callback_function)
```

**Current Limitations:**
- Subscriptions are stored but not triggered on resource changes
- No notification mechanism to inform clients of updates
- Consider polling resources directly for now

### Session Management (HTTP)

HTTP transport supports session management:
```julia
transport = HttpTransport(
    port = 3000,
    session_required = true  # Require session validation
)
```

Clients receive session ID in `Mcp-Session-Id` header after initialization.

## Common Patterns

### HTTP Server Setup

```julia
using ModelContextProtocol

# Define your tools
echo_tool = MCPTool(
    name = "echo",
    description = "Echo message",
    parameters = [
        ToolParameter(name = "msg", type = "string", required = true)
    ],
    handler = (p) -> TextContent(text = p["msg"])
)

status_tool = MCPTool(
    name = "status",
    description = "Get server status",
    parameters = [],
    handler = function(params)
        # Return multiple content items
        return [
            TextContent(text = "Server Status: Online"),
            TextContent(text = "Time: $(Dates.now())"),
            TextContent(text = "Version: 1.0.0")
        ]
    end
)

# Create server with tools
server = mcp_server(
    name = "http-example",
    version = "1.0.0",  # Your server version
    tools = [echo_tool, status_tool]
)

# Setup HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",  # Use IP on Windows
    port = 3000,
    session_required = false  # Set to true for session validation
)

# Connect and start
connect(transport)  # Must come first for HTTP
println("Server running on http://127.0.0.1:3000")
start!(server, transport = transport)  # Blocks until interrupted
```

### Stdio Server Setup

```julia
using ModelContextProtocol

# Create server with the same tools defined earlier
server = mcp_server(
    name = "stdio-example",
    version = "1.0.0",
    tools = [echo_tool, status_tool]  # Tools from HTTP example above
)

# For stdio, just call start! (no transport setup needed)
start!(server)  # Uses StdioTransport() by default
# Or explicitly:
start!(server, transport = StdioTransport())
```

### Error Handling

```julia
safe_tool = MCPTool(
    name = "safe_op",
    description = "Perform operation with error handling",
    parameters = [
        ToolParameter(name = "input", type = "string", required = true)
    ],
    handler = function(params)
        try
            result = risky_operation(params["input"])
            return TextContent(text = result)
        catch e
            return CallToolResult(
                content = [Dict(
                    "type" => "text",
                    "text" => "Error: $(string(e))"
                )],
                is_error = true
            )
        end
    end
)
```

### Working with Parameter Defaults

```julia
config_tool = MCPTool(
    name = "configure",
    description = "Configure settings with smart defaults",
    parameters = [
        ToolParameter(
            name = "timeout",
            type = "number",
            default = 30.0  # Applied when not provided
        ),
        ToolParameter(
            name = "retries",
            type = "integer",
            default = 3
        )
    ],
    handler = function(params)
        # Defaults are automatically applied
        timeout = params["timeout"]  # Will be 30.0 if not provided
        retries = params["retries"]  # Will be 3 if not provided
        TextContent(text = "Config: timeout=$timeout, retries=$retries")
    end
)
```

### Working with Resources

```julia
# Static resource with fixed data
static_resource = MCPResource(
    uri = "resource://config",
    name = "Configuration",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "setting1" => "value1",
        "setting2" => "value2"
    )
)

# Dynamic resource with real-time data
using Dates
dynamic_resource = MCPResource(
    uri = "resource://metrics",
    name = "System Metrics",
    description = "Real-time system metrics",
    mime_type = "application/json",
    data_provider = function()
        # Called each time resource is accessed
        return Dict(
            "timestamp" => now(),
            "memory_free" => Sys.free_memory(),
            "cpu_threads" => Sys.CPU_THREADS,
            "julia_version" => VERSION
        )
    end
)

# File-based resource
file_resource = MCPResource(
    uri = "file://readme",
    name = "README",
    mime_type = "text/plain",
    data_provider = () -> read("README.md", String)
)

# Resource with annotations
# Resource with annotations (using LittleDict for performance)
using DataStructures: LittleDict
annotated_resource = MCPResource(
    uri = "resource://data",
    name = "Annotated Data",
    mime_type = "application/json",
    data_provider = () -> Dict("data" => [1, 2, 3]),
    annotations = LittleDict(
        "version" => "1.0",
        "author" => "System",
        "readonly" => true
    )
)
```

## Integration with Claude Desktop

### stdio Transport

Edit Claude Desktop config:

```json
{
  "mcpServers": {
    "my-julia-server": {
      "command": "julia",
      "args": ["--project=/path/to/project", "server.jl"]
    }
  }
}
```

### HTTP Transport

1. Start your HTTP server:
   ```bash
   julia --project my_http_server.jl
   ```

2. Configure Claude Desktop to connect:
   ```json
   {
     "mcpServers": {
       "my-http-server": {
         "command": "npx",
         "args": ["mcp-remote", "http://127.0.0.1:3000", "--allow-http"]
       }
     }
   }
   ```

**Note:** HTTP server must be running before Claude Desktop connects.

## Protocol Compliance and API Stability

### Protocol Version Support

ModelContextProtocol.jl **strictly enforces MCP protocol version 2025-06-18**.

- **Single Version**: Only protocol version `2025-06-18` is accepted
- **No Negotiation**: Protocol version negotiation is not supported
- **Automatic Handling**: The protocol version is managed internally
- **Error on Mismatch**: Other protocol versions result in immediate error

### API Stability Guarantees

| Component | Stability | Notes |
|-----------|-----------|--------|
| Core Functions | Stable | `mcp_server`, `start!`, `register!` |
| Type Constructors | Stable | `MCPTool`, `MCPResource`, `MCPPrompt` |
| Content Types | Stable | `TextContent`, `ImageContent`, etc. |
| Transport APIs | Stable | `StdioTransport`, `HttpTransport` |
| Handler Signatures | Stable | `Dict{String,Any} -> Content` pattern |
| Auto-registration | Stable | Directory-based component loading |
| Progress Monitoring | Experimental | Limited implementation |
| Resource Subscriptions | Not Implemented | Placeholder only |

### Semantic Versioning

This package follows semantic versioning:
- **Major**: Breaking API changes
- **Minor**: New features, backward compatible
- **Patch**: Bug fixes, backward compatible

## Complete Example

```julia
#!/usr/bin/env julia
using ModelContextProtocol
using Dates  # Required for now() function

# Tool with defaults
time_tool = MCPTool(
    name = "get_time",
    description = "Get formatted time",
    parameters = [
        ToolParameter(
            name = "format",
            type = "string",
            description = "Time format",
            default = "HH:MM:SS"
        )
    ],
    handler = function(params)
        fmt = get(params, "format", "HH:MM:SS")
        return TextContent(text = Dates.format(now(), fmt))
    end
)

# Tool with error handling
calc_tool = MCPTool(
    name = "calculate",
    description = "Safe calculator",
    parameters = [
        ToolParameter(
            name = "expr",
            type = "string",
            description = "Expression to calculate",
            required = true
        )
    ],
    handler = function(params)
        try
            result = eval(Meta.parse(params["expr"]))
            return TextContent(text = "Result: $result")
        catch e
            return CallToolResult(
                content = [Dict(
                    "type" => "text",
                    "text" => "Invalid expression: $(string(e))"
                )],
                is_error = true
            )
        end
    end
)

# Initialize tracking variables
const start_time = time()
request_count = Ref(0)  # Use Ref for mutable global

# Modified resource to use the tracking variables
stats_resource = MCPResource(
    uri = "stats://server",
    name = "Server Statistics",
    mime_type = "application/json",
    data_provider = () -> begin
        request_count[] += 1  # Increment on each access
        Dict(
            "uptime" => time() - start_time,
            "requests" => request_count[]
        )
    end
)

# Create and start server
server = mcp_server(
    name = "example-server",
    version = "1.0.0",
    tools = [time_tool, calc_tool],
    resources = stats_resource
)

start!(server)
```

## Common Gotchas and Best Practices

### Top 10 Mistakes to Avoid

1. **Forgetting the `parameters` field in MCPTool**
   ```julia
   # ❌ Wrong - will throw error
   MCPTool(name = "bad", description = "Bad tool", handler = (p) -> TextContent(text = "Fail"))
   
   # ✅ Correct - always include parameters
   MCPTool(name = "good", description = "Good tool", parameters = [], handler = (p) -> TextContent(text = "Success"))
   ```

2. **Using localhost instead of 127.0.0.1 on Windows**
   ```julia
   # ❌ May fail on Windows
   HttpTransport(host = "localhost", port = 3000)
   
   # ✅ Always works
   HttpTransport(host = "127.0.0.1", port = 3000)
   ```

3. **Forgetting to call connect() for HTTP transport**
   ```julia
   # ❌ Wrong order
   transport = HttpTransport(port = 3000)
   start!(server, transport = transport)  # Will fail!
   
   # ✅ Correct order
   transport = HttpTransport(port = 3000)
   connect(transport)  # Must come first
   start!(server, transport = transport)
   ```

4. **Passing base64 data to ImageContent**
   ```julia
   # ❌ Wrong - don't base64 encode
   ImageContent(data = base64encode(image_bytes), mime_type = "image/png")
   
   # ✅ Correct - pass raw bytes
   ImageContent(data = image_bytes, mime_type = "image/png")
   ```

5. **Not handling missing parameters with defaults**
   ```julia
   # ❌ Risky - will error if param missing
   handler = (p) -> TextContent(text = "Value: $(p["optional"])")
   
   # ✅ Safe - use get() with default
   handler = (p) -> TextContent(text = "Value: $(get(p, "optional", "default"))")
   ```

6. **Modifying server internals directly**
   ```julia
   # ❌ Never access internal state directly
   # Internal fields may change between versions
   
   # ✅ Use public API
   stop!(server)
   ```

7. **Blocking forever in handlers**
   ```julia
   # ❌ Blocks other requests
   handler = function(params)
       sleep(60)  # Bad!
       TextContent(text = "Done")
   end
   
   # ✅ Quick return
   handler = function(params)
       # Start async work and return immediately
       @async do_slow_work()
       TextContent(text = "Started processing")
   end
   ```

8. **Not using --project flag**
   ```julia
   # ❌ May fail with missing deps
   julia server.jl
   
   # ✅ Always use project
   julia --project server.jl
   ```

9. **Expecting RequestContext in handlers**
   ```julia
   # ❌ Handlers don't receive context
   handler = function(params, ctx)  # Wrong signature!
       # ...
   end
   
   # ✅ Only params dictionary
   handler = function(params)
       # Use closures for state
   end
   ```

10. **Returning wrong Content format in CallToolResult**
    ```julia
    # ❌ Wrong - passing Content objects
    CallToolResult(content = [TextContent(text = "Error")], is_error = true)
    
    # ✅ Correct - must be dictionaries
    CallToolResult(content = [Dict("type" => "text", "text" => "Error")], is_error = true)
    ```

## Troubleshooting

### Common Issues and Solutions

#### Port Already in Use (HTTP)
**Problem:** "bind: address already in use" error when starting HTTP server.

**Solution:**
```bash
# Find process using the port
lsof -i :3000  # On Linux/Mac
netstat -ano | findstr :3000  # On Windows

# Kill the process or use a different port
transport = HttpTransport(port = 3001)  # Use alternative port
```

#### JIT Compilation Timeout
**Problem:** First request times out or takes very long.

**Solution:**
```julia
# Precompile your server before starting
julia --project -e 'using Pkg; Pkg.precompile()'

# Or add warmup in your server script
# Define your tools first
tools = [
    MCPTool(name = "tool1", description = "Tool 1", parameters = [], handler = (p) -> TextContent(text = "Result")),
    MCPTool(name = "tool2", description = "Tool 2", parameters = [], handler = (p) -> TextContent(text = "Result"))
]

server = mcp_server(
    name = "example",
    version = "1.0.0",  # Your server version
    tools = tools
)
# Warm up the JIT by calling handlers once
for tool in server.tools
    try
        tool.handler(Dict())  # Dummy call to trigger compilation
    catch
        # Ignore warmup errors
    end
end
start!(server)
```

#### Windows localhost Connection Issues
**Problem:** Cannot connect to server using `localhost` on Windows.

**Solution:** Always use `127.0.0.1` instead of `localhost`:
```julia
# ✗ Incorrect on Windows
transport = HttpTransport(host = "localhost", port = 3000)

# ✓ Correct
transport = HttpTransport(host = "127.0.0.1", port = 3000)
```

#### Missing Session ID (HTTP)
**Problem:** Requests fail with "Session required" after initialization.

**Solution:** Extract and include session ID from initialization response:
```bash
# Save session ID from init response
SESSION_ID=$(curl -X POST http://127.0.0.1:3000/ \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' \
  | jq -r '.sessionId')

# Use in subsequent requests
curl -X POST http://127.0.0.1:3000/ \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}'
```

#### Tool Handler Errors
**Problem:** Tool crashes or returns unexpected results.

**Solution:** Always wrap handlers in try-catch:
```julia
MCPTool(
    name = "safe_tool",
    description = "Tool with error handling",
    parameters = [],  # Required, even if empty
    handler = function(params)
        try
            # Your tool logic here
            result = process_data(params)
            return TextContent(text = result)
        catch e
            # Return error as CallToolResult
            return CallToolResult(
                content = [Dict("type" => "text", "text" => "Error: $(string(e))")],
                is_error = true
            )
        end
    end
)
```

## Performance Considerations

### JIT Compilation
Julia uses Just-In-Time compilation, which means:
- **First call is slow**: Initial execution compiles the code (5-10 seconds typical)
- **Subsequent calls are fast**: Compiled code runs at native speed
- **Precompilation helps**: Use `Pkg.precompile()` to reduce startup time

### Optimization Tips

1. **Precompile packages:**
   ```bash
   julia --project -e 'using Pkg; Pkg.precompile()'
   ```

2. **Use type annotations in performance-critical code:**
   ```julia
   # Slower
   handler = function(params)
       data = params["data"]
       process(data)
   end
   
   # Faster
   handler = function(params::Dict{String,Any})
       data::Vector{Float64} = params["data"]
       process(data)
   end
   ```

3. **Minimize allocations in handlers:**
   ```julia
   # Allocates new array each call
   handler = (p) -> TextContent(text = join(["Result: ", p["value"]]))
   
   # More efficient
   handler = (p) -> TextContent(text = "Result: $(p["value"])")
   ```

4. **Use `@time` and `@profile` for optimization:**
   ```julia
   # Define a tool for testing
   test_tool = MCPTool(
       name = "test",
       description = "Test tool",
       parameters = [ToolParameter(name = "value", type = "string", required = true)],
       handler = (p) -> TextContent(text = "Result: $(p["value"])")
   )
   
   # Measure handler performance
   test_params = Dict("value" => "test")
   @time test_tool.handler(test_params)
   
   # Profile for bottlenecks
   using Profile
   @profile for i in 1:100
       test_tool.handler(test_params)
   end
   Profile.print()
   ```

### Memory Management
- Tools handlers are called frequently - avoid memory leaks
- Clean up resources in error paths
- Use `WeakRef` for caching if needed

## Threading and Concurrency

### Current Limitations
- **Single-threaded by default**: Server processes requests sequentially
- **Blocking I/O**: Long-running handlers block other requests
- **No built-in async**: Handlers must complete before returning

### Thread Safety Considerations

**Important:** When using shared state in handlers (as shown in "Accessing Server State"), consider thread safety:

```julia
# Thread-safe shared state using locks
const state_lock = ReentrantLock()
const shared_data = Dict{String,Any}()

thread_safe_tool = MCPTool(
    name = "safe_update",
    description = "Thread-safe state updates",
    parameters = [
        ToolParameter(name = "key", type = "string", required = true),
        ToolParameter(name = "value", type = "string", required = true)
    ],
    handler = function(params)
        lock(state_lock) do
            # Critical section - only one handler at a time
            shared_data[params["key"]] = params["value"]
            return TextContent(text = "Updated $(params["key"])")
        end
    end
)

# Using Atomic for simple counters
const request_counter = Threads.Atomic{Int}(0)

counting_tool = MCPTool(
    name = "atomic_count",
    description = "Thread-safe counter",
    parameters = [],
    handler = function(params)
        count = Threads.atomic_add!(request_counter, 1) + 1
        TextContent(text = "Request #$count")
    end
)
```

### Best Practices
1. **Keep handlers fast**: Offload heavy work to background tasks
2. **Use timeouts**: Prevent indefinite blocking
3. **Return quickly**: Stream results via resources for long operations
4. **Use locks sparingly**: Minimize critical sections
5. **Prefer immutable data**: Reduces synchronization needs

### Future Considerations
The protocol supports progress notifications, but current implementation has limitations:
- No outbound notification mechanism from handlers
- Progress tracking infrastructure exists but isn't fully connected
- Consider polling-based progress checking as workaround

## Important Implementation Notes

### Handler Parameters
**Critical:** Tool handlers receive `Dict{String,Any}` parameters, NOT `RequestContext`:
```julia
# ✓ Correct
handler = function(params::Dict{String,Any})
    value = params["key"]
    # Process the value
    result = string(value) * " processed"
    return TextContent(text = result)
end

# ✗ Incorrect - handlers don't receive RequestContext
handler = function(params, ctx::RequestContext)
    # This won't work
end
```

### Accessing Server State from Handlers

While handlers don't receive server context directly, you can use closures to access shared state:

```julia
# Create shared state
const server_state = Dict{String,Any}(
    "request_count" => Ref(0),
    "last_request" => Ref(nothing)
)

# Tool that accesses shared state via closure
stateful_tool = MCPTool(
    name = "track_usage",
    description = "Tool that tracks its usage",
    parameters = [
        ToolParameter(name = "action", type = "string", required = true)
    ],
    handler = function(params)
        # Access and modify shared state
        server_state["request_count"][] += 1
        server_state["last_request"][] = params["action"]
        
        count = server_state["request_count"][]
        last = server_state["last_request"][]
        
        TextContent(text = "Request #$count: $last")
    end
)

# Alternative: Use a factory function
function create_stateful_tool(initial_count::Int = 0)
    count = Ref(initial_count)
    
    return MCPTool(
        name = "counter",
        description = "Counting tool",
        parameters = [],
        handler = function(params)
            count[] += 1
            TextContent(text = "Count: $(count[])")
        end
    )
end

# Create tool with encapsulated state
counter_tool = create_stateful_tool(100)
```

### Required Fields
⚠️ **CRITICAL: The `parameters` field is ALWAYS required**, even when empty. This is a common source of errors:
```julia
# ✓ Correct - empty array for no parameters
MCPTool(
    name = "no_params",
    description = "Tool without parameters",
    parameters = [],  # Required!
    handler = (p) -> TextContent(text = "Done")
)

# ✗ Incorrect - missing parameters field
MCPTool(
    name = "bad_tool",
    description = "This will fail",
    # parameters field missing - will cause error
    handler = (p) -> TextContent(text = "Done")
)
```

### Project Execution
Always use `--project` flag when running Julia MCP servers:
```bash
# ✓ Correct - loads project dependencies
julia --project server.jl
julia --project=/path/to/project server.jl
julia --project examples/time_server.jl

# For testing with MCP Inspector
julia --project examples/my_server.jl | npx @modelcontextprotocol/inspector

# For production with Claude Desktop config
julia --project=/absolute/path/to/project server.jl

# ✗ Incorrect - may fail with missing dependencies
julia server.jl
```

## Error Types and Handling

### JSON-RPC Error Codes

The package uses standard JSON-RPC error codes:

```julia
# Standard error codes (from ErrorCodes enum)
PARSE_ERROR = -32700        # Invalid JSON
INVALID_REQUEST = -32600    # Invalid JSON-RPC structure
METHOD_NOT_FOUND = -32601   # Unknown method
INVALID_PARAMS = -32602     # Invalid method parameters
INTERNAL_ERROR = -32603     # Internal server error
```

### Error Response Structure

```julia
# Error responses follow JSON-RPC format
{
    "jsonrpc": "2.0",
    "error": {
        "code": -32601,
        "message": "Method not found",
        "data": {"method": "unknown_method"}  # Optional additional data
    },
    "id": 1
}
```

### Handling Errors in Tool Handlers

```julia
# Pattern 1: Return CallToolResult with is_error=true
handler = function(params)
    if haskey(params, "invalid")
        return CallToolResult(
            content = [Dict("type" => "text", "text" => "Invalid parameter")],
            is_error = true
        )
    end
    # Normal processing
end

# Pattern 2: Let exceptions propagate (caught by framework)
handler = function(params)
    # This will be caught and converted to error response
    @assert haskey(params, "required") "Missing required parameter"
    # Normal processing
end

# Pattern 3: Explicit try-catch with logging
handler = function(params)
    try
        risky_operation(params)
    catch e
        @error "Tool failed" exception=(e, catch_backtrace())
        return CallToolResult(
            content = [Dict("type" => "text", "text" => "Operation failed: $(string(e))")],
            is_error = true
        )
    end
end
```

## Debugging Techniques

### Enable Logging

```julia
using Logging

# Set log level for detailed output
ENV["JULIA_DEBUG"] = "ModelContextProtocol"

# Or use a custom logger
global_logger(ConsoleLogger(stderr, Logging.Debug))
```

### Testing Tools Locally

```julia
# Test tool handler directly
tool = MCPTool(
    name = "test",
    description = "Test tool",
    parameters = [],
    handler = (p) -> TextContent(text = "Result")
)

# Call handler directly
result = tool.handler(Dict())
println("Result: ", result)

# Test with actual parameters
test_params = Dict("key" => "value")
result = tool.handler(test_params)
```

### Inspecting Server State

```julia
# After creating server
server = mcp_server(name = "debug-server", version = "1.0.0")

# Inspect registered components (stored as vectors)
println("Tools: ", [tool.name for tool in server.tools])
println("Resources: ", [res.name for res in server.resources])
println("Prompts: ", [prompt.name for prompt in server.prompts])

# Check server configuration
println("Server name: ", server.config.name)
println("Server version: ", server.config.version)
```

### Testing with curl

```bash
# Test HTTP server with verbose output
curl -v -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}},"id":1}' \
  | jq .
```

## Notes

### Critical Implementation Details
- Tool handlers receive `Dict{String,Any}` parameters (not RequestContext)
- Parameters field is ALWAYS required for tools (use `[]` for no parameters)
- Binary data in ImageContent must be raw bytes (`Vector{UInt8}`), NOT base64
- HTTP transport requires `connect()` before `start!()`
- Use `127.0.0.1` instead of `localhost` on Windows
- Auto-registration loads each file in isolated module
- CallToolResult requires pre-serialized content dictionaries
- First execution will be slow due to JIT compilation (5-10 seconds typical)
- Always use `julia --project` to ensure dependencies are loaded

### Type System Notes
- Abstract types (`Content`, `Transport`, `Resource`) for extensibility
- Concrete types use `@kwdef` for keyword constructors
- Small dictionaries use `LittleDict` from DataStructures.jl (auto-imported)
- URI fields accept strings but store as `URI` objects internally

### Protocol Compliance
- Strictly enforces protocol version 2025-06-18 (no negotiation)
- JSON-RPC batching not supported (returns error)
- Session management required for HTTP transport
- ResourceLink is new in protocol version 2025-06-18
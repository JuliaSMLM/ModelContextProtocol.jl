# ModelContextProtocol.jl API Reference

## Overview

ModelContextProtocol.jl provides a Julia implementation of the Model Context Protocol (MCP) version 2025-06-18, enabling standardized communication between AI applications and external tools, resources, and data sources.

**Protocol Version:** This implementation exclusively supports MCP protocol version `2025-06-18`. No other versions are accepted.

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
   - Small maps use `LittleDict` for performance

4. **Handler Design**:
   - Tool handlers receive `Dict{String,Any}` parameters for JSON flexibility
   - Support multiple return types with automatic conversion
   - `CallToolResult` for explicit control when needed

5. **Minimal Public API**: Only essential types and functions are exported. Internal complexity remains internal.

## Quick Start

```julia
using ModelContextProtocol

# Create a simple tool
my_tool = MCPTool(
    name = "hello",
    description = "Say hello",
    parameters = [],
    handler = (params) -> TextContent(text = "Hello, world!")
)

# Create and start a server
server = mcp_server(
    name = "my-server",
    tools = my_tool
)

start!(server)  # Uses stdio transport by default
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
    version::String = "2024-11-05",      # Server implementation version (NOT protocol)
    description::String = "",            # Server description
    tools = nothing,                     # Single tool or Vector{MCPTool}
    resources = nothing,                 # Single resource or Vector{MCPResource}
    prompts = nothing,                   # Single prompt or Vector{MCPPrompt}
    auto_register_dir = nothing         # Directory for auto-registration
) -> Server
```

**Important Version Clarification:**
- `version` parameter: Your server's implementation version (any string, defaults to "2024-11-05")
- Protocol version: Always "2025-06-18" (hardcoded, only supported version)

**Examples:**

```julia
# Simple server
server = mcp_server(name = "simple")

# Server with components
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

```julia
transport = HttpTransport(port = 3000)
connect(transport)  # Binds port, starts HTTP server
```

#### `register!(server::Server, component)`

Register components after server creation.

```julia
register!(server, my_tool)      # Add tool
register!(server, my_resource)  # Add resource
register!(server, my_prompt)    # Add prompt
```

## Component Types

### Tools

#### `MCPTool`

Define a tool that can be invoked by clients.

```julia
MCPTool(;
    name::String,                          # Unique identifier
    description::String,                   # Human-readable description
    parameters::Vector{ToolParameter},    # Input parameters (required, use [] for none)
    handler::Function,                     # (Dict -> Content) handler
    return_type::Type = Vector{Content}   # Expected return type
)
```

**Handler Return Types:**
- Single `Content` subtype (auto-wrapped in vector if return_type is Vector{Content})
- `Vector{<:Content}` for multiple items
- `CallToolResult` for explicit control (ignores return_type)
- `String` (auto-wrapped in TextContent)
- `Dict` (converted to JSON and wrapped in TextContent)

#### `ToolParameter`

Define tool parameters with optional defaults.

```julia
ToolParameter(;
    name::String,                    # Parameter name
    description::String,             # Description
    type::String,                    # JSON Schema type (e.g., "string", "number", "boolean")
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
    annotations::Dict = Dict()            # Metadata
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

#### `PromptMessage`

Messages in prompts.

```julia
PromptMessage(;
    content::Content,                # Message content
    role::Role = user                # Role (user or assistant)
)
```

**Note:** The `Role` enum has values `user` and `assistant`. The default is `user` for most cases.

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
    text::String,                          # Text content
    annotations::Dict = Dict()             # Metadata
)
```

#### `ImageContent`

```julia
ImageContent(;
    data::Vector{UInt8},                   # Raw binary data (NOT base64)
    mime_type::String,                     # e.g., "image/png"
    annotations::Dict = Dict()
)
```

**Important:** Pass raw bytes, not base64. Encoding happens automatically during serialization.

### Advanced Content

#### `EmbeddedResource`

```julia
EmbeddedResource(;
    resource::ResourceContents,            # Text or Blob resource contents
    annotations::Dict = Dict()
)
```

#### `ResourceLink`

```julia
ResourceLink(;
    uri::String,                          # Resource URI
    name::String,                         # Resource name
    description::Union{String,Nothing} = nothing,
    mime_type::Union{String,Nothing} = nothing,
    title::Union{String,Nothing} = nothing,
    size::Union{Float64,Nothing} = nothing,
    annotations::Dict = Dict()
)
```

### Resource Contents

#### `TextResourceContents`

```julia
TextResourceContents(;
    uri::String,                          # Resource URI
    text::String,                         # Text content
    mime_type::Union{String,Nothing} = nothing
)
```

#### `BlobResourceContents`

```julia
BlobResourceContents(;
    uri::String,                          # Resource URI
    blob::Vector{UInt8},                  # Binary data
    mime_type::Union{String,Nothing} = nothing
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
        ToolParameter(name = "path", type = "string", required = true)
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
server = mcp_server(name = "http-server", tools = my_tools)

# Connect first (binds port)
connect(transport)

# Set transport and start (blocks here)
server.transport = transport
start!(server)  # Server runs until Ctrl+C
```

## Auto-Registration System

Automatically discover and load components from a directory structure:

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
        # Return multiple content types
        return [
            TextContent(text = "Analysis complete"),
            ImageContent(
                data = generate_chart(),  # Returns Vector{UInt8}
                mime_type = "image/png"
            ),
            TextContent(text = "See chart above")
        ]
    end
)
```

## Utility Functions

### `content2dict(content::Content) -> Dict{String,Any}`

Convert Content objects to dictionary representation.

```julia
# Text content
text = TextContent(text = "Hello")
dict = content2dict(text)
# Returns: Dict("type" => "text", "text" => "Hello")

# Image (automatically base64 encodes)
image = ImageContent(data = [0x89, 0x50], mime_type = "image/png")
dict = content2dict(image)
# Returns: Dict("type" => "image", "data" => "iVA=", "mimeType" => "image/png")
```

**Use cases:**
- Debugging content objects
- Custom serialization
- Building CallToolResult content

## Known Limitations

### Progress Monitoring

The codebase includes progress monitoring infrastructure (`Progress`, `ProgressToken` types) but **cannot send progress notifications** because:
- No bidirectional notification mechanism implemented
- Tool handlers execute synchronously
- Server can only respond to requests, not push updates

### Subscriptions

Resource subscription methods (`subscribe!`, `unsubscribe!`) are exported but functionality is incomplete:
- No mechanism to notify subscribers of updates
- Subscription registry exists but unused

### Session Management

HTTP transport supports session IDs but with limited functionality:
- Session validation after initialization
- No session persistence
- No session timeout handling

## Common Patterns

### HTTP Server Setup

```julia
using ModelContextProtocol

# Define your tools
my_tool = MCPTool(
    name = "echo",
    description = "Echo message",
    parameters = [
        ToolParameter(name = "msg", type = "string", required = true)
    ],
    handler = (p) -> TextContent(text = p["msg"])
)

# Create server
server = mcp_server(
    name = "http-example",
    tools = my_tool
)

# Setup HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",  # Use IP on Windows
    port = 3000
)

# Connect and start
connect(transport)  # Must come first
server.transport = transport
println("Server running on http://127.0.0.1:3000")
start!(server)  # Blocks until interrupted
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

### Working with Defaults

```julia
config_tool = MCPTool(
    name = "configure",
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

## Protocol Compliance

ModelContextProtocol.jl **only supports MCP protocol version 2025-06-18**.

- Attempting to initialize with any other version results in an error
- No version negotiation performed
- Strict compliance with 2025-06-18 specification

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
        TextContent(text = Dates.format(now(), fmt))
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
            TextContent(text = "Result: $result")
        catch e
            CallToolResult(
                content = [Dict(
                    "type" => "text",
                    "text" => "Invalid expression: $(string(e))"
                )],
                is_error = true
            )
        end
    end
)

# Resource
stats_resource = MCPResource(
    uri = "stats://server",
    name = "Server Statistics",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "uptime" => time() - start_time,
        "requests" => request_count
    )
)

# Create and start server
server = mcp_server(
    name = "example-server",
    version = "1.0.0",
    tools = [time_tool, calc_tool],
    resources = stats_resource
)

global start_time = time()
global request_count = 0

start!(server)
```

## Notes

- Tool handlers receive `Dict{String,Any}` parameters
- Binary data in ImageContent must be raw bytes (`Vector{UInt8}`)
- HTTP transport requires `connect()` before `start!()`
- Use `127.0.0.1` instead of `localhost` on Windows
- Auto-registration loads each file in isolated module
- CallToolResult requires pre-serialized content dictionaries
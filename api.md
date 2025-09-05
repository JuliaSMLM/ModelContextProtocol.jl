# ModelContextProtocol.jl API Reference

## Overview

ModelContextProtocol.jl provides a Julia implementation of the Model Context Protocol (MCP) version 2025-06-18, enabling standardized communication between AI applications and external tools, resources, and data sources.

**Protocol Support:** This implementation exclusively supports MCP protocol version `2025-06-18`. No other protocol versions are supported.

## API Design Philosophy

### Why These Design Choices?

1. **CallToolResult uses Dict instead of Content objects**: This is a low-level API for direct JSON-RPC responses. When returning CallToolResult, you're taking full control of the response structure, bypassing automatic Content serialization.

2. **Role as an enum with default 'user'**: The Role enum provides type safety while defaulting to the most common case (user). The enum values are intentionally not exported to keep the API surface clean - 99% of use cases just need the default.

3. **Separate connect() for HttpTransport**: HTTP servers need explicit startup to bind ports and initialize SSE streams, while stdio transport uses existing file descriptors. This separation allows for better error handling and resource management.

4. **Abstract types in exports**: Types like `Content`, `Transport`, and `ResourceContents` are exported for type annotations in user code, enabling better documentation and type checking.

### Quick Start

```julia
using ModelContextProtocol

# Create a simple tool
my_tool = MCPTool(
    name = "hello",
    description = "Say hello",
    parameters = [],
    handler = (p) -> TextContent(text = "Hello, world!")
)

# Create and start a server
server = mcp_server(
    name = "my-server",
    tools = my_tool
)

start!(server)  # Uses stdio transport by default
```

## Core Functions

### `mcp_server`

Create an MCP server instance with tools, resources, and prompts.

```julia
mcp_server(;
    name::String,                    # Required: Server name
    version::String = "2024-11-05",  # Server implementation version (NOT protocol version)
    description::String = "",        # Server description
    tools = nothing,                 # Single tool or Vector{MCPTool}
    resources = nothing,             # Single resource or Vector{MCPResource}
    prompts = nothing,               # Single prompt or Vector{MCPPrompt}
    auto_register_dir = nothing     # Directory for auto-registration
) -> Server
```

**Examples:**

```julia
# Simple server
server = mcp_server(name = "simple-server")

# Server with components
server = mcp_server(
    name = "full-server",
    tools = [tool1, tool2],
    resources = my_resource,
    prompts = [prompt1, prompt2]
)

# Auto-registration from directory
server = mcp_server(
    name = "auto-server",
    auto_register_dir = "mcp_components"  # Scans tools/, resources/, prompts/ subdirs
)
```

### Server Operations

#### `start!(server::Server; transport::Union{Transport,Nothing}=nothing)`

Start the MCP server and begin processing requests.

```julia
# Default stdio transport
start!(server)

# Override transport at start time
start!(server, transport = HttpTransport(port = 3000))

# Or set transport beforehand
transport = HttpTransport(port = 3000)
server.transport = transport
# For HTTP, connect first:
using ModelContextProtocol: connect
connect(transport)
start!(server)
```

#### `stop!(server::Server)`

Stop a running MCP server and clean up resources.

```julia
stop!(server)
```

**Behavior:**
- Closes all active connections
- Releases bound ports (for HTTP transport)
- Sets server.active to false
- Safe to call multiple times
- Server can be restarted with start! after stopping

#### `connect(transport::HttpTransport)`

Initialize and start the HTTP server for an HttpTransport.

```julia
transport = HttpTransport(port = 3000)
connect(transport)  # Starts HTTP server on port 3000
```

**Note:** Only required for HttpTransport. StdioTransport doesn't need connect.

#### `register!(server::Server, component)`

Register a component with the server after creation.

```julia
register!(server, my_tool)
register!(server, my_resource)
register!(server, my_prompt)
```

## Component Types

### Tools

#### `MCPTool`

Define a tool that can be invoked by clients.

```julia
MCPTool(;
    name::String,                              # Unique identifier
    description::String,                       # Human-readable description
    parameters::Vector{ToolParameter},        # Input parameters
    handler::Function,                         # (Dict -> Content) handler
    return_type::Type = Vector{Content}       # Expected return type
)
```

#### `ToolParameter`

Define tool parameters.

```julia
ToolParameter(;
    name::String,                    # Parameter name
    type::String,                    # JSON Schema type ("string", "number", "boolean", etc.)
    description::String = "",        # Parameter description
    required::Bool = false,          # Whether required
    default::Any = nothing           # Default value
)
```

**Example:**

```julia
calculator = MCPTool(
    name = "calculate",
    description = "Perform calculations",
    parameters = [
        ToolParameter(
            name = "expression",
            type = "string",
            description = "Math expression",
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
        precision = params["precision"]
        TextContent(text = "Result: $(round(result, digits=Int(precision)))")
    end
)
```

### Resources

#### `MCPResource`

Define a resource that provides data.

```julia
MCPResource(;
    uri::Union{String, URI},              # Resource URI (auto-converts strings)
    name::String,                         # Human-readable name
    description::String = "",             # Resource description
    mime_type::String = "application/json", # MIME type
    data_provider::Function,              # () -> data function
    annotations::Dict = Dict()            # Metadata
)
```

Note: The `uri` field is stored internally as a `URI` object, but the constructor accepts either strings or URI objects for convenience.

#### `ResourceTemplate`

Define templates for dynamic resources.

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
config_resource = MCPResource(
    uri = "config://app",
    name = "Application Config",
    description = "App configuration data",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "version" => "1.0",
        "settings" => Dict("debug" => false)
    )
)
```

### Prompts

#### `MCPPrompt`

Define prompt templates.

```julia
MCPPrompt(;
    name::String,                              # Prompt identifier
    description::String = "",                  # Prompt description
    arguments::Vector{PromptArgument} = [],   # Input arguments
    messages::Vector{PromptMessage} = []      # Template messages
)
```

#### `PromptArgument`

Define prompt arguments.

```julia
PromptArgument(;
    name::String,                    # Argument name
    description::String = "",        # Argument description
    required::Bool = false           # Whether required
)
```

#### `PromptMessage`

Define prompt messages.

```julia
PromptMessage(;
    content::Content,                # Message content
    role::Role = user                # Message role (defaults to user)
)
```

**Example:**

```julia
code_review = MCPPrompt(
    name = "review_code",
    description = "Review code for issues",
    arguments = [
        PromptArgument(
            name = "language",
            description = "Programming language",
            required = true
        )
    ],
    messages = [
        PromptMessage(
            content = TextContent(text = "Review this {language} code for issues")
            # role defaults to 'user'
        )
    ]
)
```

## Content Types

### Basic Content

#### `TextContent`

Text-based content.

```julia
TextContent(;
    text::String,                          # Text content
    annotations::Dict = Dict()             # Optional metadata
)
```

#### `ImageContent`

Image content with binary data.

```julia
ImageContent(;
    data::Vector{UInt8},                   # Binary image data (NOT base64)
    mime_type::String,                     # MIME type (e.g., "image/png")
    annotations::Dict = Dict()
)
```

### Advanced Content

#### `EmbeddedResource`

Embed resource content in responses.

```julia
EmbeddedResource(;
    resource::Union{TextResourceContents, BlobResourceContents},
    annotations::Dict = Dict()
)
```

#### `ResourceLink`

Reference to a resource.

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

Text resource data.

```julia
TextResourceContents(;
    uri::String,                          # Resource URI
    text::String,                         # Text content
    mime_type::Union{String,Nothing} = nothing
)
```

#### `BlobResourceContents`

Binary resource data.

```julia
BlobResourceContents(;
    uri::String,                          # Resource URI
    blob::Vector{UInt8},                  # Binary data
    mime_type::Union{String,Nothing} = nothing
)
```

### Error Handling

#### `CallToolResult`

Return explicit errors from tools. When using CallToolResult, you must provide content as serialized dictionaries, not Content objects.

```julia
CallToolResult(;
    content::Vector{Dict{String,Any}},    # Serialized content dictionaries
    is_error::Bool = false                # Whether this is an error
)
```

**Important:** The `content` field requires dictionaries with the proper content structure (e.g., `Dict("type" => "text", "text" => "message")`), not Content objects.

**Example:**

```julia
file_tool = MCPTool(
    name = "read_file",
    handler = function(params)
        if !isfile(params["path"])
            return CallToolResult(
                content = [Dict("type" => "text", "text" => "File not found")],
                is_error = true
            )
        end
        TextContent(text = read(params["path"], String))
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
    protocol_version::String = "2025-06-18",  # MCP protocol version (only supported value)
    session_required::Bool = false,      # Require session validation
    allowed_origins::Vector{String} = []  # CORS origins
)
```

**Important:** For HTTP transport, the server runs as a long-running process. The `start!(server)` call will block and keep the server running until interrupted (Ctrl+C) or `stop!(server)` is called from another thread/task.

**Usage with HTTP:**

```julia
using ModelContextProtocol

# Create HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",  # Use IP on Windows, not "localhost"
    port = 3000
)

# Create server and set transport
server = mcp_server(name = "http-server", tools = my_tool)
server.transport = transport

# Connect transport (starts HTTP server, binds to port)
connect(transport)

# Start processing (blocks until server is stopped)
println("Server running on http://127.0.0.1:3000")
start!(server)  # This blocks! Server runs until Ctrl+C

# Alternative: Set transport in start!
server = mcp_server(name = "http-server", tools = my_tool)
transport = HttpTransport(port = 3000)
connect(transport)
start!(server, transport = transport)  # Also blocks
```

**Running as a Script:**
```bash
# Start the server (it will run continuously)
julia --project my_http_server.jl

# In another terminal, connect your MCP client
# The server stays running, handling multiple client connections
```

## Advanced Features

### Resource Subscriptions

Subscribe to resource updates.

```julia
# Subscribe to updates
subscribe!(server, "resource://path", callback_function)

# Unsubscribe
unsubscribe!(server, "resource://path", callback_function)
```

### Type Annotations

Use abstract types for type annotations:

```julia
function process_content(content::Content)
    # Works with any Content subtype
end

function setup_transport() :: Transport
    # Can return any Transport subtype
    return StdioTransport()
end
```

### Utility Functions

#### `content2dict(content::Content) -> Dict{String,Any}`

Convert any Content object to its dictionary representation for debugging or custom serialization.

```julia
# Text content
text = TextContent(text = "Hello")
dict = content2dict(text)
# Returns: Dict("type" => "text", "text" => "Hello")

# Image content (automatically base64 encodes)
image = ImageContent(data = [0x89, 0x50, 0x4E], mime_type = "image/png")
dict = content2dict(image)
# Returns: Dict("type" => "image", "data" => "iVBO", "mimeType" => "image/png")

# Embedded resource
resource = EmbeddedResource(
    resource = TextResourceContents(uri = "test", text = "data")
)
dict = content2dict(resource)
# Returns nested dictionary structure
```

**When to use:**
- Debugging content objects
- Custom serialization logic
- Testing tool outputs
- Inspecting multi-content responses

## Auto-Registration System

The auto-registration system discovers components from a directory structure:

```
my_project/
└── components/
    ├── tools/
    │   ├── calculator.jl    # Contains MCPTool definitions
    │   └── file_ops.jl
    ├── resources/
    │   └── data.jl          # Contains MCPResource definitions
    └── prompts/
        └── templates.jl      # Contains MCPPrompt definitions
```

Each `.jl` file should define component variables (no exports needed):

```julia
# tools/calculator.jl
add = MCPTool(
    name = "add",
    description = "Add numbers",
    parameters = [
        ToolParameter(name = "a", type = "number", required = true),
        ToolParameter(name = "b", type = "number", required = true)
    ],
    handler = (p) -> TextContent(text = string(p["a"] + p["b"]))
)

multiply = MCPTool(
    name = "multiply",
    description = "Multiply numbers",
    parameters = [
        ToolParameter(name = "a", type = "number", required = true),
        ToolParameter(name = "b", type = "number", required = true)
    ],
    handler = (p) -> TextContent(text = string(p["a"] * p["b"]))
)
```

Then use with:

```julia
server = mcp_server(
    name = "math-server",
    auto_register_dir = "components"
)
start!(server)
```

## Multi-Content Responses

Tools can return multiple content items:

```julia
analysis_tool = MCPTool(
    name = "analyze",
    description = "Analyze data",
    handler = function(params)
        # Return multiple content items
        return [
            TextContent(text = "Analysis complete"),
            ImageContent(
                data = generate_chart(),  # Returns Vector{UInt8}
                mime_type = "image/png"
            ),
            TextContent(text = "Chart shows trends")
        ]
    end,
    return_type = Vector{Content}  # Default
)
```

## Common Patterns

### Working with Prompt Messages

```julia
using ModelContextProtocol

# Most common: role defaults to 'user'
prompt = MCPPrompt(
    name = "example",
    messages = [
        PromptMessage(content = TextContent(text = "Question?"))  # defaults to user role
    ]
)

# If you need assistant role (rare):
# using ModelContextProtocol: assistant
# PromptMessage(role = assistant, content = ...)
```

### HTTP Server Pattern

```julia
using ModelContextProtocol

# Standard HTTP server setup
server = mcp_server(name = "my-server", tools = my_tools)
transport = HttpTransport(port = 3000)
connect(transport)  # Must connect first - binds port
server.transport = transport

println("Starting server on http://127.0.0.1:3000")
start!(server)  # Blocks here - server runs continuously

# Code after start! won't execute until server stops
println("Server stopped")  # Only prints after Ctrl+C
```

### Error Handling Pattern

```julia
tool = MCPTool(
    name = "safe_operation",
    handler = function(params)
        try
            # Risky operation
            result = process_data(params["input"])
            return TextContent(text = result)
        catch e
            # Return error using CallToolResult
            return CallToolResult(
                content = [Dict("type" => "text", "text" => "Error: $e")],
                is_error = true
            )
        end
    end
)
```

## Complete Examples

### Simple Echo Server

```julia
using ModelContextProtocol

echo = MCPTool(
    name = "echo",
    description = "Echo the message",
    parameters = [
        ToolParameter(
            name = "message",
            type = "string",
            description = "Message to echo",
            required = true
        )
    ],
    handler = (p) -> TextContent(text = p["message"])
)

server = mcp_server(
    name = "echo-server",
    tools = echo
)

start!(server)
```

### HTTP Server with Multiple Tools

```julia
using ModelContextProtocol

# Define tools
time_tool = MCPTool(
    name = "get_time",
    description = "Get current time",
    parameters = [],
    handler = (p) -> TextContent(text = string(now()))
)

calc_tool = MCPTool(
    name = "calculate",
    description = "Calculate expression",
    parameters = [
        ToolParameter(name = "expr", type = "string", description = "Math expression", required = true)
    ],
    handler = (p) -> TextContent(
        text = string(eval(Meta.parse(p["expr"])))
    )
)

# Create HTTP transport
transport = HttpTransport(port = 3000)

# Create server
server = mcp_server(
    name = "http-tools",
    tools = [time_tool, calc_tool]
)

# Configure transport
server.transport = transport
connect(transport)

println("Server running on http://127.0.0.1:3000")
start!(server)
```

### File Management Server with Error Handling

```julia
using ModelContextProtocol

read_file = MCPTool(
    name = "read_file",
    description = "Read file contents",
    parameters = [
        ToolParameter(name = "path", type = "string", description = "File path", required = true),
        ToolParameter(name = "encoding", type = "string", description = "File encoding", default = "utf-8")
    ],
    handler = function(params)
        path = params["path"]
        
        if !isfile(path)
            return CallToolResult(
                content = [Dict("type" => "text", "text" => "Error: File not found")],
                is_error = true
            )
        end
        
        try
            content = read(path, String)
            return [
                TextContent(text = "File: $path"),
                TextContent(text = content)
            ]
        catch e
            return CallToolResult(
                content = [Dict("type" => "text", "text" => "Error: $(string(e))")],
                is_error = true
            )
        end
    end
)

list_dir = MCPTool(
    name = "list_directory",
    description = "List directory contents",
    parameters = [
        ToolParameter(name = "path", type = "string", description = "Directory path", required = true)
    ],
    handler = function(params)
        path = params["path"]
        
        if !isdir(path)
            return TextContent(text = "Error: Not a directory")
        end
        
        files = readdir(path)
        TextContent(text = "Contents:\n" * join(files, "\n"))
    end
)

server = mcp_server(
    name = "file-server",
    tools = [read_file, list_dir]
)

start!(server)
```

## Integration with Claude Desktop

Configure Claude Desktop to use your MCP server:

### For stdio servers (default):
1. Go to Settings → Developer → Edit Config
2. Add your server configuration:

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

### For HTTP servers:
1. **First, start your HTTP server** (it needs to be running):
   ```bash
   julia --project my_http_server.jl
   # Server will run continuously, listening on the specified port
   ```

2. **Then configure Claude Desktop** to connect to the running server:
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

**Note:** The HTTP server must be started and running before Claude Desktop can connect to it. The server will continue running and can handle multiple client connections.

## Protocol Support

**Important:** ModelContextProtocol.jl **only supports MCP protocol version 2025-06-18**. This is the only protocol version accepted during initialization.

### Version Clarification
- **Protocol Version**: Always `"2025-06-18"` (hardcoded, only supported version)
- **Server Version** (`mcp_server` parameter): Your server's implementation version (defaults to `"2024-11-05"`, can be any string)
- **HttpTransport `protocol_version`**: Must be `"2025-06-18"` (the default)

Attempting to initialize with any protocol version other than `"2025-06-18"` will result in an error

## Notes

- Tools handlers receive parameters as `Dict{String,Any}`
- Resource data providers are zero-argument functions
- Content is automatically serialized to JSON
- Binary data in ImageContent should be raw bytes (Vector{UInt8}), not base64
- HTTP transport requires explicit `connect()` before `start!()`
- Use `127.0.0.1` instead of `localhost` on Windows for HTTP transport
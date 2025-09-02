# ModelContextProtocol.jl API Overview

## What is the Model Context Protocol (MCP)?

The Model Context Protocol (MCP) is an open standard introduced by Anthropic in 2024 that standardizes how AI applications connect with external tools, data sources, and systems. Think of it as "USB for AI integrations" - it provides a universal way for Large Language Models (LLMs) to access and interact with external resources without requiring custom integrations for each combination.

### MCP Architecture Overview

MCP follows a client-server architecture built on JSON-RPC 2.0, where:

- **MCP Hosts**: AI applications (Claude Desktop, IDEs, chatbots) that want to access external capabilities
- **MCP Clients**: Protocol clients embedded within hosts that maintain 1:1 connections with servers  
- **MCP Servers**: Lightweight programs that expose specific capabilities (tools, resources, prompts) through the standardized protocol
- **Transport Layer**: Communication mechanism using STDIO (local) or HTTP+SSE (remote/multi-client)

### Client-Server Interaction Flow

When an MCP server starts and a client connects, the following happens:

1. **Initialization Handshake**: Client and server exchange capabilities and protocol versions
2. **Capability Discovery**: Client requests what features (tools/resources/prompts) the server offers
3. **Registration**: Server responds with available capabilities, but doesn't send tool details yet
4. **Active Discovery**: Client must explicitly call `tools/list`, `resources/list`, or `prompts/list` to get actual definitions
5. **Invocation**: When the LLM needs to use a tool, the client sends invocation requests to the server
6. **Execution**: Server executes the request and returns structured results

### ModelContextProtocol.jl's Role

ModelContextProtocol.jl is a Julia implementation that makes it extremely easy to create MCP servers. It handles all the protocol complexity, JSON-RPC communication, and provides a developer-friendly API focused on simply defining tools, resources, and prompts.

## Architecture Overview

ModelContextProtocol.jl is built around several key architectural principles that make MCP server development intuitive:

### 1. **Auto-Registration System**

The package's flagship feature automatically discovers and registers MCP components without explicit registration code. This leverages Julia's metaprogramming capabilities to scan modules or directories for tool definitions.

### 2. **Content-Centric Design**

All communication revolves around `Content` objects that provide type safety while allowing flexibility:

```julia
abstract type Content end

Base.@kwdef struct TextContent <: Content
    type::String = "text"           # Required by MCP schema
    text::String                    # The actual text content
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}()  # Optional metadata
end

Base.@kwdef struct ImageContent <: Content
    type::String = "image"          # Required by MCP schema
    data::Vector{UInt8}            # Binary image data (NOT base64 string)
    mime_type::String              # MIME type of the image
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}()  # Optional metadata
end

Base.@kwdef struct EmbeddedResource <: Content
    type::String = "resource"       # Required by MCP schema
    resource::Union{TextResourceContents, BlobResourceContents}  # The embedded resource
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}()  # Optional metadata
end
```

### 3. **Functional Handler Pattern**

Tools, prompts, and resources use consistent handler functions:

```julia
# Tool handler: Dict -> Content or Vector{Content}
handler = (params::Dict) -> TextContent(text = "Result: $(params["input"])")

# Resource handler: String -> ResourceContents  
resource_handler = (uri::String) -> TextResourceContents(uri = uri, text = read(uri, String))

# Prompt handler: Dict -> MCPPromptMessage
prompt_handler = (args::Dict) -> MCPPromptMessage(role = "user", content = TextContent(...))
```

## Auto-Registration System Detailed

The auto-registration system is the core innovation that eliminates boilerplate. Here's how it works:

### Directory-Based Auto-Registration

The most powerful approach uses a structured directory layout:

```
my_mcp_project/
├── Project.toml
├── main.jl                 # Server startup script
└── mcp_components/         # Auto-registration directory
    ├── tools/              # Tool definitions
    │   ├── calculator.jl
    │   ├── file_reader.jl
    │   └── web_scraper.jl
    ├── resources/          # Resource definitions (optional)
    │   ├── docs.jl
    │   └── config.jl
    └── prompts/            # Prompt definitions (optional)
        └── code_review.jl
```

### How to Structure Components

Each `.jl` file in the component directories should define one or more MCP components:

**`tools/calculator.jl`**:
```julia
# Simple tool definition - no exports or module setup needed
calculator = MCPTool(
    name = "calculate",
    description = "Perform basic mathematical calculations",
    parameters = [
        ToolParameter(name = "expression", description = "Mathematical expression to evaluate", type = "string", required = true),
        ToolParameter(name = "precision", description = "Decimal places for rounding", type = "number", default = 2.0)
    ],
    handler = function(params)
        expr = params["expression"]
        precision = params["precision"]
        # Note: In production, use a safe expression parser instead of eval
        result = Base.eval(Main, Meta.parse(expr))
        return TextContent(text = "Result: $(round(result, digits=Int(precision)))")
    end
)
```

**`tools/file_reader.jl`**:
```julia
using Base64

file_tool = MCPTool(
    name = "read_file",
    description = "Read and return file contents",
    parameters = [
        ToolParameter(name = "path", description = "File path to read", type = "string", required = true),
        ToolParameter(name = "encoding", description = "Text encoding", type = "string", default = "utf-8")
    ],
    handler = function(params)
        path = params["path"]
        if !isfile(path)
            return CallToolResult(
                content = [TextContent(text = "File not found: $path")],
                is_error = true
            )
        end
        
        content = read(path, String)
        return [
            TextContent(text = "File: $path"),
            TextContent(text = content)
        ]
    end,
    return_type = Vector{Content}
)
```

**`resources/docs.jl`**:
```julia
docs_resource = MCPResource(
    uri = "docs://*",
    name = "Documentation",
    description = "Access to project documentation",
    mime_type = "text/markdown",
    data_provider = function(uri::String)
        # Strip the docs:// prefix and read file
        file_path = replace(uri, "docs://" => "docs/")
        if isfile(file_path)
            content = read(file_path, String)
            return TextResourceContents(
                uri = uri,
                mime_type = "text/markdown",
                text = content
            )
        else
            error("Documentation file not found: $file_path")
        end
    end
)
```

### Server Startup Script

**`main.jl`**:
```julia
#!/usr/bin/env julia

using Pkg
Pkg.activate(@__DIR__)  # Activate local project environment

using ModelContextProtocol

# Create server with auto-registration
server = mcp_server(
    name = "my-awesome-server",
    description = "A comprehensive MCP server with auto-discovered components",
    auto_register_dir = "mcp_components"  # Scans this directory structure
)

# Start the server (uses STDIO transport by default, see Transport Options section for HTTP)
println("Starting MCP Server...")
start!(server)
```

### Advanced Auto-Registration Features

#### 1. **Multiple Variables Per File**

Files can define multiple components:

```julia
# tools/math_tools.jl
add_tool = MCPTool(
    name = "add",
    description = "Add two numbers", 
    parameters = [
        ToolParameter(name = "a", type = "number", required = true),
        ToolParameter(name = "b", type = "number", required = true)
    ],
    handler = (p) -> TextContent(text = "$(p["a"] + p["b"])")
)

multiply_tool = MCPTool(
    name = "multiply", 
    description = "Multiply two numbers",
    parameters = [
        ToolParameter(name = "a", type = "number", required = true),
        ToolParameter(name = "b", type = "number", required = true)
    ],
    handler = (p) -> TextContent(text = "$(p["a"] * p["b"])")
)

# Both tools are automatically discovered
```

#### 2. **Auto-Registration Implementation**

The system works by scanning `.jl` files and looking for variables of the correct types:

```julia
function auto_register!(server::Server, dir::AbstractString)
    component_dirs = [
        ("tools", MCPTool),
        ("resources", MCPResource), 
        ("prompts", MCPPrompt)
    ]
    
    for (subdir, type) in component_dirs
        component_dir = joinpath(dir, subdir)
        if isdir(component_dir)
            for file in readdir(component_dir, join=true)
                if endswith(file, ".jl")
                    # Create temporary module and include file
                    mod = Module()
                    Core.eval(mod, :(using ModelContextProtocol))
                    Base.include(mod, file)
                    
                    # Find all variables matching the target type
                    for name in names(mod, all=true)
                        if isdefined(mod, name)
                            component = getfield(mod, name)
                            if component isa type
                                register!(server, component)
                                @info "Registered $type from $file: $name"
                            end
                        end
                    end
                end
            end
        end
    end
end
```

#### 3. **Benefits of Auto-Registration**

- **Zero Boilerplate**: No manual registration calls needed
- **File-Based Organization**: Natural separation of concerns
- **Dynamic Discovery**: Add new tools by creating new files
- **Error Isolation**: Problems in one file don't affect others
- **Clear Structure**: Easy to understand and maintain

### Module-Based Registration (Alternative Approach)

For simpler cases, you can also register from Julia modules:

```julia
module MyTools
using ModelContextProtocol

time_tool = MCPTool(
    name = "current_time",
    description = "Get current time",
    parameters = [],
    handler = (p) -> TextContent(text = string(now()))
)

weather_tool = MCPTool(
    name = "weather",
    description = "Get weather info",
    parameters = [ToolParameter(name = "location", description = "Location to get weather for", type = "string", required = true)],
    handler = (p) -> TextContent(text = "Weather in $(p["location"]): Sunny")
)
end

# Create server and register tools from module
server = mcp_server(name = "time-weather-server")

# Manual registration from module
for name in names(MyTools, all=true)
    obj = getfield(MyTools, name)
    if obj isa MCPTool
        register!(server, obj)
    end
end

start!(server)
```

## Type Hierarchy

```
Content (abstract)
├── TextContent            # Has: type="text", text, annotations
├── ImageContent          # Has: type="image", data::Vector{UInt8}, mime_type, annotations  
└── EmbeddedResource      # Has: type="resource", resource::Union{TextResourceContents, BlobResourceContents}, annotations

ResourceContents (abstract)
├── TextResourceContents  # Has: uri, text, mime_type::Union{String,Nothing}
└── BlobResourceContents  # Has: uri, blob::Vector{UInt8}, mime_type::Union{String,Nothing}

Tool (abstract)
└── MCPTool              # Has: name, description, parameters, handler, return_type

Resource (abstract)
└── MCPResource          # Has: uri::URI, name, description, mime_type, data_provider, annotations

MCPPrompt                # Has: name, description, arguments, messages (NO handler - static templates)
PromptArgument          # Has: name, description, required
PromptMessage           # Has: content, role

ResponseResult (abstract)
└── CallToolResult       # Has: content::Vector{Dict{String,Any}}, is_error::Bool (NO metadata field)
```

## Essential Types

### Tool Definition

```julia
Base.@kwdef struct MCPTool <: Tool
    name::String                    # Unique tool identifier
    description::String             # Human-readable description
    parameters::Vector{ToolParameter}  # Input parameters schema
    handler::Function               # Processing function
    return_type::Type = Vector{Content}  # Expected return type (v0.2+)
end

Base.@kwdef struct ToolParameter
    name::String                    # Parameter name
    description::String             # Parameter description
    type::String                    # JSON Schema type ("string", "number", "boolean", "object", "array")
    required::Bool = false          # Whether parameter is required
    default::Any = nothing          # Default value if not provided
end
```

### Content Types

```julia
# Text content constructor
TextContent(text = "Hello, world!")

# Image content constructor - note: data is Vector{UInt8}, not base64 string
ImageContent(
    data = image_bytes,  # Vector{UInt8}
    mime_type = "image/png"
)

# Embedded resource constructor
EmbeddedResource(
    resource = TextResourceContents(
        uri = "file:///path/to/file.txt",
        text = "content"
    )
)

# Direct result control (v0.2+) - content is Vector{Dict}, not Vector{Content}
CallToolResult(
    content = [Dict("type" => "text", "text" => "result")],  # Pre-serialized
    is_error = false
)
```

### Resource Definition

```julia
Base.@kwdef struct MCPResource <: Resource
    uri::URI                        # URI pattern (uses URI type, not String)
    name::String                    # Human-readable name
    description::String = ""        # Resource description
    mime_type::String = "application/json"  # MIME type of resource content
    data_provider::Function         # Function that provides data (NOT handler)
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}()  # Optional metadata
end

Base.@kwdef struct TextResourceContents <: ResourceContents
    uri::String                     # Actual URI
    text::String                    # Text content
    mime_type::Union{String,Nothing} = nothing  # Optional MIME type
end

Base.@kwdef struct BlobResourceContents <: ResourceContents
    uri::String                     # Actual URI
    blob::Vector{UInt8}            # Binary content
    mime_type::Union{String,Nothing} = nothing  # Optional MIME type
end
```

### Prompt Definition

```julia
Base.@kwdef struct MCPPrompt
    name::String                           # Prompt identifier
    description::String = ""               # Prompt description
    arguments::Vector{PromptArgument} = PromptArgument[]  # Input arguments
    messages::Vector{PromptMessage} = PromptMessage[]     # Static template messages (NO handler)
end

Base.@kwdef struct PromptArgument
    name::String                          # Argument name
    description::String = ""              # Argument description
    required::Bool = false                # Whether required
end

Base.@kwdef struct PromptMessage
    content::Union{TextContent, ImageContent, EmbeddedResource}  # Message content
    role::Role = user                     # Role enum (user or assistant), not String
end
```

## Core Functions

### Server Creation

```julia
# Basic server creation
server = mcp_server(name = "my-server")

# Server with auto-registration 
server = mcp_server(
    name = "auto-server",
    description = "Server with auto-discovered components",
    auto_register_dir = "mcp_components"
)

# Server with explicit components
server = mcp_server(
    name = "explicit-server", 
    tools = [tool1, tool2],
    resources = [resource1],
    prompts = [prompt1]
)

# Start the server (default: STDIO transport)
start!(server)

# Or with HTTP transport
start!(server; transport = HttpTransport(; port = 3000))
```

### Component Registration

```julia
# Manual registration
register!(server, my_tool)
register!(server, my_resource)
register!(server, my_prompt)

# Batch registration
tools = [tool1, tool2, tool3]
foreach(t -> register!(server, t), tools)
```

### Content Creation

```julia
# Text content
text = TextContent(text = "Hello, world!")

# Image content (raw bytes - base64 encoding happens automatically during JSON serialization)
image = ImageContent(
    data = image_bytes,  # Vector{UInt8} - raw binary data, NOT base64 string
    mime_type = "image/png"
)

# Multi-content response
results = [
    TextContent(text = "Analysis complete"),
    ImageContent(data = chart_data, mime_type = "image/png"),
    TextContent(text = "See chart above for details")
]
```

## Transport Options

ModelContextProtocol.jl abstracts the communication layer through transports. By default, servers use STDIO (standard input/output) for communication, which works perfectly for local integrations like Claude Desktop. However, the package also provides HTTP transport for scenarios requiring network access or multiple concurrent clients.

### Why Different Transports?

The transport layer determines how your MCP server communicates with clients:

- **STDIO Transport**: Direct process communication via stdin/stdout. Simple, secure, and ideal for local tools
- **HTTP Transport**: Network-based communication with support for multiple clients and Server-Sent Events (SSE) for real-time updates

### Using HTTP Transport

```julia
# Default STDIO server
server = mcp_server(name = "my-server")
start!(server)  # Blocks on stdin

# HTTP server on port 3000
server = mcp_server(name = "my-http-server")
start!(server; transport = HttpTransport(; port = 3000))

# HTTP with specific host (important for Windows)
start!(server; transport = HttpTransport(;
    host = "127.0.0.1",  # Use IP instead of localhost on Windows
    port = 3000,
    endpoint = "/"  # Default endpoint
))
```

### How HTTP Transport Works

The HTTP transport implements the MCP protocol over HTTP with two key mechanisms:

1. **Request/Response**: POST requests with JSON-RPC payloads for tool calls, resource access, etc.
2. **Server-Sent Events**: GET requests with `Accept: text/event-stream` for server-initiated notifications

This dual approach enables both traditional request/response patterns and real-time updates without polling.

**Important**: ModelContextProtocol.jl currently supports HTTP only, not HTTPS. For production use with internet-facing deployments, you'll need either:
- **mcp-remote**: A proxy adapter that provides HTTPS and OAuth support
- **Reverse proxy**: nginx, Apache, or similar to handle TLS termination

### Connecting to HTTP Servers

Once your HTTP server is running, clients have several connection options:

```julia
# 1. Direct HTTP requests (for testing)
# curl -X POST http://127.0.0.1:3000/ \
#   -H "Content-Type: application/json" \
#   -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'

# 2. Via mcp-remote bridge (for Claude Desktop and secure connections)
# The --allow-http flag is required since we're using HTTP, not HTTPS
# In your Claude Desktop config:
{
  "mcpServers": {
    "my-http-server": {
      "command": "npx",
      "args": ["mcp-remote", "http://127.0.0.1:3000", "--allow-http"]
    }
  }
}

# 3. MCP Inspector for debugging
# npx @modelcontextprotocol/inspector stdio -- \
#   npx mcp-remote http://127.0.0.1:3000 --allow-http
```

### Real-time Updates with SSE

HTTP transport automatically handles Server-Sent Events for features like:
- Progress notifications during long-running operations
- Resource subscription updates
- Server-initiated messages

The server manages SSE streams internally - tools and resources work identically regardless of transport.

### Transport Selection Guide

Use STDIO when:
- Building tools for local use (Claude Desktop, VS Code)
- Security is paramount (no network exposure)
- Single client access is sufficient

Use HTTP when:
- Server runs on a different machine than the client
- Multiple clients need concurrent access
- Building web-based integrations
- Debugging with standard HTTP tools

The transport abstraction ensures your tools, resources, and prompts work identically with either transport - only the server startup changes.

## Tool Creation Patterns

### Simple Text Tool

```julia
echo_tool = MCPTool(
    name = "echo",
    description = "Echo the input message",
    parameters = [
        ToolParameter(name = "message", description = "Message to echo back", type = "string", required = true)
    ],
    handler = (params) -> TextContent(text = params["message"])
)
```

### Tool with Default Parameters

```julia
format_tool = MCPTool(
    name = "format_json",
    description = "Format JSON with configurable options",
    parameters = [
        ToolParameter(name = "json_string", description = "JSON string to format", type = "string", required = true),
        ToolParameter(name = "indent", description = "Number of spaces for indentation", type = "number", default = 2),
        ToolParameter(name = "sort_keys", description = "Whether to sort object keys", type = "boolean", default = false)
    ],
    handler = function(params)
        data = JSON3.read(params["json_string"])
        indent = Int(params["indent"])
        sort_keys = params["sort_keys"]
        
        formatted = JSON3.pretty(data, indent = indent, sort_keys = sort_keys)
        return TextContent(text = formatted)
    end
)
```

### Multi-Content Tool

```julia
analyze_tool = MCPTool(
    name = "analyze_data", 
    description = "Analyze data and return text + visualization",
    parameters = [
        ToolParameter(name = "data", description = "JSON data to analyze", type = "string", required = true)
    ],
    handler = function(params)
        # Process data
        data = JSON3.read(params["data"])
        
        # Create summary
        summary = TextContent(
            text = "Data contains $(length(data)) items with keys: $(join(keys(first(data)), ", "))"
        )
        
        # Create visualization (mock chart)
        chart = ImageContent(
            data = generate_chart_bytes(data),  # Your chart generation function returns Vector{UInt8}
            mime_type = "image/png"
        )
        
        return [summary, chart]  # Return multiple content items
    end,
    return_type = Vector{Content}
)
```

### Error-Handling Tool

```julia
file_reader = MCPTool(
    name = "read_file",
    description = "Read file with comprehensive error handling",
    parameters = [
        ToolParameter(name = "path", description = "File path to read", type = "string", required = true)
    ],
    handler = function(params)
        path = params["path"]
        
        # Validate file exists
        if !isfile(path)
            return CallToolResult(
                content = [TextContent(text = "Error: File not found at path '$path'")],
                is_error = true
            )
        end
        
        # Check file permissions
        if !isreadable(path) 
            return CallToolResult(
                content = [TextContent(text = "Error: File '$path' is not readable")],
                is_error = true
            )
        end
        
        try
            content = read(path, String)
            file_size = filesize(path)
            
            return [
                TextContent(text = "Successfully read file: $path"),
                TextContent(text = "File size: $file_size bytes"),
                TextContent(text = "Content:\n$content")
            ]
        catch e
            return CallToolResult(
                content = [TextContent(text = "Error reading file: $(string(e))")],
                is_error = true
            )
        end
    end,
    return_type = Union{Vector{Content}, CallToolResult}
)
```

## Complete Workflow Examples

### 1. Creating a File Management Server

**Project Structure**:
```
file_server/
├── main.jl
└── mcp_components/
    ├── tools/
    │   ├── file_operations.jl
    │   └── directory_scanner.jl
    └── resources/
        └── file_system.jl
```

**`tools/file_operations.jl`**:
```julia
using Base64

read_file = MCPTool(
    name = "read_file",
    description = "Read file contents",
    parameters = [
        ToolParameter(name = "path", description = "File path to read", type = "string", required = true),
        ToolParameter(name = "max_size", type = "number", default = 1048576)  # 1MB default
    ],
    handler = function(params)
        path = params["path"]
        max_size = Int(params["max_size"])
        
        if !isfile(path)
            return TextContent(text = "File not found: $path")
        end
        
        size = filesize(path)
        if size > max_size
            return TextContent(text = "File too large: $(size) bytes (max: $(max_size))")
        end
        
        content = read(path, String)
        return TextContent(text = "File: $path\n\n$content")
    end
)

write_file = MCPTool(
    name = "write_file",
    description = "Write content to file",
    parameters = [
        ToolParameter(name = "path", description = "File path to read", type = "string", required = true),
        ToolParameter(name = "content", type = "string", required = true),
        ToolParameter(name = "append", type = "boolean", default = false)
    ],
    handler = function(params)
        path = params["path"]
        content = params["content"]
        append_mode = params["append"]
        
        try
            if append_mode
                open(path, "a") do file
                    write(file, content)
                end
            else
                write(path, content)
            end
            
            return TextContent(text = "Successfully wrote to $path")
        catch e
            return CallToolResult(
                content = [TextContent(text = "Failed to write file: $(string(e))")],
                is_error = true
            )
        end
    end
)
```

**`tools/directory_scanner.jl`**:
```julia
list_directory = MCPTool(
    name = "list_directory",
    description = "List directory contents with file information",
    parameters = [
        ToolParameter(name = "path", description = "File path to read", type = "string", required = true),
        ToolParameter(name = "recursive", type = "boolean", default = false),
        ToolParameter(name = "show_hidden", type = "boolean", default = false)
    ],
    handler = function(params)
        path = params["path"]
        recursive = params["recursive"]
        show_hidden = params["show_hidden"]
        
        if !isdir(path)
            return TextContent(text = "Directory not found: $path")
        end
        
        files = []
        if recursive
            for (root, dirs, filenames) in walkdir(path)
                for filename in filenames
                    if show_hidden || !startswith(filename, ".")
                        full_path = joinpath(root, filename)
                        size = filesize(full_path)
                        modified = Dates.format(Dates.unix2datetime(mtime(full_path)), "yyyy-mm-dd HH:MM:SS")
                        push!(files, "$full_path ($size bytes, modified: $modified)")
                    end
                end
            end
        else
            for item in readdir(path, join=true)
                if show_hidden || !startswith(basename(item), ".")
                    if isfile(item)
                        size = filesize(item)
                        modified = Dates.format(Dates.unix2datetime(mtime(item)), "yyyy-mm-dd HH:MM:SS")
                        push!(files, "$(basename(item)) ($size bytes, modified: $modified)")
                    else
                        push!(files, "$(basename(item))/ (directory)")
                    end
                end
            end
        end
        
        result = "Directory listing for $path:\n" * join(files, "\n")
        return TextContent(text = result)
    end
)
```

**`resources/file_system.jl`**:
```julia
file_system = MCPResource(
    uri = "file://*",
    name = "File System Access",
    description = "Direct access to local file system",
    mime_type = "application/octet-stream",
    data_provider = function(uri::String)
        # Remove file:// prefix
        local_path = replace(uri, "file://" => "")
        
        if isfile(local_path)
            # Detect MIME type based on extension
            ext = lowercase(splitext(local_path)[2])
            mime_type = if ext in [".txt", ".md", ".json", ".xml", ".csv"]
                "text/plain"
            elseif ext in [".html", ".htm"] 
                "text/html"
            elseif ext in [".js"]
                "application/javascript"
            elseif ext in [".css"]
                "text/css"
            else
                "application/octet-stream"
            end
            
            if startswith(mime_type, "text/")
                content = read(local_path, String)
                return TextResourceContents(
                    uri = uri,
                    mime_type = mime_type,
                    text = content
                )
            else
                content = read(local_path)
                return BlobResourceContents(
                    uri = uri,
                    mime_type = mime_type,
                    blob = content
                )
            end
        else
            error("File not found: $local_path")
        end
    end
)
```

**`main.jl`**:
```julia
#!/usr/bin/env julia

using Pkg
Pkg.activate(@__DIR__)

using ModelContextProtocol

# Create server with auto-registration
server = mcp_server(
    name = "file-management-server",
    version = "2024-11-05",
    description = "Comprehensive file management MCP server",
    auto_register_dir = "mcp_components"
)

println("Starting File Management MCP Server...")
println("Available tools will be auto-discovered from mcp_components/")
start!(server)
```

### 2. Creating a Data Analysis Server

**Project Structure**: 
```
data_server/
├── main.jl
├── data/
│   ├── sample.csv
│   └── config.json
└── mcp_components/
    ├── tools/
    │   ├── data_loader.jl
    │   ├── statistics.jl
    │   └── visualization.jl
    └── resources/
        └── datasets.jl
```

**`tools/data_loader.jl`**:
```julia
using CSV, DataFrames, JSON3

load_csv = MCPTool(
    name = "load_csv",
    description = "Load and preview CSV data",
    parameters = [
        ToolParameter(name = "file_path", type = "string", required = true),
        ToolParameter(name = "delimiter", type = "string", default = ","),
        ToolParameter(name = "preview_rows", type = "number", default = 5)
    ],
    handler = function(params)
        file_path = params["file_path"]
        delimiter = params["delimiter"][1]  # Convert to char
        preview_rows = Int(params["preview_rows"])
        
        try
            df = CSV.read(file_path, DataFrame, delim = delimiter)
            total_rows, total_cols = size(df)
            
            # Create summary
            summary_text = """
            Dataset loaded successfully!
            - File: $file_path
            - Dimensions: $total_rows rows × $total_cols columns
            - Columns: $(join(names(df), ", "))
            """
            
            # Create preview
            preview_df = first(df, preview_rows)
            preview_text = sprint(show, preview_df, context = :limit => true)
            
            return [
                TextContent(text = summary_text),
                TextContent(text = "Preview (first $preview_rows rows):\n$preview_text")
            ]
        catch e
            return CallToolResult(
                content = [TextContent(text = "Error loading CSV: $(string(e))")],
                is_error = true
            )
        end
    end,
    return_type = Vector{Content}
)
```

### 3. Running the Servers

To run any of these servers:

```bash
# Navigate to the project directory
cd file_server/  # or data_server/

# Run the server
julia main.jl

# The server will start and listen on STDIO
# Connect from Claude Desktop or other MCP clients
```

## Important Architecture Patterns

### 1. **Stateless Handlers** 
Handlers should be pure functions without side effects in server state:

```julia
# Good: External state management
const cache = Dict{String, Any}()

cached_tool = MCPTool(
    name = "cached_compute",
    handler = function(params)
        key = params["key"]
        if haskey(cache, key)
            return TextContent(text = "Cached: $(cache[key])")
        end
        result = expensive_computation(params)
        cache[key] = result
        return TextContent(text = "Computed: $result")
    end
)
```

### 2. **Content Serialization**
The package automatically serializes content via `content2dict` (src/utils/serialization.jl):

```julia
# Automatic serialization
TextContent(text = "Hello") 
# → {"type": "text", "text": "Hello"}

ImageContent(data = base64_data, mime_type = "image/png")
# → {"type": "image", "data": "...", "mimeType": "image/png"}

[TextContent(text = "Part 1"), TextContent(text = "Part 2")]
# → [{"type": "text", "text": "Part 1"}, {"type": "text", "text": "Part 2"}]
```

### 3. **Error Handling Strategies**

```julia
# Strategy 1: Exception handling (automatic error response)
error_tool1 = MCPTool(
    handler = function(params)
        if invalid_input(params)
            error("Invalid input provided")  # Becomes MCP error response
        end
        return TextContent(text = "Success")
    end
)

# Strategy 2: Explicit error control
error_tool2 = MCPTool(
    handler = function(params)
        if invalid_input(params)
            return CallToolResult(
                content = [TextContent(text = "Validation failed")],
                is_error = true
            )
        end
        return TextContent(text = "Success")
    end
)
```

### 4. **Performance Considerations**

- **LittleDict Usage**: Package uses `LittleDict` for small dictionaries (< 10 items) for better performance
- **Lazy Resource Loading**: Resources are loaded on-demand via handlers
- **Content Chunking**: For large content, consider splitting into multiple content items

### 5. **Protocol Compliance**

ModelContextProtocol.jl ensures MCP compliance automatically:

- Tools are not included in initialization response (only capability indication)
- Clients must call `tools/list` to discover actual tools
- Proper JSON-RPC message formatting
- Automatic parameter validation and default application
- Correct error response formatting

This architecture enables ModelContextProtocol.jl to provide an intuitive, powerful API while maintaining full MCP specification compliance and excellent performance characteristics.
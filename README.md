# ModelContextProtocol.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaSMLM.github.io/ModelContextProtocol.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaSMLM.github.io/ModelContextProtocol.jl/dev/)
[![Build Status](https://github.com/JuliaSMLM/ModelContextProtocol.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JuliaSMLM/ModelContextProtocol.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/JuliaSMLM/ModelContextProtocol.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaSMLM/ModelContextProtocol.jl)

A Julia implementation of the [Model Context Protocol](https://modelcontextprotocol.io) (MCP), enabling seamless integration between Julia applications and Large Language Models like Claude Desktop through standardized tools, resources, and prompts.

## Features

✅ **Core MCP 2025-06-18 Protocol** - Server-side implementation with tools, resources, and prompts  
✅ **Multiple Transports** - stdio (default) and HTTP with Server-Sent Events  
✅ **Multi-Content Responses** - Tools can return text, images, and embedded resources  
✅ **Auto-Registration** - Automatic component discovery from directory structure  
✅ **Type-Safe** - Leverages Julia's type system for robust implementations  
✅ **Session Management** - Secure session handling for HTTP transport  

**Note:** This is a server-side implementation. Client features (roots, sampling), OAuth, and some optional features (elicitation, audio content) are not yet implemented.  

## Quick Example

```julia
using ModelContextProtocol

# Create a simple tool
hello_tool = MCPTool(
    name = "say_hello",
    description = "Greet someone",
    parameters = [
        ToolParameter(name = "name", type = "string", description = "Name to greet")
    ],
    handler = (params) -> TextContent(text = "Hello, $(params["name"])!")
)

# Create and start server
server = mcp_server(
    name = "hello-server",
    version = "1.0.0",
    tools = hello_tool
)

start!(server)  # Uses stdio transport by default
```

## Requirements

- Julia 1.9 or higher
- No external dependencies for basic usage
- Optional: HTTP.jl for HTTP transport

## Installation

```julia
using Pkg
Pkg.add("ModelContextProtocol")
```

## Core Components

### Tools
`MCPTool` - Functions that LLMs can call to perform actions or retrieve information
```julia
tool = MCPTool(
    name = "get_data",
    description = "Fetch data from source",
    parameters = [...],
    handler = (params) -> TextContent(text = "result")
)
```

### Resources  
`MCPResource` - Data sources that LLMs can read
```julia
resource = MCPResource(
    uri = "file://data.json",
    name = "Dataset",
    mime_type = "application/json",
    data_provider = () -> read("data.json", String)
)
```

### Prompts
`MCPPrompt` - Reusable prompt templates with variables
```julia
prompt = MCPPrompt(
    name = "analyze",
    description = "Analysis prompt template",
    arguments = [PromptArgument(name = "topic", required = true)],
    messages = [PromptMessage(content = TextContent(text = "Analyze {topic}"))]
)
```

## Transport Options

### stdio Transport (Default)
Simple communication via standard input/output - perfect for Claude Desktop integration:
```julia
server = mcp_server(name = "my-server", tools = [my_tool])
start!(server)  # Automatically uses stdio
```

### HTTP Transport  
Web-based transport with Server-Sent Events for real-time updates:
```julia
transport = HttpTransport(host = "127.0.0.1", port = 3000)
connect(transport)  # Must connect before starting
start!(server, transport)
```

**Note:** On Windows, always use `127.0.0.1` instead of `localhost` for HTTP transport.

## Complete Example

```julia
using ModelContextProtocol
using Dates

# Create a tool that returns formatted time
time_tool = MCPTool(
    name = "get_time",
    description = "Get current time in specified format",
    parameters = [
        ToolParameter(
            name = "format",
            type = "string",
            description = "DateTime format (e.g., 'HH:MM:SS')",
            required = false,
            default = "HH:MM:SS"
        )
    ],
    handler = function(params)
        fmt = get(params, "format", "HH:MM:SS")
        TextContent(text = Dates.format(now(), fmt))
    end
)

# Create a resource that provides system info
info_resource = MCPResource(
    uri = "system://info",
    name = "System Information",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "julia_version" => string(VERSION),
        "os" => Sys.KERNEL,
        "cpu_threads" => Sys.CPU_THREADS
    )
)

# Create and start server
server = mcp_server(
    name = "demo-server",
    version = "1.0.0",
    tools = time_tool,
    resources = info_resource
)

start!(server)
```

## Auto-Registration

Organize components in directories for automatic discovery:

```
my_server/
├── tools/
│   ├── calculator.jl
│   └── file_ops.jl
├── resources/
│   └── data.jl
└── prompts/
    └── templates.jl
```

```julia
# Auto-register all components from directory
server = mcp_server(
    name = "my-server",
    version = "1.0.0",
    auto_register_dir = "my_server"
)
start!(server)
```

Each `.jl` file should define component instances. ModelContextProtocol is automatically available:

```julia
# tools/calculator.jl
calculator = MCPTool(
    name = "calc",
    description = "Calculate expressions",
    parameters = [
        ToolParameter(name = "expr", type = "string", description = "Expression")
    ],
    handler = (p) -> TextContent(text = string(eval(Meta.parse(p["expr"]))))
)
```

## Claude Desktop Integration

1. **Configure Claude Desktop** (Settings → Developer → Edit Config):
```json
{
  "mcpServers": {
    "julia-server": {
      "command": "julia",
      "args": ["--project=/path/to/project", "server.jl"]
    }
  }
}
```

2. **Restart Claude Desktop** to load the configuration

3. **Use your server** - Claude will automatically connect and discover available tools

For HTTP servers, use the MCP Remote bridge:
```json
{
  "mcpServers": {
    "julia-http": {
      "command": "npx",
      "args": ["mcp-remote", "http://127.0.0.1:3000", "--allow-http"]
    }
  }
}
```

## Documentation

- **[API Reference](api.md)** - Complete API documentation with examples
- **[Official Docs](https://JuliaSMLM.github.io/ModelContextProtocol.jl/stable/)** - Full documentation
- **[MCP Specification](https://modelcontextprotocol.io)** - Protocol specification

## What's Included

- **Server Implementation** - Complete MCP server with tools, resources, and prompts
- **Multi-Content Responses** - Return text, images, and resources from a single tool
- **Parameter Defaults** - Optional parameters with default values  
- **Session Management** - Secure HTTP sessions with automatic ID generation
- **Error Handling** - Built-in error types and CallToolResult for explicit control
- **Resource Templates** - Dynamic resource URIs with placeholders

## Not Yet Implemented

- **Client Features** - Roots, sampling, completion (this is server-only)
- **OAuth/Authentication** - Beyond basic session management
- **Elicitation** - Server-to-client interaction requests
- **Audio Content** - AudioContent type
- **Progress Notifications** - Bidirectional progress updates (infrastructure exists but limited)

## License

This project is licensed under the MIT License - see the LICENSE file for details.
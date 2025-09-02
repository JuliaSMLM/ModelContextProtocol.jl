# ModelContextProtocol.jl

ModelContextProtocol.jl is a Julia implementation of the [Model Context Protocol (MCP)](https://github.com/modelcontextprotocol), enabling integration with Large Language Models (LLMs) like Anthropic's Claude.

## Overview

The Model Context Protocol provides a standardized way for applications to offer context and capabilities to LLMs. This package implements the full MCP specification, with `mcp_server()` as the main entry point.

## Installation

```julia
using Pkg
Pkg.add("ModelContextProtocol")
```

## Key Components

The package provides three main types that can be registered with an MCP server:

- **Tools**: Callable functions that LLMs can use
- **Resources**: Data sources that LLMs can read
- **Prompts**: Template-based messages

## Quick Start

### Direct Component Registration

The simplest way to create an MCP server is to directly register components:

```julia
using ModelContextProtocol
using JSON3, Dates

# Create a simple tool that returns the current time
time_tool = MCPTool(
    name = "get_time",
    description = "Get current time in specified format",
    parameters = [
        ToolParameter(
            name = "format",
            type = "string",
            description = "DateTime format string",
            required = true
        )
    ],
    handler = params -> TextContent(
        text = JSON3.write(Dict("time" => Dates.format(now(), params["format"])))
    )
)

# Create and start server
server = mcp_server(
    name = "time-server",
    description = "Simple MCP server with time tool",
    tools = time_tool
)

start!(server)  # Default: STDIO transport
```

This example:
1. Creates a tool that returns the current time in a specified format
2. Registers this tool with a new MCP server
3. Starts the server process, listening for incoming connections via STDIO

When Claude connects to this server, it can discover and use the `get_time` tool to provide formatted time information.

#### Using HTTP Transport

For network-based or multi-client scenarios:

```julia
# Start server with HTTP transport
start!(server; transport = HttpTransport(; port = 3000))
```

See the [API documentation](api.md#transport-options) for more transport options.

### Directory-Based Organization

For larger projects, you can organize components in a directory structure:

```
my_mcp_project/
├── tools/
│   ├── time_tool.jl
│   └── calculator_tool.jl
├── resources/
│   └── weather_data.jl
└── prompts/
    └── greeting.jl
```

Each file exports one or more components:

```julia
# tools/time_tool.jl
using ModelContextProtocol
using JSON3, Dates

time_tool = MCPTool(
    name = "get_time",
    description = "Get current time in specified format",
    parameters = [
        ToolParameter(name = "format", type = "string", required = true)
    ],
    handler = params -> TextContent(
        text = JSON3.write(Dict("time" => Dates.format(now(), params["format"])))
    )
)
```

Then auto-register all components at once:

```julia
using ModelContextProtocol

server = mcp_server(
    name = "full-server",
    description = "MCP server with auto-registered components",
    auto_register_dir = "my_mcp_project"  # Directory to scan for components
)

start!(server)  # Or with HTTP: start!(server; transport = HttpTransport(; port = 3000))
```

The directory approach offers several advantages:
- Better organization for complex servers
- Separation of concerns for different components
- Ability to add/modify components without changing server code

See the [Tools](tools.md), [Resources](resources.md), and [Prompts](prompts.md) sections for more details.
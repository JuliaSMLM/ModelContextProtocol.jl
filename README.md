# ModelContextProtocol.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaSMLM.github.io/ModelContextProtocol.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaSMLM.github.io/ModelContextProtocol.jl/dev/)
[![Build Status](https://github.com/JuliaSMLM/ModelContextProtocol.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JuliaSMLM/ModelContextProtocol.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/JuliaSMLM/ModelContextProtocol.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaSMLM/ModelContextProtocol.jl)

A Julia implementation of the [Model Context Protocol](https://github.com/modelcontextprotocol) (MCP), enabling integration with Large Language Models (LLMs) like Anthropic's Claude by providing standardized access to tools, resources, and prompts.

## Overview

The Model Context Protocol allows applications to provide context and capabilities to LLMs in a standardized way. This package implements the full MCP specification in Julia, with `mcp_server()` as the main entry point for creating and configuring servers.

The `mcp_server()` function provides a flexible interface to:
- Create MCP servers with custom names and configurations
- Register tools, resources, and prompts manually or automatically
- Configure server capabilities and behavior
- Set up directory-based component organization

Example:
```julia
server = mcp_server(
    name = "my-server",
    version = "2024-11-05",
    tools = my_tool,              # Single tool or vector of tools
    resources = my_resource,      # Single resource or vector of resources
    prompts = my_prompt,          # Single prompt or vector of prompts
    description = "Server description",
    auto_register_dir = "path/to/components"  # Optional auto-registration
)
```

The package enables you to:
- Create MCP servers that expose tools, resources, and prompts
- Define custom tools that LLMs can interact with
- Organize and auto-register components from directory structures
- Handle all MCP protocol messages and lifecycle events

## Core Components

The package provides three main types that can be registered with an MCP server:

1. `MCPTool`: Represents callable functions that LLMs can use
   - Has a name, description, parameters, and handler function
   - LLMs can invoke tools to perform actions or computations

2. `MCPResource`: Represents data sources that LLMs can read
   - Has a URI, name, MIME type, and data provider function
   - Provides static or dynamic data access to LLMs

3. `MCPPrompt`: Represents template-based prompts
   - Has a name, description, and parameterized message templates
   - Helps standardize interactions with LLMs

## Quick Start

### Installation

```julia
using Pkg
Pkg.add("ModelContextProtocol")
```

### Basic Example: Manual Tool Setup

Here's a minimal example creating an MCP server with a single tool:

```julia
using ModelContextProtocol
using JSON3
using Dates

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
        text = JSON3.write(Dict(
            "time" => Dates.format(now(), params["format"])
        ))
    )
)

# Create and start server with the tool
server = mcp_server(
    name = "time-server",
    description = "Simple MCP server with time tool",
    tools = time_tool
)

# Start the server
start!(server)
```

When Claude connects to this server, it will discover the `get_time` tool and be able to use it to provide formatted time information to users.

### Directory-Based Organization

You can also organize your MCP components in a directory structure and auto-register them:

```
my_mcp_server/
├── tools/
│   ├── time_tool.jl
│   └── math_tool.jl
├── resources/
│   └── data_source.jl
└── prompts/
    └── templates.jl
```

```julia
using ModelContextProtocol

# Create and start server with all components
server = mcp_server(
    name = "full-server",
    description = "MCP server with auto-registered components",
    auto_register_dir = "my_mcp_server"
)

start!(server)
```

The package will automatically scan the directory structure and register all components:
- `tools/`: Contains tool definitions (MCPTool instances)
- `resources/`: Contains resource definitions (MCPResource instances)
- `prompts/`: Contains prompt definitions (MCPPrompt instances)

Each component file should export one or more instances of the appropriate type. They will be automatically discovered and registered with the server.

## Using with Claude

To use your MCP server with Claude, you need to:

1. Configure Claude Desktop:
   - Go to File → Settings → Developer
   - Click the Edit Config button
   - Add to the configuration:
   ```json
   {
     "mcpServers": {
       "my-server": {
         "command": "julia",
         "args": ["--project=/path/to/project", "server_script.jl"]
       }
     }
   }
   ```

2. Restart the Claude Desktop application to apply changes

3. Start a conversation with Claude and tell it to use your server:
   ```
   Please connect to the MCP server named "my-server" and list its available tools.
   ```

4. Claude will connect to your server and can then:
   - List available tools using the server's capabilities
   - Call tools with appropriate parameters
   - Access resources and prompts
   - Report results back to you

See our [documentation](https://JuliaSMLM.github.io/ModelContextProtocol.jl/stable/) for more details on integration with Claude.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
# ModelContextProtocol.jl

Julia implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io), enabling seamless integration between AI applications and external data sources, tools, and services.

## Features

- ✅ **Core MCP 2025-06-18 Protocol** - Server-side implementation with tools, resources, and prompts
- ✅ **Multiple Transports** - stdio (default) and HTTP with Server-Sent Events
- ✅ **Multi-Content Responses** - Tools can return text, images, and embedded resources
- ✅ **Auto-Registration** - Automatic component discovery from directory structure
- ✅ **Type-Safe** - Leverages Julia's type system for robust implementations
- ✅ **Session Management** - Secure session handling for HTTP transport

**Note:** This is a server-side implementation. Client features (roots, sampling), OAuth, and some optional features (elicitation, audio content) are not yet implemented.

## Installation

```julia
using Pkg
Pkg.add("ModelContextProtocol")
```

## Quick Start

Create a simple MCP server with a tool:

```julia
using ModelContextProtocol

# Create a server with a simple echo tool
server = mcp_server(
    name = "echo-server",
    version = "1.0.0",
    tools = [
        MCPTool(
            name = "echo",
            description = "Echo back the input message",
            parameters = [
                ToolParameter(
                    name = "message",
                    type = "string",
                    description = "Message to echo",
                    required = true
                )
            ],
            handler = (params) -> TextContent(text = params["message"])
        )
    ]
)

# Start the server (stdio transport by default)
start!(server)
```

### Using HTTP Transport

For web-based integrations, use the HTTP transport:

```julia
# Create server with HTTP transport
server = mcp_server(
    name = "http-server",
    version = "1.0.0",
    tools = [...],  # Your tools here
    transport = HttpTransport(host = "127.0.0.1", port = 3000)
)

start!(server)

# Test with curl
# curl -X POST http://127.0.0.1:3000/ \
#   -H "Content-Type: application/json" \
#   -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}'
```

## Documentation Structure

- **[Examples](examples.md)** - Complete working examples and common patterns
- **[Tools](tools.md)** - Creating and using MCP tools
- **[Resources](resources.md)** - Managing data sources and subscriptions
- **[Prompts](prompts.md)** - Defining prompt templates for LLMs
- **[Transports](transports.md)** - Transport options and configuration
- **[Auto-Registration](auto-registration.md)** - Directory-based component organization
- **[Claude Desktop Integration](claude.md)** - Integration with Claude Desktop
- **[API Reference](api.md)** - Complete API documentation

## Protocol Compliance

ModelContextProtocol.jl implements the MCP specification version `2025-06-18`, including:

- JSON-RPC 2.0 message protocol
- Tool discovery and invocation
- Resource management with subscriptions
- Prompt templates with arguments
- Session management for HTTP transport
- Content negotiation and multi-format responses

## Basic Concepts

### Tools

Tools are functions that can be invoked by the LLM:

```julia
tool = MCPTool(
    name = "calculate",
    description = "Perform basic arithmetic",
    parameters = [
        ToolParameter(name = "a", type = "number", required = true),
        ToolParameter(name = "b", type = "number", required = true),
        ToolParameter(name = "op", type = "string", required = true)
    ],
    handler = function(params)
        a, b = params["a"], params["b"]
        result = if params["op"] == "+"
            a + b
        elseif params["op"] == "-"
            a - b
        elseif params["op"] == "*"
            a * b
        elseif params["op"] == "/"
            a / b
        else
            error("Unknown operation")
        end
        return TextContent(text = string(result))
    end
)
```

### Resources

Resources provide data access to the LLM:

```julia
resource = MCPResource(
    uri = "file:///data/config.json",
    name = "Application Config",
    description = "Current application configuration",
    mime_type = "application/json",
    handler = function(uri)
        config_data = read("config.json", String)
        return TextResourceContents(
            uri = uri,
            text = config_data,
            mime_type = "application/json"
        )
    end
)
```

### Prompts

Prompts are templates for generating conversations:

```julia
prompt = MCPPrompt(
    name = "code_review",
    description = "Request a code review",
    arguments = [
        PromptArgument(
            name = "language",
            description = "Programming language",
            required = true
        )
    ],
    handler = function(args)
        return [
            PromptMessage(
                role = user,
                content = TextContent(
                    text = "Please review this $(args["language"]) code for best practices."
                )
            )
        ]
    end
)
```

## Testing Your Server

### With MCP Inspector

Test your server using the official MCP Inspector:

```bash
# For stdio transport
npx @modelcontextprotocol/inspector stdio -- julia --project server.jl

# For HTTP transport
npx @modelcontextprotocol/inspector http://127.0.0.1:3000/
```

### With curl (HTTP only)

```bash
# Initialize connection
curl -X POST http://127.0.0.1:3000/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

# List available tools
curl -X POST http://127.0.0.1:3000/ \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id-from-init>" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}'
```

## Next Steps

- Explore the [Examples](examples.md) for complete working implementations
- Read the [User Guide](tools.md) to understand each component type
- Check the [API Reference](api.md) for detailed function documentation
- Set up [Claude Desktop Integration](claude.md) for real-world usage

## Contributing

ModelContextProtocol.jl is part of the [JuliaSMLM](https://github.com/JuliaSMLM) organization. Contributions are welcome! Please see our [GitHub repository](https://github.com/JuliaSMLM/ModelContextProtocol.jl) for issues and pull requests.

## License

This project is licensed under the MIT License.
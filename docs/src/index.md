# ModelContextProtocol.jl

Julia implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io), enabling seamless integration between AI applications and external data sources, tools, and services.

## Features

- ✅ **MCP 2025-11-25 Protocol** - server-side implementation with version negotiation back to `2024-11-05`
- ✅ **Multiple Transports** - stdio (default) and Streamable HTTP with Server-Sent Events and session management
- ✅ **All Content Types** - text, images, audio, embedded resources, and `resource_link` references
- ✅ **Structured Tool Output** - `output_schema` declarations with `structuredContent` results
- ✅ **Tool Annotations** - behavioral hints (`readOnlyHint`, `destructiveHint`, …) for client trust decisions
- ✅ **Progress Notifications** - long-running tools report progress through context-aware handlers
- ✅ **Tasks (experimental)** - background tool execution with status polling, blocking
  result retrieval, and cancellation ([SEP-1686](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks))
- ✅ **OAuth Resource Server** - bearer-token validation for HTTP (GitHub tokens, JWT claims, RFC 7662 introspection) with RFC 9728 discovery
- ✅ **Logging Control** - runtime `logging/setLevel` plus opt-in per-request lifecycle logs
- ✅ **Auto-Registration** - automatic component discovery from directory structure
- ✅ **Type-Safe** - leverages Julia's type system for robust implementations

**Note:** This is a server-side implementation. Client features (roots, sampling), elicitation, and the OAuth *Authorization Server* (token issuance) are not yet implemented.

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
# Create server, then attach an HTTP transport
server = mcp_server(
    name = "http-server",
    version = "1.0.0",
    tools = [...]  # Your tools here
)

server.transport = HttpTransport(host = "127.0.0.1", port = 3000)
connect(server.transport)
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

ModelContextProtocol.jl implements the MCP specification version `2025-11-25` and negotiates
with clients speaking `2025-06-18`, `2025-03-26`, or `2024-11-05`. This includes:

- JSON-RPC 2.0 message protocol (batching rejected per spec)
- Tool discovery and invocation, structured output, annotations, `_meta`
- Resource management with subscriptions and `resource_link` references
- Prompt templates with arguments and media content
- Progress notifications (`notifications/progress`) and logging (`logging/setLevel`)
- Session management and OAuth Resource Server authentication for HTTP transport

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
    data_provider = () -> JSON3.read(read("config.json", String), Dict{String,Any})
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
    messages = [
        PromptMessage(
            content = TextContent(
                text = "Please review this {language} code for best practices."
            )
        )
    ]
)
```

Template placeholders like `{language}` are substituted from the arguments supplied in
`prompts/get`.

## Testing Your Server

### With MCP Inspector

Test your server using the official MCP Inspector:

```bash
# For stdio transport (Inspector spawns the server command directly)
npx @modelcontextprotocol/inspector julia --project=. server.jl

# For HTTP transport
npx @modelcontextprotocol/inspector http://127.0.0.1:3000/

# Quick smoke test without the browser UI (CLI mode)
npx @modelcontextprotocol/inspector --cli julia --project=. server.jl --method tools/list
```

### With curl (HTTP only)

```bash
# Initialize connection
curl -X POST http://127.0.0.1:3000/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

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
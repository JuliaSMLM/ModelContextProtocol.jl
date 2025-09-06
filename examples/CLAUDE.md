# Examples Guidelines for examples/

This directory contains user-facing examples demonstrating how to use ModelContextProtocol.jl. These examples serve as both documentation and practical guides for implementing MCP servers.

## Purpose
- Demonstrate MCP server implementations
- Provide practical usage examples for different transports
- Show tool, resource, and prompt registration
- Help users understand MCP capabilities
- Serve as templates for custom servers

## Current Examples

### Core Examples
- `time_server.jl` - Basic stdio server with tools, resources, and prompts
- `simple_http_server.jl` - HTTP transport with session management
- `multi_content_tool.jl` - Demonstrates multi-content returns
- `reg_dir.jl` - Auto-registration from directory structure (stdio)
- `reg_dir_http.jl` - Auto-registration with HTTP transport

### Component Examples (mcp_tools/)
- `tools/` - Example tool implementations
- `resources/` - Example resource handlers
- `prompts/` - Example prompt generators

## Environment Setup

### Examples Environment
- **Examples use the main project environment** (no separate activation needed)
- Run with `julia --project` from the project root
- Import ModelContextProtocol directly

### Running Example Files (For Code Agents/Claude)

Run examples from the project root:
```bash
# Run stdio server
julia --project examples/time_server.jl

# Run HTTP server
julia --project examples/simple_http_server.jl
```

**Important Notes**:
1. Allow 5-10 seconds for Julia JIT compilation on first run
2. HTTP servers bind to specific ports (check for conflicts)
3. Use `127.0.0.1` instead of `localhost` for reliability
4. Always capture stdout to see server messages

## Testing Examples

### Testing stdio Servers
```bash
# Direct JSON-RPC test
echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' | \
  julia --project examples/time_server.jl 2>/dev/null | jq .

# With MCP Inspector CLI
npx @modelcontextprotocol/inspector --cli \
  julia --project=/path/to/ModelContextProtocol examples/time_server.jl \
  --method tools/list
```

### Testing HTTP Servers
```bash
# Start server (in one terminal)
julia --project examples/simple_http_server.jl

# Test with curl (in another terminal)
curl -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18"},"id":1}' | jq .

# With MCP Inspector CLI (via mcp-remote)
npx @modelcontextprotocol/inspector --cli \
  npx mcp-remote http://127.0.0.1:3000 --allow-http \
  --method tools/list
```

## Creating New Example Files

### Basic Server Template
```julia
#!/usr/bin/env julia
# No Pkg.activate needed - examples use main project environment
using ModelContextProtocol

# Create server
server = Server(
    name = "example-server",
    version = "1.0.0"
)

# Add a simple tool
add_tool!(server, MCPTool(
    name = "hello",
    description = "Say hello",
    handler = function(params)
        name = get(params, "name", "World")
        return TextContent(text = "Hello, $name!")
    end,
    parameters = [
        ToolParameter(
            name = "name",
            type = "string",
            description = "Name to greet",
            required = false
        )
    ]
))

# Add a resource
add_resource!(server, MCPResource(
    uri = "example://data",
    name = "Example Data",
    handler = function(uri)
        return TextContent(
            text = "This is example data",
            uri = uri
        )
    end
))

# Start server (stdio by default)
println("Starting example MCP server...")
start!(server)
```

### HTTP Server Template
```julia
#!/usr/bin/env julia
using ModelContextProtocol

# Create HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3000
)

# Create server with HTTP transport
server = Server(
    name = "http-example",
    version = "1.0.0",
    transport = transport
)

# Add components...
# (same as stdio example)

println("Starting HTTP server on http://127.0.0.1:3000")
println("Test with: curl -X POST http://127.0.0.1:3000/ ...")
start!(server)
```

### Auto-Registration Template
```julia
#!/usr/bin/env julia
using ModelContextProtocol

# Create server
server = Server("auto-reg-example", "1.0.0")

# Auto-register from directory
components_dir = joinpath(@__DIR__, "example_components")
register_directory!(server, components_dir)

println("Registered components from: $components_dir")
println("Tools: ", [t.name for t in server.tools])
println("Resources: ", [r.name for r in server.resources])
println("Prompts: ", [p.name for p in server.prompts])

start!(server)
```

## Component File Structure

### Tool Component (mcp_tools/tools/example_tool.jl)
```julia
using ModelContextProtocol

MCPTool(
    name = "example_tool",
    description = "An example tool",
    handler = function(params)
        # Tool logic here
        return TextContent(text = "Tool result")
    end,
    parameters = [
        ToolParameter(
            name = "input",
            type = "string",
            description = "Input parameter"
        )
    ]
)
```

### Resource Component (mcp_tools/resources/example_resource.jl)
```julia
using ModelContextProtocol

MCPResource(
    uri = "example://resource",
    name = "Example Resource",
    mime_type = "text/plain",
    handler = function(uri)
        return TextContent(
            text = "Resource content",
            uri = uri
        )
    end
)
```

### Prompt Component (mcp_tools/prompts/example_prompt.jl)
```julia
using ModelContextProtocol

MCPPrompt(
    name = "example_prompt",
    description = "An example prompt",
    handler = function(params)
        user_input = get(params, "input", "default")
        return PromptMessage(
            role = "user",
            content = TextContent(text = "Prompt with: $user_input")
        )
    end,
    arguments = [
        PromptArgument(
            name = "input",
            description = "User input",
            required = false
        )
    ]
)
```

## Output Conventions

### Output Location
- Examples should not write files unless demonstrating file I/O
- Use `println()` for status messages
- Return results through MCP protocol

### Console Output
Examples should provide clear feedback:
```julia
println("Starting server: $(server.name) v$(server.version)")
println("Transport: $(typeof(server.transport))")
println("Registered $(length(server.tools)) tools")
println("Registered $(length(server.resources)) resources")
println("Registered $(length(server.prompts)) prompts")
```

## Best Practices

1. **Keep Examples Simple**: Focus on demonstrating specific features
2. **Add Comments**: Explain what each section does
3. **Show Best Practices**: Use proper error handling and parameter validation
4. **Test Before Committing**: Ensure examples work with MCP Inspector
5. **Document Requirements**: Note any special setup or dependencies
6. **Use Consistent Style**: Follow project conventions
7. **Provide Test Commands**: Include example curl/Inspector commands in comments

## Testing Checklist

Before adding a new example, verify:
- [ ] Works with direct JSON-RPC testing
- [ ] Works with MCP Inspector CLI
- [ ] Handles errors gracefully
- [ ] Uses protocol version `2025-06-18`
- [ ] Has clear console output
- [ ] Includes helpful comments
- [ ] Follows naming conventions
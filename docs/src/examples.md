# Examples

This page provides comprehensive examples of using ModelContextProtocol.jl to create MCP servers with various features and configurations.

## Basic Usage

### Simple Echo Server

A minimal MCP server with a single tool:

```@example basic
using ModelContextProtocol

# Create a simple echo tool
echo_tool = MCPTool(
    name = "echo",
    description = "Echo back the provided message",
    parameters = [
        ToolParameter(
            name = "message",
            type = "string",
            description = "Message to echo back",
            required = true
        )
    ],
    handler = function(params)
        return TextContent(text = "Echo: $(params["message"])")
    end
)

# Create and configure server
server = mcp_server(
    name = "echo-server",
    version = "1.0.0",
    tools = [echo_tool]
)

# Display server configuration
println("Server created: $(server.config.name) v$(server.config.version)")
println("Available tools: ", [t.name for t in server.tools])
```

### Calculator Server

A server with multiple arithmetic operations:

```@example calculator
using ModelContextProtocol

# Create calculator tool with multiple operations
calc_tool = MCPTool(
    name = "calculate",
    description = "Perform arithmetic calculations",
    parameters = [
        ToolParameter(name = "a", type = "number", description = "First number", required = true),
        ToolParameter(name = "b", type = "number", description = "Second number", required = true),
        ToolParameter(name = "operation", type = "string",
                     description = "Operation: add, subtract, multiply, divide", required = true)
    ],
    handler = function(params)
        a = params["a"]
        b = params["b"]
        op = params["operation"]

        result = if op == "add"
            a + b
        elseif op == "subtract"
            a - b
        elseif op == "multiply"
            a * b
        elseif op == "divide"
            b != 0 ? a / b : "Error: Division by zero"
        else
            "Error: Unknown operation"
        end

        return TextContent(text = "Result: $result")
    end
)

server = mcp_server(
    name = "calculator",
    version = "1.0.0",
    tools = [calc_tool]
)

println("Calculator server configured with tool: $(server.tools[1].name)")
```

## Advanced Examples

### Multi-Content Tool Returns

Tools can return multiple content items of different types:

```@example multicontent
using ModelContextProtocol
using Base64

# Tool that returns multiple content types
analysis_tool = MCPTool(
    name = "analyze_data",
    description = "Analyze data and return multiple results",
    parameters = [
        ToolParameter(name = "data", type = "string", description = "Data to analyze", required = true)
    ],
    handler = function(params)
        data = params["data"]

        # Return multiple content items
        space_char = ' '
        return [
            TextContent(text = "Analysis Summary: Processed $(length(data)) characters"),
            TextContent(text = "Data contains $(count(==(space_char), data)) spaces"),
            # Could also include ImageContent with base64 data
            # ImageContent(data = base64_encoded_image, mime_type = "image/png")
        ]
    end,
    return_type = Vector{Content}  # Explicitly specify multi-content return
)

server = mcp_server(
    name = "analyzer",
    version = "1.0.0",
    tools = [analysis_tool]
)

println("Multi-content tool configured: $(server.tools[1].name)")
```

### Resource Server with Custom Data

Implementing resources with custom data providers:

```@example resources
using ModelContextProtocol
using URIs  # For URI construction

# Create a resource with a custom data provider
config_resource = MCPResource(
    uri = URI("config://app/settings"),
    name = "Application Settings",
    description = "Current application configuration",
    mime_type = "application/json",
    data_provider = function(uri)
        # In real implementation, read from actual config
        config_json = """
        {
            "theme": "dark",
            "language": "en",
            "debug": false
        }
        """
        return TextResourceContents(
            uri = uri,
            text = config_json,
            mime_type = "application/json"
        )
    end,
    annotations = Dict{String,Any}()
)

# Create another resource for file access
file_resource = MCPResource(
    uri = URI("file:///readme.txt"),
    name = "README File",
    description = "Project readme file",
    mime_type = "text/plain",
    data_provider = function(uri)
        # In real implementation, read the actual file
        content = "# Project README\n\nThis is the readme content."
        return TextResourceContents(
            uri = uri,
            text = content,
            mime_type = "text/plain"
        )
    end
)

server = mcp_server(
    name = "resource-server",
    version = "1.0.0",
    resources = [config_resource, file_resource]
)

println("Server configured with $(length(server.resources)) resources")
```

### Prompt Templates Server

Creating reusable prompt templates:

```@example prompts
using ModelContextProtocol

# Import Role enum values
user_role = ModelContextProtocol.user
assistant_role = ModelContextProtocol.assistant

# Function to generate messages for code review
function generate_code_review_messages(args)
    lang = args["language"]
    focus = get(args, "focus", "general quality")
    return [
        PromptMessage(
            role = user_role,
            content = TextContent(
                text = "Please review this $lang code focusing on $focus. " *
                      "Look for bugs, performance issues, and adherence to best practices."
            )
        ),
        PromptMessage(
            role = assistant_role,
            content = TextContent(
                text = "I'll review your $lang code with a focus on $focus. " *
                      "Please share the code you'd like me to examine."
            )
        )
    ]
end

# Create a code review prompt template
code_review_prompt = MCPPrompt(
    name = "code_review",
    description = "Generate a code review request",
    arguments = [
        PromptArgument(name = "language", description = "Programming language", required = true),
        PromptArgument(name = "focus", description = "Review focus area", required = false)
    ],
    messages = generate_code_review_messages(Dict("language" => "Julia", "focus" => "performance"))
)

# Create a data analysis prompt with static messages
analysis_prompt = MCPPrompt(
    name = "data_analysis",
    description = "Request data analysis",
    arguments = [
        PromptArgument(name = "dataset", description = "Dataset description", required = true)
    ],
    messages = [
        PromptMessage(
            role = user_role,
            content = TextContent(
                text = "Analyze the dataset. " *
                      "Provide insights on patterns, anomalies, and recommendations."
            )
        )
    ]
)

server = mcp_server(
    name = "prompt-server",
    version = "1.0.0",
    prompts = [code_review_prompt, analysis_prompt]
)

println("Server configured with prompts: ", [p.name for p in server.prompts])
```

## Transport Configuration

### HTTP Transport with Custom Settings

```@example http
using ModelContextProtocol

# Note: HttpTransport is an internal type not exported
# Use stdio transport (default) or specify transport in mcp_server
# For HTTP servers, the transport is configured internally

# Example server configuration
server = mcp_server(
    name = "http-server",
    version = "1.0.0",
    tools = [
        MCPTool(
            name = "status",
            description = "Get server status",
            parameters = [],
            handler = () -> TextContent(text = "Server is running")
        )
    ]
)

println("Server configured: $(server.config.name)")
```

## Common Patterns

### Error Handling in Tools

Properly handling errors in tool implementations:

```@example errors
using ModelContextProtocol

safe_division_tool = MCPTool(
    name = "safe_divide",
    description = "Divide two numbers with error handling",
    parameters = [
        ToolParameter(name = "dividend", description = "Number to be divided", type = "number", required = true),
        ToolParameter(name = "divisor", description = "Number to divide by", type = "number", required = true)
    ],
    handler = function(params)
        dividend = params["dividend"]
        divisor = params["divisor"]

        # Return error result for invalid input
        if divisor == 0
            return CallToolResult(
                content = [TextContent(text = "Error: Division by zero is not allowed")],
                is_error = true
            )
        end

        result = dividend / divisor
        return TextContent(text = "Result: $result")
    end
)

server = mcp_server(
    name = "safe-calc",
    version = "1.0.0",
    tools = [safe_division_tool]
)

println("Error-handling tool configured: $(server.tools[1].name)")
```

### Directory-Based Auto-Registration

Organizing components in a directory structure:

```@example autoregister
using ModelContextProtocol

# Example directory structure:
# my_server/
# ├── tools/
# │   ├── file_ops.jl    # File operation tools
# │   └── data_proc.jl   # Data processing tools
# ├── resources/
# │   └── configs.jl     # Configuration resources
# └── prompts/
#     └── templates.jl   # Prompt templates

# Each file exports components like:
# file: tools/file_ops.jl
# read_file = MCPTool(name = "read_file", ...)
# write_file = MCPTool(name = "write_file", ...)

# Auto-register all components from directory
server = mcp_server(
    name = "auto-server",
    version = "2.0.0",
    auto_register_dir = "my_server"  # Scans and registers all components
)

# Alternatively, register individual components
server2 = mcp_server(name = "manual-server", version = "1.0.0")
# Use register! with specific components:
# register!(server2, my_tool)  # Register a tool
# register!(server2, my_resource)  # Register a resource
# register!(server2, my_prompt)  # Register a prompt

println("Auto-registration example configured")
```

### Tool with Default Parameters

Using default values for optional parameters:

```@example defaults
using ModelContextProtocol
using Dates

format_date_tool = MCPTool(
    name = "format_date",
    description = "Format the current date/time",
    parameters = [
        ToolParameter(
            name = "format",
            type = "string",
            description = "Date format string",
            required = false,
            default = "yyyy-mm-dd HH:MM:SS"  # Default format
        ),
        ToolParameter(
            name = "timezone",
            type = "string",
            description = "Timezone (not implemented in this example)",
            required = false,
            default = "UTC"
        )
    ],
    handler = function(params)
        format_str = params["format"]  # Will use default if not provided
        current_time = Dates.format(now(), format_str)
        return TextContent(text = "Current time: $current_time")
    end
)

server = mcp_server(
    name = "time-server",
    version = "1.0.0",
    tools = [format_date_tool]
)

println("Tool with defaults configured: $(server.tools[1].name)")
```

## Testing Your Implementation

### Unit Testing Tools

Example of testing tool handlers:

```julia
using ModelContextProtocol
using Test

# Create a test tool
test_tool = MCPTool(
    name = "test_tool",
    description = "Tool for testing",
    parameters = [
        ToolParameter(name = "input", type = "string", required = true)
    ],
    handler = function(params)
        return TextContent(text = "Processed: $(params["input"])")
    end
)

# Test the handler directly
@testset "Tool Handler Tests" begin
    # Test normal operation
    result = test_tool.handler(Dict("input" => "test"))
    @test result isa TextContent
    @test result.text == "Processed: test"

    # Test with different inputs
    result2 = test_tool.handler(Dict("input" => "hello"))
    @test result2.text == "Processed: hello"
end
```

### Integration Testing with curl

Testing HTTP server endpoints:

```bash
# Start your HTTP server first
julia --project server_http.jl &

# Wait for server to start
sleep 5

# Test initialization
curl -X POST http://127.0.0.1:8765/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

# Save session ID from response, then test tool listing
curl -X POST http://127.0.0.1:8765/ \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}'
```

## Best Practices

1. **Always validate input parameters** in tool handlers
2. **Use appropriate content types** for different data formats
3. **Provide clear descriptions** for tools, resources, and prompts
4. **Handle errors gracefully** with CallToolResult when needed
5. **Test with MCP Inspector** before deploying to production
6. **Use 127.0.0.1 instead of localhost** on Windows for HTTP transport
7. **Organize complex servers** using directory-based auto-registration
8. **Document parameter schemas** thoroughly for better LLM understanding

## See Also

- [Tools Documentation](tools.md) for detailed tool implementation
- [Resources Documentation](resources.md) for resource management
- [Prompts Documentation](prompts.md) for prompt templates
- [API Reference](api.md) for complete function documentation
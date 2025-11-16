# Auto-Registration System

ModelContextProtocol.jl provides an auto-registration system that automatically loads and registers MCP components (tools, prompts, and resources) from a directory structure. This enables clean organization of large MCP servers with many components.

## Overview

Instead of manually registering each component, you can organize them in directories and let the system auto-register them:

```julia
server = mcp_server(
    name = "my-large-server",
    version = "1.0.0",
    auto_register_dir = "path/to/components"
)
```

The system will automatically scan for and register all components found in the directory structure.

## Directory Structure

The auto-registration system expects a specific directory layout:

```
components/
├── tools/          # MCPTool definitions
│   ├── data_tools.jl
│   ├── file_tools.jl
│   └── math_tools.jl
├── prompts/        # MCPPrompt definitions  
│   ├── analysis.jl
│   └── code_review.jl
└── resources/      # MCPResource definitions
    ├── config.jl
    └── docs.jl
```

Each subdirectory is scanned for `.jl` files containing component definitions.

## Component File Format

### Tool Files (tools/)

Each file should define one or more `MCPTool` instances:

```julia
# tools/math_tools.jl
using ModelContextProtocol

# Simple calculator tool
calculator_tool = MCPTool(
    name = "calculate",
    description = "Perform basic arithmetic calculations",
    parameters = [
        ToolParameter(
            name = "expression",
            type = "string",
            description = "Mathematical expression to evaluate",
            required = true
        )
    ],
    handler = function(params)
        expr = params["expression"]
        try
            result = eval(Meta.parse(expr))
            return TextContent(text = "Result: $result")
        catch e
            return TextContent(text = "Error: $e")
        end
    end
)

# Statistics tool
stats_tool = MCPTool(
    name = "statistics",
    description = "Calculate statistics for a dataset",
    parameters = [
        ToolParameter(
            name = "data",
            type = "array",
            description = "Array of numbers",
            required = true
        )
    ],
    handler = function(params)
        data = params["data"]
        mean_val = sum(data) / length(data)
        return TextContent(text = "Mean: $mean_val")
    end
)
```

### Prompt Files (prompts/)

Define `MCPPrompt` instances for reusable prompt templates:

```julia
# prompts/analysis.jl
using ModelContextProtocol

data_analysis_prompt = MCPPrompt(
    name = "analyze_data",
    description = "Analyze a dataset and provide insights",
    arguments = [
        PromptArgument(
            name = "dataset",
            description = "Description of the dataset to analyze",
            required = true
        ),
        PromptArgument(
            name = "focus_areas",
            description = "Specific areas to focus analysis on",
            required = false
        )
    ],
    messages = [
        PromptMessage(
            role = ModelContextProtocol.user,
            content = TextContent(
                text = """Analyze the following dataset: {dataset}
                
{?focus_areas?Focus particularly on: {focus_areas}}

Provide:
1. Key insights and patterns
2. Statistical summary  
3. Recommendations for further analysis"""
            )
        )
    ]
)
```

### Resource Files (resources/)

Define `MCPResource` instances for data access:

```julia
# resources/config.jl
using ModelContextProtocol
using URIs

app_config_resource = MCPResource(
    uri = URI("config://app/settings"),
    name = "Application Configuration",
    description = "Current application settings and configuration",
    mime_type = "application/json",
    data_provider = function()
        return Dict(
            "version" => "1.0.0",
            "debug_mode" => false,
            "max_connections" => 100,
            "features" => [
                "auto_registration",
                "http_transport",
                "sse_streaming"
            ]
        )
    end
)
```

## Usage Examples

### Basic Auto-Registration

```julia
using ModelContextProtocol

# Create server with auto-registration
server = mcp_server(
    name = "my-server",
    version = "1.0.0",
    auto_register_dir = joinpath(@__DIR__, "mcp_components")
)

# Start server (all components are automatically registered)
start!(server)
```

### With HTTP Transport

```julia
using ModelContextProtocol
using ModelContextProtocol: HttpTransport

# Create server with auto-registration
server = mcp_server(
    name = "http-server",
    auto_register_dir = "components"
)

# Add HTTP transport
transport = HttpTransport(port = 3000)
server.transport = transport
ModelContextProtocol.connect(transport)

start!(server)
```

### Manual Registration Combined

You can combine auto-registration with manual registration:

```julia
# Manual tool
manual_tool = MCPTool(
    name = "special_tool",
    description = "Manually registered tool",
    parameters = [],
    handler = params -> TextContent(text = "Hello from manual tool!")
)

# Server with both auto and manual registration
server = mcp_server(
    name = "mixed-server",
    tools = [manual_tool],  # Manual registration
    auto_register_dir = "components"  # Auto registration
)
```

## Shared State

Components loaded via auto-registration can share state through the global `Main.storage` dictionary:

```julia
# In any tool file
if !isdefined(Main, :storage)
    Main.storage = Dict{String, Any}()
end

# Tool that stores data
store_tool = MCPTool(
    name = "store_data",
    description = "Store data in shared storage",
    parameters = [
        ToolParameter(name = "key", type = "string", required = true),
        ToolParameter(name = "value", type = "string", required = true)
    ],
    handler = function(params)
        Main.storage[params["key"]] = params["value"]
        return TextContent(text = "Data stored successfully")
    end
)

# Tool that retrieves data
get_tool = MCPTool(
    name = "get_data", 
    description = "Get data from shared storage",
    parameters = [
        ToolParameter(name = "key", type = "string", required = true)
    ],
    handler = function(params)
        value = get(Main.storage, params["key"], "Not found")
        return TextContent(text = "Value: $value")
    end
)
```

## Best Practices

### Organization Strategies

1. **By Domain**: Group related functionality
   ```
   components/
   ├── tools/
   │   ├── database_tools.jl
   │   ├── file_tools.jl
   │   └── api_tools.jl
   ```

2. **By Complexity**: Separate simple and complex tools
   ```
   components/
   ├── tools/
   │   ├── basic/
   │   │   ├── math.jl
   │   │   └── text.jl
   │   └── advanced/
   │       ├── ml_analysis.jl
   │       └── data_processing.jl
   ```

3. **By Team**: Organize by development team
   ```
   components/
   ├── tools/
   │   ├── backend_team.jl
   │   ├── frontend_team.jl
   │   └── data_team.jl
   ```

### Component Design

1. **Single Responsibility**: Each tool should have a clear, focused purpose
2. **Error Handling**: Always handle errors gracefully in tool handlers
3. **Documentation**: Use clear descriptions and parameter documentation
4. **Return Types**: Be explicit about return types for better error detection

```julia
my_tool = MCPTool(
    name = "well_designed_tool",
    description = "Clear description of what this tool does",
    parameters = [
        ToolParameter(
            name = "input",
            type = "string",
            description = "Detailed description of this parameter",
            required = true
        )
    ],
    handler = function(params)
        try
            # Tool logic here
            result = process(params["input"])
            return TextContent(text = result)
        catch e
            return TextContent(text = "Error: $(string(e))")
        end
    end,
    return_type = TextContent  # Explicit return type
)
```

### Scaling Considerations

1. **Module Isolation**: Each component file runs in its own module to avoid conflicts
2. **Startup Time**: Large numbers of components may increase server startup time
3. **Memory Usage**: Monitor memory usage with many auto-registered components
4. **Error Isolation**: One broken component file won't prevent others from loading

## Troubleshooting

### Common Issues

1. **Components Not Loading**
   - Check file permissions (files must be readable)
   - Verify directory structure matches expected layout
   - Check for syntax errors in component files

2. **Import Errors**
   - The auto-registration system automatically imports ModelContextProtocol
   - Avoid conflicting using statements in component files
   - Use fully qualified names for other packages

3. **Variable Name Conflicts**
   - Each component runs in its own module, so variable names are isolated
   - Global state should use Main.storage, not module-level variables

### Debugging

Enable verbose logging to see what components are being registered:

```julia
using Logging
global_logger(ConsoleLogger(Logging.Debug))

server = mcp_server(
    name = "debug-server",
    auto_register_dir = "components"
)
```

You'll see messages like:
```
[ Info: Auto-registering components from /path/to/components
[ Info: Registered MCPTool from /path/to/components/tools/math.jl: calculator_tool
[ Info: Registered MCPPrompt from /path/to/components/prompts/analysis.jl: data_analysis_prompt
```

## Complete Example

See `examples/reg_dir.jl` and `examples/reg_dir_http.jl` for complete working examples of auto-registration with both stdio and HTTP transports.
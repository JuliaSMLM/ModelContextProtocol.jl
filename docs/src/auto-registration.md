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
├── tools/          # MCPTool definitions, one per file
│   ├── calculator.jl
│   ├── file_reader.jl
│   └── statistics.jl
├── prompts/        # MCPPrompt definitions, one per file
│   ├── analysis.jl
│   └── code_review.jl
└── resources/      # MCPResource definitions, one per file
    ├── config.jl
    └── docs.jl
```

Exactly three subdirectory names are scanned — `tools/`, `resources/`, and `prompts/`.
Any other directory in the component root is ignored, and the scan is **not recursive**:
only `.jl` files sitting directly in one of those three directories are loaded, never
files in nested subdirectories.

`ResourceTemplate`s have no auto-registration directory. Pass them at server creation
with `mcp_server(resource_templates = [...])` or add them later with
`register!(server, template)`.

## Component File Format

### Tool Files (tools/)

Each file must define **exactly one** `MCPTool`, and it must be the file's final
expression. The loader evaluates the file in a fresh module and registers the value the
file returns — anything defined earlier is available as a helper but is never registered,
so a second tool in the same file is silently dropped. Give each tool its own file:

```julia
# tools/calculator.jl
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
```

```julia
# tools/statistics.jl
using ModelContextProtocol

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

Define one `MCPPrompt` per file, again as the file's final expression:

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

Define one `MCPResource` per file for data access, as the file's final expression:

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
# tools/store_data.jl
if !isdefined(Main, :storage)
    @eval Main storage = Dict{String, Any}()
end

# Tool that stores data
store_tool = MCPTool(
    name = "store_data",
    description = "Store data in shared storage",
    parameters = [
        ToolParameter(name = "key", type = "string",
                      description = "Key to store the value under", required = true),
        ToolParameter(name = "value", type = "string",
                      description = "Value to store", required = true)
    ],
    handler = function(params)
        Main.storage[params["key"]] = params["value"]
        return TextContent(text = "Data stored successfully")
    end
)
```

```julia
# tools/get_data.jl
if !isdefined(Main, :storage)
    @eval Main storage = Dict{String, Any}()
end

# Tool that retrieves data
get_tool = MCPTool(
    name = "get_data", 
    description = "Get data from shared storage",
    parameters = [
        ToolParameter(name = "key", type = "string",
                      description = "Key to look up", required = true)
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

2. **By Naming Prefix**: Convey grouping in the file name, since subdirectories under
   `tools/`, `resources/`, and `prompts/` are never scanned — every component file must
   sit directly in one of those three directories
   ```
   components/
   ├── tools/
   │   ├── basic_math.jl
   │   ├── basic_text.jl
   │   ├── advanced_ml_analysis.jl
   │   └── advanced_data_processing.jl
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
[ Info: Registered MCPTool from /path/to/components/tools/calculator.jl
[ Info: Registered MCPPrompt from /path/to/components/prompts/analysis.jl
```

A file whose final expression is not the type expected for its directory is skipped with
a warning — a stray trailing statement after the component is the usual cause:
```
┌ Warning: File /path/to/components/tools/helpers.jl did not return a MCPTool (got Nothing)
```

Note that a file defining two components produces no warning at all: the last one is
registered and the earlier one is dropped silently, which is why one component per file
matters.

## Complete Example

See `examples/reg_dir.jl` and `examples/reg_dir_http.jl` for complete working examples of auto-registration with both stdio and HTTP transports.

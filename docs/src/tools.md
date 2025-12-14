# MCP Tools

Tools represent callable functions that language models can invoke. Each tool has a name, description, parameters, and a handler function.

## Tool Structure

Every tool in ModelContextProtocol.jl is represented by the `MCPTool` struct, which contains:

- `name`: Unique identifier for the tool
- `description`: Human-readable explanation of the tool's purpose
- `parameters`: List of input parameters the tool accepts (for simple types)
- `input_schema`: Custom JSON Schema for complex parameter types (takes precedence over `parameters`)
- `handler`: Function that executes when the tool is called
- `return_type`: The expected return type of the handler (defaults to `Vector{Content}`)

## Creating Tools

Here's how to create a basic tool:

```julia
calculator_tool = MCPTool(
    name = "calculate",
    description = "Perform basic arithmetic",
    parameters = [
        ToolParameter(
            name = "expression",
            type = "string",
            description = "Math expression to evaluate",
            required = true
        )
    ],
    handler = params -> TextContent(
        text = JSON3.write(Dict(
            "result" => eval(Meta.parse(params["expression"]))
        ))
    )
)
```

## Parameters

Tool parameters are defined using the `ToolParameter` struct:

- `name`: Parameter identifier
- `description`: Explanation of the parameter
- `type`: JSON schema type (e.g., "string", "number", "boolean")
- `required`: Whether the parameter must be provided (default: false)
- `default`: Default value for the parameter (default: nothing)

## Complex Input Schemas

For tools requiring arrays, enums, nested objects, or other advanced JSON Schema features, use `input_schema` instead of `parameters`. When `input_schema` is provided, the `parameters` field is ignored.

### Array Parameters

```julia
tag_tool = MCPTool(
    name = "filter_by_tags",
    description = "Filter items by multiple tags",
    input_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "tags" => Dict{String,Any}(
                "type" => "array",
                "items" => Dict{String,Any}("type" => "string"),
                "description" => "List of tags to filter by",
                "minItems" => 1
            )
        ),
        "required" => ["tags"]
    ),
    handler = function(params)
        tags = params["tags"]
        TextContent(text = "Filtering by tags: $(join(tags, ", "))")
    end
)
```

### Enum Parameters

```julia
sort_tool = MCPTool(
    name = "sort_results",
    description = "Sort results by field and order",
    input_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "field" => Dict{String,Any}(
                "type" => "string",
                "enum" => ["name", "date", "relevance", "size"],
                "description" => "Field to sort by"
            ),
            "order" => Dict{String,Any}(
                "type" => "string",
                "enum" => ["asc", "desc"],
                "default" => "asc"
            )
        ),
        "required" => ["field"]
    ),
    handler = function(params)
        field = params["field"]
        order = get(params, "order", "asc")
        TextContent(text = "Sorting by $field ($order)")
    end
)
```

### Nested Objects

```julia
filter_tool = MCPTool(
    name = "advanced_filter",
    description = "Filter with complex criteria",
    input_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "query" => Dict{String,Any}("type" => "string"),
            "options" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "limit" => Dict{String,Any}(
                        "type" => "integer",
                        "default" => 10,
                        "minimum" => 1,
                        "maximum" => 100
                    ),
                    "offset" => Dict{String,Any}(
                        "type" => "integer",
                        "default" => 0
                    )
                )
            )
        ),
        "required" => ["query"]
    ),
    handler = function(params)
        query = params["query"]
        options = get(params, "options", Dict())
        limit = get(options, "limit", 10)
        TextContent(text = "Query: $query (limit=$limit)")
    end
)
```

## Return Values

Tool handlers can return various types which are automatically converted:

- `Content` instance: A single `TextContent`, `ImageContent`, or `EmbeddedResource`
- `Vector{<:Content}`: Multiple content items (can mix different content types)
- `Dict`: Automatically converted to JSON and wrapped in `TextContent`
- `String`: Automatically wrapped in `TextContent`
- `Tuple{Vector{UInt8}, String}`: Automatically wrapped in `ImageContent` (bytes, mime_type)
- `CallToolResult`: For full control over the response including error handling

When `return_type` is `Vector{Content}` (default), single items are automatically wrapped in a vector.

## Registering Tools

Tools can be registered with a server in two ways:

1. During server creation:
```julia
server = mcp_server(
    name = "my-server",
    tools = my_tool  # Single tool or vector of tools
)
```

2. After server creation:
```julia
register!(server, my_tool)
```

## Directory-Based Organization

Tools can be organized in directory structures and auto-registered:

```
my_server/
└── tools/
    ├── calculator.jl
    └── time_tool.jl
```

Each file should export one or more `MCPTool` instances:

```julia
# calculator.jl
using ModelContextProtocol
using JSON3

calculator_tool = MCPTool(
    name = "calculate",
    description = "Basic calculator",
    parameters = [
        ToolParameter(name = "expression", type = "string", required = true)
    ],
    handler = params -> TextContent(
        text = JSON3.write(Dict("result" => eval(Meta.parse(params["expression"]))))
    )
)
```

Then auto-register from the directory:

```julia
server = mcp_server(
    name = "my-server",
    auto_register_dir = "my_server"
)
```

## Advanced Examples

### Tool with Multiple Content Returns

```julia
analyze_tool = MCPTool(
    name = "analyze_data",
    description = "Analyze data and return text + image",
    parameters = [
        ToolParameter(name = "data", description = "Data to analyze", type = "string", required = true)
    ],
    handler = function(params)
        # Return multiple content items
        return [
            TextContent(text = "Analysis complete"),
            ImageContent(
                data = generate_chart_bytes(),  # Your chart generation
                mime_type = "image/png"
            ),
            TextContent(text = "See chart above for details")
        ]
    end,
    return_type = Vector{Content}
)
```

### Tool with Error Handling

```julia
safe_tool = MCPTool(
    name = "safe_operation",
    description = "Tool with explicit error handling",
    parameters = [
        ToolParameter(name = "path", description = "File path", type = "string", required = true)
    ],
    handler = function(params)
        if !isfile(params["path"])
            # Return error result
            return CallToolResult(
                content = [Dict("type" => "text", "text" => "File not found")],
                is_error = true
            )
        end
        
        content = read(params["path"], String)
        return TextContent(text = content)
    end
)
```
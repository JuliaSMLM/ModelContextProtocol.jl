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

## Structured Output

Declare an `output_schema` and return machine-readable results in `structuredContent`
alongside the human-readable `content` (the spec recommends providing both):

```julia
stats_tool = MCPTool(
    name = "get_stats",
    description = "Compute dataset statistics",
    parameters = [],
    output_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}("count" => Dict{String,Any}("type" => "integer"))
    ),
    handler = args -> CallToolResult(
        content = [Dict{String,Any}("type" => "text", "text" => "{\"count\": 42}")],
        structured_content = Dict("count" => 42)
    )
)
```

The schema is emitted as `outputSchema` in `tools/list`; the result field serializes as
`structuredContent`.

## Tool Annotations

Annotations are behavioral hints clients can use for trust and approval decisions. They
are emitted verbatim in `tools/list`:

```julia
MCPTool(
    name = "delete_file",
    description = "Delete a file",
    parameters = [ToolParameter(name = "path", type = "string", description = "File path", required = true)],
    handler = my_handler,
    annotations = Dict{String,Any}(
        "readOnlyHint" => false,
        "destructiveHint" => true,
        "idempotentHint" => true,
        "openWorldHint" => false
    )
)
```

## Context-Aware Handlers and Progress

A handler may accept a second argument to receive the per-request context — useful for
progress reporting on long-running tools and for reading the authenticated user when
HTTP auth is enabled:

```julia
MCPTool(
    name = "long_job",
    description = "Process with progress updates",
    parameters = [],
    handler = (args, ctx) -> begin
        for i in 1:10
            send_progress(ctx, i; total = 10, message = "step $i")
            # ... work ...
        end
        TextContent(text = "done")
    end
)
```

`send_progress` emits `notifications/progress` (over stdout for stdio, over the SSE
stream for HTTP) and is a safe no-op when the client did not send a `progressToken`.
The context also exposes `ctx.authenticated_user` and `ctx.request_id`. Plain
one-argument handlers keep working unchanged.

## Audio and Resource Links in Results

Tools can return audio and references to large artifacts without embedding them:

```julia
handler = args -> [
    TextContent(text = "Analysis complete"),
    AudioContent(data = wav_bytes, mime_type = "audio/wav"),
    ResourceLink(
        uri = "file:///results/overlay.png",
        name = "overlay.png",
        mime_type = "image/png",
        size = 123_456
    )
]
```

`ResourceLink` serializes to the spec `resource_link` content block, letting clients fetch
or subscribe to the artifact instead of receiving inline base64.

## Long-Running Tools: Tasks (experimental)

MCP Tasks (protocol 2025-11-25, SEP-1686) let clients run a tool call in the
background instead of waiting on the response: the client augments `tools/call` with a
`task` field, the server immediately answers with a task handle, executes the handler
in a background Julia task, and the client polls `tasks/get` until the task completes,
then fetches the real result via `tasks/result`.

Tools opt in per tool:

```julia
MCPTool(
    name = "train_model",
    description = "Long-running training job",
    parameters = [],
    handler = (args, ctx) -> begin
        for epoch in 1:100
            task_cancelled(ctx) && return TextContent(text = "stopped early")
            send_progress(ctx, epoch; total = 100, message = "epoch $epoch")
            # ... work ...
        end
        TextContent(text = "trained")
    end,
    task_support = :optional   # :forbidden (default) | :optional | :required
)
```

- `:forbidden` (the default): task-augmented calls are rejected (`-32601`), the tool
  always runs synchronously.
- `:optional`: the client chooses per call — plain calls run synchronously, calls with
  a `task` field run in the background.
- `:required`: the tool only runs as a task; synchronous calls are rejected (`-32601`).

The setting is advertised per tool as `execution.taskSupport` in `tools/list`, and the
server only offers the `tasks` capability to clients that negotiated protocol
`2025-11-25`. Older clients fall back exactly as the spec mandates: their task
metadata is ignored and the call runs synchronously.

What the server handles for you:

- `tasks/get` — status polling (`working` → `completed`/`failed`/`cancelled`), with
  `createdAt`/`lastUpdatedAt` timestamps, the actual `ttl`, and a suggested
  `pollInterval`.
- `tasks/result` — blocks until the task is terminal, then returns exactly what the
  call would have returned (including tool errors), tagged with the spec's
  `io.modelcontextprotocol/related-task` metadata. The serial request loop is never
  blocked: on HTTP the POST simply stays open; on stdio the response is written
  out-of-band when ready.
- `tasks/cancel` — marks the task `cancelled` and wakes any blocked `tasks/result`.
  Handlers can notice via [`task_cancelled`](@ref) and stop early; even if the
  handler runs to completion, the late result is discarded. Cancelling an already
  terminal task is rejected (`-32602`).
- `tasks/list` — cursor-paginated listing of the requestor's tasks. On an HTTP
  transport without authentication the server cannot tell requestors apart, so
  `tasks/list` is withheld there (per the spec's security guidance). With HTTP auth
  enabled, tasks are bound to the authenticated principal: other principals cannot
  see, poll, fetch, or cancel them.
- `notifications/tasks/status` — optional status-change notifications, delivered over
  the transport-correct channel (stdout for stdio, the SSE stream for HTTP).

Task records are retained for the requested `ttl` (clamped to a server maximum of one
hour; default five minutes) and swept after expiry. Progress notifications keep
working inside task handlers — the `progressToken` from the original call stays valid
for the task's lifetime.

!!! note "Experimental"
    Tasks are experimental in the MCP spec and may evolve in future protocol
    versions. Client-initiated task flows (`input_required`, task-augmented
    elicitation/sampling) are not applicable server-side and are not implemented.
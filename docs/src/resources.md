# MCP Resources

Resources provide data that language models can access. Each resource has a URI, name, MIME type, and a data provider function.

## Resource Structure

Every resource in ModelContextProtocol.jl is represented by the `MCPResource` struct:

- `uri`: Unique URI identifier for the resource
- `name`: Human-readable resource name
- `description`: Explanation of the resource's purpose
- `mime_type`: Content type (e.g., "application/json", "text/plain")
- `data_provider`: Function that returns the resource's data
- `annotations`: Optional metadata about the resource

## Creating Resources

Here's how to create a basic resource:

```julia
using URIs

weather_resource = MCPResource(
    uri = "weather://current",
    name = "Current Weather",
    description = "Current weather conditions",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "temperature" => 22.5,
        "conditions" => "Partly Cloudy",
        "updated" => Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    )
)
```

Note: The `uri` field accepts both strings and URI objects. Strings are automatically converted to URIs.

## Data Providers

The `data_provider` function can return different types of data:

1. **For simple data (automatically serialized to JSON)**:
   - Return Julia objects (Dict, Array, etc.) that can be JSON-serialized
   - These are wrapped in `TextResourceContents` with JSON serialization

2. **For explicit control over content**:
   - Return `TextResourceContents` for text data
   - Return `BlobResourceContents` for binary data
   
The `data_provider` receives the requested URI as a parameter when using wildcards.

## Registering Resources

Resources can be registered with a server in two ways:

1. During server creation:
```julia
server = mcp_server(
    name = "my-server",
    resources = my_resource  # Single resource or vector of resources
)
```

2. After server creation:
```julia
register!(server, my_resource)
```

## Directory-Based Organization

Resources can be organized in directory structures and auto-registered:

```
my_server/
└── resources/
    ├── weather.jl
    └── stock_data.jl
```

Each file should export one or more `MCPResource` instances:

```julia
# weather.jl
using ModelContextProtocol
using Dates

weather_resource = MCPResource(
    uri = "weather://current",
    name = "Current Weather",
    description = "Current weather conditions",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "temperature" => 22.5,
        "conditions" => "Partly Cloudy",
        "updated" => Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
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

### Resource with Dynamic Data

The `data_provider` is called with no arguments on every `resources/read`. What it
returns determines the wire contents:

- A **`TextResourceContents`** or **`BlobResourceContents`** (or a vector of them) is
  serialized directly — this is how binary resources are served (base64 `blob` on the
  wire) and how you control the contents `uri`/`mimeType` per entry.
- A **`String`** becomes the text contents verbatim, with the resource's `mime_type`.
- Anything else is **JSON-encoded** into a text contents entry.

```julia
# JSON data (encoded automatically)
log_resource = MCPResource(
    uri = "app://logs/recent",
    name = "Recent Log Entries",
    description = "The most recent application log entries",
    mime_type = "application/json",
    data_provider = function ()
        entries = isfile("app.log") ?
            collect(Iterators.take(eachline("app.log"), 50)) : String[]
        return Dict("count" => length(entries), "entries" => entries)
    end
)
```

### Resource with Binary Data

Return a `BlobResourceContents` to serve binary data (base64-encoded on the wire):

```julia
image_resource = MCPResource(
    uri = "images://logo",
    name = "Logo Image",
    description = "Company logo",
    mime_type = "image/png",
    data_provider = () -> BlobResourceContents(
        uri = "images://logo",
        mime_type = "image/png",
        blob = read("logo.png")   # Vector{UInt8}
    )
)
```

This pairs naturally with `ResourceLink` tool results: a tool can return a link to a
large artifact, and the client then reads the binary via `resources/read`.

### Current Limitations

- Resources are matched by **exact URI**; wildcard or template URIs (e.g. `file://*`)
  are not routed to providers (`data_provider` takes no arguments).
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

### Resource with Dynamic URI Patterns

```julia
# Support URIs like file://path/to/file.txt
file_resource = MCPResource(
    uri = "file://*",
    name = "File System Access",
    description = "Access local files",
    mime_type = "text/plain",
    data_provider = function(uri::String)
        # Extract path from URI
        path = replace(uri, "file://" => "")
        
        if isfile(path)
            content = read(path, String)
            return TextResourceContents(
                uri = uri,
                text = content,
                mime_type = "text/plain"
            )
        else
            error("File not found: $path")
        end
    end
)
```

### Resource with Binary Data

```julia
image_resource = MCPResource(
    uri = "images://logo",
    name = "Logo Image",
    description = "Company logo",
    mime_type = "image/png",
    data_provider = function(uri::String)
        image_data = read("logo.png")  # Returns Vector{UInt8}
        return BlobResourceContents(
            uri = uri,
            blob = image_data,
            mime_type = "image/png"
        )
    end
)
```
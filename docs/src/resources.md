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
- `title`: Optional human-friendly display name
- `icons`: Optional icons for UI display
- `_meta`: Optional metadata for protocol extensions, emitted verbatim in `resources/list`

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

The `data_provider` is a **zero-argument** function called on every `resources/read`.
It can return different types of data:

1. **For simple data (automatically serialized to JSON)**:
   - Return Julia objects (Dict, Array, etc.) that can be JSON-serialized
   - These become a text contents entry with the resource's `mime_type`

2. **For verbatim text**: return a `String` — used as the text contents as-is

3. **For explicit control over content** (including binary):
   - Return `TextResourceContents` for text data
   - Return `BlobResourceContents` for binary data (base64 `blob` on the wire)
   - Return a `Vector` of them for multiple contents entries

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

Each file must define exactly one `MCPResource` as the file's final expression — the
loader registers the value of the last expression and ignores everything else defined in
the file:

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

## URI Templates

For a parameterized *family* of resources — content-addressed artifacts, per-id
results, file trees — register a `ResourceTemplate` instead of one resource per URI.
Templates use RFC 6570 level-1 placeholders (`{var}`, matching one path segment) and
are advertised to clients via `resources/templates/list`:

```julia
artifact_template = ResourceTemplate(
    name = "artifact",
    uri_template = "app://artifact/{id}",
    description = "Content-addressed result artifacts",
    mime_type = "image/png",
    data_provider = (uri, vars) -> BlobResourceContents(
        uri = uri,
        mime_type = "image/png",
        blob = read(artifact_path(vars["id"]))
    )
)

server = mcp_server(
    name = "my-server",
    resource_templates = [artifact_template]   # or register!(server, artifact_template)
)
```

A `resources/read` whose URI matches no exact resource is routed through the
templates: the first match with a provider serves it. The provider receives the
requested URI — `provider(uri)` — or opts into `provider(uri, vars)` to also get the
extracted placeholder values. Return values follow the same contract as resource
providers (`ResourceContents`/vector, `String` verbatim, JSON fallback). Exact-URI
resources always take precedence over templates.

### Completing Template Variables

A template's `completions` field supplies `completion/complete` suggestions for its
placeholders, so clients can offer values as the user types a URI. It maps a variable
name to either a `Vector{String}` (served filtered by prefix against the partial value)
or a function — `value -> values`, or `(value, context_args) -> values` to also receive
the arguments already resolved for the request:

```julia
artifact_template = ResourceTemplate(
    name = "artifact",
    uri_template = "app://artifact/{id}",
    description = "Content-addressed result artifacts",
    data_provider = (uri, vars) -> read_artifact(vars["id"]),
    completions = Dict{String,Any}("id" => value -> recent_artifact_ids(value))
)
```

Suggestions are capped at 100 values with `total`/`hasMore` reported to the client. The
wire details are in [The Modern Era](modern.md); `completion/complete` is served in both
eras and the completion capability is advertised by default.

## Subscriptions and Change Notifications

Clients can follow resource changes instead of re-reading, through a different mechanism
in each era:

- **Legacy era**: `resources/subscribe` / `resources/unsubscribe` record the client's
  interest per URI on its session (the `subscribe` resource capability is advertised by
  default). Both are idempotent and answer with an empty result; a subscribed session
  then receives `notifications/resources/updated` for those URIs — on stdout for stdio,
  on the standalone GET SSE stream for Streamable HTTP.
- **Modern era**: `subscriptions/listen` replaces both the legacy GET stream and
  `resources/subscribe` — a single long-lived request whose response stream carries only
  the notification types the client opted into. See [The Modern Era](modern.md).

Announce changes from server code with two exported functions, which deliver to the open
`subscriptions/listen` streams that opted into them and to the subscribed legacy
session:

```julia
# A resource's contents changed
notify_resource_updated(server, "app://logs/recent")

# A component list changed after registering or removing something at runtime
notify_list_changed(server, :resources)   # or :tools, :prompts
```

Both return the number of clients notified (listen streams plus the legacy session
when it was reached). There is no backlog — only clients connected at the time of the
call are reached — and `notify_list_changed` reaches the legacy session only when the
corresponding `listChanged` capability is declared.

Separately, `subscribe!(server, uri, callback)` and `unsubscribe!(server, uri, callback)`
maintain an in-process registry of callbacks keyed by URI, for server-side code that
wants to react to its own updates. `notify_resource_updated` invokes each matching
callback as `callback(uri)` (errors are logged and swallowed); the callbacks themselves
send nothing to clients.

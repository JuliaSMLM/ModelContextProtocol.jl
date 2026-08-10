# ModelContextProtocol.jl API Reference

## Table of Contents

- [Overview](#overview)
- [Quick Reference](#quick-reference)
- [Design Philosophy](#design-philosophy)
- [Quick Start](#quick-start)
- [Core Architecture](#core-architecture)
- [Protocol Version Negotiation](#protocol-version-negotiation)
- [Core Functions](#core-functions)
- [Component Types](#component-types)
  - [Tools](#tools)
  - [Resources](#resources)
  - [Prompts](#prompts)
  - [Icons](#icons)
- [Content Types](#content-types)
- [Control Types](#control-types)
- [Tasks](#tasks)
  - [Legacy era (SEP-1686, experimental)](#legacy-era-sep-1686-experimental)
  - [Modern era (SEP-2663, tasks extension)](#modern-era-sep-2663-tasks-extension)
- [MRTR: client input from handlers](#mrtr-client-input-from-handlers-modern-era)
- [Transport Types](#transport-types)
- [Authentication (OAuth Resource Server)](#authentication-oauth-resource-server)
- [Auto-Registration](#auto-registration-system)
- [Utility Functions](#utility-functions)
- [Advanced Features](#advanced-features)
- [Common Patterns](#common-patterns)
- [Protocol Compliance and API Stability](#protocol-compliance-and-api-stability)
- [Error Handling](#error-types-and-handling)
- [Debugging](#debugging-techniques)
- [Performance](#performance-considerations)
- [Troubleshooting](#troubleshooting)

## Overview

ModelContextProtocol.jl provides a Julia implementation of the Model Context Protocol (MCP), enabling standardized communication between AI applications and external tools, resources, and data sources.

The server is **dual-era**: it serves both the modern stateless era (`2026-07-28`, selected per request through the `_meta` key `io.modelcontextprotocol/protocolVersion`, no handshake) and the legacy handshake era (`initialize` negotiates one of `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`). Both eras are live at the same time on the same server — see [Protocol Version Negotiation](#protocol-version-negotiation), and `docs/src/modern.md` for the modern era in depth.

Notable capabilities: structured tool output (`output_schema`/`structuredContent`), tool annotations, audio content and `resource_link` content blocks, progress notifications from context-aware handlers (`handler = (args, ctx) -> ...` + `send_progress`), argument/variable completion (`completion/complete`), resource subscriptions with `notify_resource_updated`/`notify_list_changed`, background execution via Tasks in both eras, modern-era MRTR (handlers asking the client for elicitation/sampling/roots input), runtime `logging/setLevel`, and an OAuth Resource Server for the HTTP transport (`create_github_auth`, `JWKSValidator` for signature-verified JWTs from external authorization servers, `HttpTransport(; auth, resource_metadata)`).

### Version Information

⚠️ **Critical Distinction - Two Different Versions:**

| Version Type | Example | Who Sets It | Purpose |
|-------------|---------|------------|----------|
| **Protocol Version** | `"2026-07-28"` (modern) / `"2025-11-25"` (legacy) | MCP Specification | Modern: per request via `_meta`. Legacy: negotiated at `initialize` (down to `2024-11-05`) |
| **Server Version** | `"1.0.0"` | You (developer) | Your server's version |

```julia
# The protocol version is handled internally - you don't set it
# You only set YOUR server's version:
server = mcp_server(
    name = "my-server",
    version = "2.3.1",  # ← YOUR server version, not the protocol!
    tools = my_tools
)
```

### Breaking Changes and Migration

**From Earlier Versions:**
- Two eras run side by side: modern-era clients send `2026-07-28` in each request's `_meta` (no `initialize`); legacy clients negotiate at `initialize`, where the server advertises `2025-11-25` and falls back through `2025-06-18` and `2025-03-26` to `2024-11-05`
- JSON-RPC batching is no longer supported
- ResourceLink is a new content type (spec wire shape `{"type":"resource_link","uri":...,"name":...}`)
- Session management added for HTTP transport

**Migration Tips:**
- Send the latest protocol version you support in `initialize`; the server negotiates the rest
- Split batch requests into individual calls
- Use ResourceLink for resource references instead of embedding

## Quick Reference

### Essential Functions
- `mcp_server(name="...", version="1.0.0", tools=..., resources=..., prompts=...)` - Create server
- `start!(server, transport=...)` - Start server (blocks for HTTP)
- `connect(transport)` - Initialize HTTP transport (required before start!)
- `register!(server, component)` - Add components dynamically

### Key Types
- `MCPTool` - Define executable tools
- `MCPResource` - Provide data resources
- `MCPPrompt` - Create prompt templates
- `TextContent` / `ImageContent` - Return content from handlers
- `StdioTransport` / `HttpTransport` - Communication transports

### Common Patterns
```julia
# Minimal tool
tool = MCPTool(
    name = "example",
    description = "Example tool",
    parameters = [],  # Required, even if empty!
    handler = (p) -> TextContent(text = "Result")
)

# Tool with multiple return types
multi_tool = MCPTool(
    name = "multi",
    description = "Returns multiple content items",
    parameters = [],
    handler = function(params)
        # Return array of different content types
        return [
            TextContent(text = "Analysis results"),
            ImageContent(data = image_bytes, mime_type = "image/png"),
            TextContent(text = "Summary: Process complete")
        ]
    end
)

# Start server
server = mcp_server(
    name = "my-server",
    version = "1.0.0",  # Your server version
    tools = [tool, multi_tool]
)
start!(server)  # Uses stdio by default
```

## Design Philosophy

### Core Principles

1. **Protocol-First Design**: Dual-era. Modern-era requests (`2026-07-28`, declared per request in `_meta`) are served statelessly; legacy clients negotiate at `initialize` across 2025-11-25, 2025-06-18, 2025-03-26, and 2024-11-05.

2. **Layered Architecture**: 
   - **Transport Layer**: Abstract interface with stdio and HTTP implementations
   - **Protocol Layer**: JSON-RPC message handling and routing
   - **Features Layer**: Tools, resources, and prompts implementation
   - **Core Layer**: Server state management and initialization

3. **Type System Design**:
   - Exported abstract types (`Content`, `ResourceContents`, `Transport`) for extensibility and type annotations
   - Concrete types with `@kwdef` for ergonomic construction with defaults
   - Module isolation for safe dynamic component loading
   - Small maps use `LittleDict` for performance (from OrderedCollections.jl)

4. **Handler Design**:
   - Tool handlers receive `Dict{String,Any}` parameters for JSON flexibility
   - Support multiple return types with automatic conversion
   - `CallToolResult` for explicit control when needed

5. **Minimal Public API**: Only essential types and functions are exported. Internal complexity remains internal.

## Quick Start

### Create Your First Tool

```julia
using ModelContextProtocol

# Create a simple tool that says hello
hello_tool = MCPTool(
    name = "hello",
    description = "Say hello to someone",
    parameters = [
        ToolParameter(
            name = "name",
            type = "string",
            description = "Name to greet",
            required = true
        )
    ],
    handler = function(params)
        name = params["name"]
        return TextContent(text = "Hello, $name! Welcome to MCP.")
    end
)
```

### Step 3: Create and Start Server

```julia
# Create server with your tool
server = mcp_server(
    name = "hello-server",
    version = "1.0.0",  # YOUR server version (not protocol version!)
    tools = hello_tool
)

# Start the server (uses stdio by default)
start!(server)
```

### Step 4: Test Your Server

```bash
# Test with a simple echo command
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | julia --project your_server.jl

# Or use MCP Inspector for interactive testing
julia --project your_server.jl | npx @modelcontextprotocol/inspector
```

## Core Architecture

### Transport Hierarchy

```julia
abstract type Transport end
├── StdioTransport    # Standard input/output
└── HttpTransport     # HTTP with SSE support
```

### Content Type Hierarchy

```julia
abstract type Content end
├── TextContent       # Text-based content
├── ImageContent      # Binary image data
├── AudioContent      # Binary audio data
├── EmbeddedResource  # Embedded resource content
└── ResourceLink      # Reference to a resource
```

### Resource Contents Hierarchy

```julia
abstract type ResourceContents end
├── TextResourceContents  # Text-based resource data
└── BlobResourceContents  # Binary resource data
```

## Protocol Version Negotiation

The server speaks two protocol eras concurrently, and which one a request gets is
decided by the request itself:

- **Modern era (stateless).** A request whose `params._meta` carries
  `"io.modelcontextprotocol/protocolVersion" => "2026-07-28"` is served statelessly —
  no `initialize`, no session. This is the surface described in `docs/src/modern.md`
  (per-request client capabilities, `server/discover`, `subscriptions/listen`, MRTR,
  the tasks extension, per-request `logLevel`).
- **Legacy era (handshake).** A client that calls `initialize` negotiates one version
  from the supported list and keeps it for the session.

```julia
LATEST_PROTOCOL_VERSION      # "2025-11-25" — latest LEGACY (handshake) version
SUPPORTED_PROTOCOL_VERSIONS  # ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
FEATURE_VERSIONS             # Dict{Symbol,String}: feature => minimum legacy version
```

The modern-era version (`"2026-07-28"`) is not part of `SUPPORTED_PROTOCOL_VERSIONS`:
that constant is the `initialize` handshake list, and the two eras are deliberately
separate.

### `negotiate_version(client_version) -> String`

Apply the spec's negotiation rule to an `initialize` request's `protocolVersion`.

```julia
negotiate_version("2025-06-18")  # "2025-06-18" — supported, echoed back
negotiate_version("2099-01-01")  # "2025-11-25" — unsupported, our latest is offered
negotiate_version(nothing)       # "2025-11-25"
```

This runs internally at `initialize`; call it directly only when building your own
handshake logic or tests.

### `is_supported_version(version) -> Bool`

```julia
is_supported_version("2025-03-26")  # true
is_supported_version("2026-07-28")  # false — modern era, not an initialize version
```

### `supports(version, feature) -> Bool`

Gate optional behavior on the client's protocol version. Legacy sessions carry the
negotiated version in `ctx.state.protocol_version`; modern requests carry theirs in
`ctx.protocol_version` (their `ctx.state` is a fresh, unnegotiated state whose
version is `nothing`) — so merge the two before gating:

```julia
handler = (args, ctx) -> begin
    version = ctx.protocol_version === nothing ?
        ctx.state.protocol_version : ctx.protocol_version
    if version !== nothing && supports(version, :resource_links)
        return ResourceLink(uri = "app://report/42", name = "Report 42")
    end
    TextContent(text = "app://report/42")
end
```

Feature keys (`FEATURE_VERSIONS`): `:tasks`, `:sse_priming_events`, `:icon_metadata`,
`:tool_calling_in_sampling`, `:oauth_openid_connect`, `:oauth_incremental_scope`,
`:url_elicitation` (all `2025-11-25`); `:resource_links` (`2025-06-18`);
`:streamable_http` (`2025-03-26`). An unknown feature symbol returns `false`.

## Core Functions

### `mcp_server`

Create an MCP server instance with tools, resources, and prompts.

```julia
mcp_server(;
    name::String,                        # Required: Server name
    version::String = "1.0.0",           # Your server version (defaults to "1.0.0", NOT the protocol version)
    tools = nothing,                     # Single MCPTool or Vector{MCPTool}
    resources = nothing,                 # Single MCPResource or Vector{MCPResource}
    resource_templates = nothing,        # Single ResourceTemplate or Vector{ResourceTemplate}
    prompts = nothing,                   # Single MCPPrompt or Vector{MCPPrompt}
    description::String = "",            # Server description (serverInfo.description)
    instructions::String = "",           # Usage instructions returned to the client at initialize
    capabilities::Vector{Capability} = default_capabilities(),  # Protocol capabilities (usually use default)
    auto_register_dir = nothing,         # Directory for auto-registration
    title = nothing,                     # Optional human-friendly display name (serverInfo.title)
    icons = nothing,                     # Union{Vector{MCPIcon},Nothing} for serverInfo.icons
    mrtr_state_key = nothing             # Union{Vector{UInt8},Nothing}: HMAC key for MRTR requestState
                                         # (a random ephemeral key is generated when omitted)
) -> Server
```

**Protocol Version:** Set by the client, not here. Modern-era clients declare
`2026-07-28` per request in `_meta`; legacy clients negotiate `2025-11-25` down to
`2024-11-05` at `initialize`. See [Protocol Version Negotiation](#protocol-version-negotiation).

**Capabilities:** `capabilities` is a `Vector{Capability}`. `Capability`,
`default_capabilities`, and the concrete capability types are internal (not exported) —
the default set covers resources (list-changed + subscribe), tools, prompts, logging,
completion, and tasks, and is what you want unless you are deliberately withholding a
feature. To customize, import them explicitly:
`using ModelContextProtocol: default_capabilities, ToolCapability`.

**Examples:**

```julia
# Simple server
server = mcp_server(name = "simple")  # Uses default version "1.0.0"

# Server with explicit version
server = mcp_server(
    name = "simple",
    version = "2.1.0"  # Your custom server version
)

# Server with components
# Define components first
tool1 = MCPTool(
    name = "tool1",
    description = "First tool",
    parameters = [],  # Empty array for no parameters
    handler = (p) -> TextContent(text = "Tool 1 result")
)

tool2 = MCPTool(
    name = "tool2",
    description = "Second tool",
    parameters = [],
    handler = (p) -> TextContent(text = "Tool 2 result")
)

my_resource = MCPResource(
    uri = "resource://example",
    name = "Example Resource",
    data_provider = () -> Dict("data" => "value")
)

prompt1 = MCPPrompt(
    name = "greeting",
    description = "Greeting prompt"
)

prompt2 = MCPPrompt(
    name = "analysis",
    description = "Analysis prompt"
)

server = mcp_server(
    name = "full-server",
    version = "1.0.0",  # Your server's version
    tools = [tool1, tool2],
    resources = my_resource,
    prompts = [prompt1, prompt2]
)

# Auto-registration from directory
server = mcp_server(
    name = "auto-server",
    version = "1.0.0",  # Your server version
    auto_register_dir = "mcp_components"
)
```

### Server Operations

#### `start!(server::Server; transport::Union{Transport,Nothing}=nothing)`

Start the MCP server and begin processing requests.

```julia
# Default stdio transport
start!(server)

# Custom transport
transport = HttpTransport(port = 3000)
connect(transport)  # Required for HTTP only
start!(server, transport = transport)
```

**Behavior:**
- For stdio: Processes messages from stdin, responds to stdout
- For HTTP: Blocks and runs server until interrupted

#### `stop!(server::Server)`

Stop a running MCP server and clean up resources.

```julia
stop!(server)
```

**Behavior:**
- Closes active connections
- Releases bound ports (HTTP)
- Sets server.active to false
- Safe to call multiple times

#### `connect(transport::HttpTransport)`

Initialize HTTP server and bind to port. **Required before `start!` for HTTP transport only.**

**Note:** This function is only needed for `HttpTransport`. `StdioTransport` does not require `connect()`.

```julia
transport = HttpTransport(port = 3000)
connect(transport)  # Binds port, starts HTTP server
```

#### `register!(server::Server, component)`

Register components after server creation.

```julia
# Define components
new_tool = MCPTool(name = "new_tool", description = "New tool", parameters = [], handler = (p) -> TextContent(text = "Done"))
new_resource = MCPResource(uri = "resource://new", name = "New Resource", data_provider = () -> Dict())
new_prompt = MCPPrompt(name = "new_prompt", description = "New prompt")

# Register them
register!(server, new_tool)      # Add tool
register!(server, new_resource)  # Add resource
register!(server, new_prompt)    # Add prompt
```

## Component Types

**Note:** All component type definitions are located in `src/types.jl`.

### Tools

#### `MCPTool`

Define a tool that can be invoked by clients.

```julia
MCPTool(;
    name::String,                          # Unique identifier
    description::String,                   # Human-readable description
    parameters::Vector{ToolParameter} = ToolParameter[],  # Input parameters (use [] for none)
    input_schema::Union{Nothing,AbstractDict} = nothing,  # Custom JSON Schema (takes precedence)
    handler::Function,                     # handler(args) or handler(args, ctx)
    return_type::Type = Vector{Content},   # Expected return type (default: Vector{Content})
    title::Union{String,Nothing} = nothing,        # Optional display name
    icons::Union{Vector{MCPIcon},Nothing} = nothing,  # Optional icons (tools/list)
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Behavioral hints (readOnlyHint, ...)
    output_schema::Union{Nothing,AbstractDict} = nothing,  # JSON Schema for structured output
    _meta::Union{Nothing,Dict{String,Any}} = nothing,  # Protocol-extension metadata
    task_support::Symbol = :forbidden,     # MCP Tasks: :forbidden | :optional | :required
    required_scopes::Vector{String} = String[]  # OAuth scopes the caller must hold to invoke
                                           # this tool. Enforced at tools/call only when the
                                           # request carries an authenticated principal (HTTP
                                           # auth active); skipped when auth is not configured.
                                           # Server-side policy — not emitted in tools/list.
)
```

**Schema Options:**
- Use `parameters` for simple tools with basic types (string, number, boolean)
- Use `input_schema` for complex schemas requiring arrays, enums, nested objects, or advanced JSON Schema features
- When `input_schema` is provided, the `parameters` field is ignored

**Handler Return Types:**
- Single `Content` subtype (auto-wrapped in vector)
- `Vector{<:Content}` for multiple items
- `CallToolResult` for explicit control (ignores return_type)
- `String` (auto-wrapped in TextContent)
- `Dict` (converted to JSON string and wrapped in TextContent)
- `Nothing` or `missing` (returns empty content array)

**Return Type Validation:**
The `return_type` field validates handler returns:
```julia
# Default: accepts any Content or Vector{Content}
return_type = Content  # Most flexible

# Specific type: validates single content type
return_type = TextContent  # Only accepts TextContent
return_type = ImageContent  # Only accepts ImageContent

# Note: CallToolResult bypasses validation
```

#### `ToolParameter`

Define tool parameters with optional defaults.

```julia
ToolParameter(;
    name::String,                    # Parameter name
    type::String,                    # JSON Schema type (e.g., "string", "number", "boolean")
    description::String,             # Description (required)
    required::Bool = false,          # Whether required
    default::Any = nothing,          # Default value if not provided
    header::Union{String,Nothing} = nothing  # SEP-2243 mirroring suffix: emitted as
                                     # x-mcp-header; modern HTTP clients mirror the
                                     # argument as Mcp-Param-<header>, validated
                                     # against the body by the server
)
```

**Example:**

```julia
calc_tool = MCPTool(
    name = "calculate",
    description = "Evaluate math expressions",
    parameters = [
        ToolParameter(
            name = "expression",
            type = "string",
            description = "Math expression to evaluate",
            required = true
        ),
        ToolParameter(
            name = "precision",
            type = "number",
            description = "Decimal places",
            default = 2
        )
    ],
    handler = function(params)
        result = eval(Meta.parse(params["expression"]))
        precision = get(params, "precision", 2)  # Uses default
        TextContent(text = string(round(result, digits=Int(precision))))
    end
)
```

#### Complex Input Schemas

For tools requiring arrays, enums, nested objects, or other advanced JSON Schema features, use `input_schema` instead of `parameters`:

**Array Parameters:**
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
            ),
            "match_all" => Dict{String,Any}(
                "type" => "boolean",
                "default" => false,
                "description" => "Require all tags to match"
            )
        ),
        "required" => ["tags"]
    ),
    handler = function(params)
        tags = params["tags"]
        match_all = get(params, "match_all", false)
        TextContent(text = "Filtering by $(length(tags)) tags (match_all=$match_all)")
    end
)
```

**Enum Parameters:**
```julia
sort_tool = MCPTool(
    name = "sort_results",
    description = "Sort results by field",
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

**Nested Objects:**
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

### Resources

#### `MCPResource`

Define a resource that provides data.

```julia
MCPResource(;
    uri::Union{String, URI},              # Resource identifier
    name::String = "",                    # Human-readable name
    description::String = "",             # Description
    mime_type::String = "application/json", # MIME type
    data_provider::Function,              # () -> data function (see note below)
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}(),  # Metadata (LittleDict for performance)
    title::Union{String,Nothing} = nothing,           # Optional display name
    icons::Union{Vector{MCPIcon},Nothing} = nothing,  # Optional icons (resources/list)
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Protocol-extension metadata (resources/list)
)
```

**Note:** The `uri` is stored internally as a `URI` object but accepts strings for convenience.

**Provider return values** (`resources/read` contents):
- `TextResourceContents` / `BlobResourceContents` (or a `Vector` of them): serialized
  directly — `BlobResourceContents` is how binary resources are served (base64 `blob`)
- `String`: used as the text verbatim with the resource's `mime_type`
- anything else: JSON-encoded into a text contents entry

**URI templates** (`ResourceTemplate`): parameterized resource families. RFC 6570
level-1 `{var}` placeholders (one path segment each); advertised via
`resources/templates/list`; a `resources/read` with no exact-URI match routes to the
first matching template's provider — `provider(uri)` or `provider(uri, vars)` for the
extracted placeholders, same return contract as above. Register via
`mcp_server(resource_templates = [...])` or `register!(server, template)`.

```julia
tmpl = ResourceTemplate(
    name = "artifact",
    uri_template = "app://artifact/{id}",
    mime_type = "image/png",
    data_provider = (uri, vars) -> BlobResourceContents(
        uri = uri, mime_type = "image/png", blob = load_artifact(vars["id"]))
)
```

```julia
# Binary resource
logo = MCPResource(
    uri = "images://logo",
    name = "Logo",
    mime_type = "image/png",
    data_provider = () -> BlobResourceContents(
        uri = "images://logo", mime_type = "image/png", blob = read("logo.png"))
)
```

#### `ResourceTemplate`

Templates for dynamic resources.

```julia
ResourceTemplate(;
    name::String,                       # Template name
    uri_template::String,               # RFC 6570 level-1 pattern, e.g. "user://{user_id}/profile"
    mime_type::Union{String,Nothing} = nothing,  # MIME type shared by all matching resources
    description::String = "",
    title::Union{String,Nothing} = nothing,           # Optional display name
    icons::Union{Vector{MCPIcon},Nothing} = nothing,  # Optional icons
    data_provider::Union{Function,Nothing} = nothing, # provider(uri) or provider(uri, vars);
                                        # templates without one are advertised but not readable
    _meta::Union{Nothing,Dict{String,Any}} = nothing, # Protocol-extension metadata
    completions::Union{Nothing,Dict{String,Any}} = nothing  # completion/complete sources per {var}
)
```

**Example:**

```julia
using Dates  # Required for now()

# Static resource with dynamic data
data_resource = MCPResource(
    uri = "data://metrics",
    name = "System Metrics",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "cpu" => 45.2,
        "memory" => 8192,
        "timestamp" => now()
    )
)

# Dynamic resource template with placeholders
template = ResourceTemplate(
    name = "User Profile Template",
    uri_template = "user://{user_id}/profile",
    mime_type = "application/json",
    description = "Template for accessing user profiles by ID"
)
```

### Prompts

#### `MCPPrompt`

Define prompt templates.

```julia
MCPPrompt(;
    name::String,                              # Identifier
    description::String = "",                  # Description
    arguments::Vector{PromptArgument} = [],    # Arguments
    messages::Vector{PromptMessage} = [],      # Messages
    title::Union{String,Nothing} = nothing,           # Optional display name
    icons::Union{Vector{MCPIcon},Nothing} = nothing,  # Optional icons (prompts/list)
    _meta::Union{Nothing,Dict{String,Any}} = nothing, # Protocol-extension metadata (prompts/list)
    completions::Union{Nothing,Dict{String,Any}} = nothing  # completion/complete sources per argument
)
```

**Argument completion** (`completion/complete`, both eras): map an argument name
to a `Vector{String}` (served filtered by prefix against the partial value) or a
function `value -> values` / `(value, context_args) -> values` — `context_args`
carries the request's already-resolved arguments. Values cap at the spec's 100
per response (`total`/`hasMore` report the rest). The same field exists on
`ResourceTemplate` for URI-template variables. The `completions` capability is
advertised by default; components without sources serve empty lists.

```julia
prompt = MCPPrompt(
    name = "city_report",
    arguments = [PromptArgument(name = "city", required = true)],
    messages = [PromptMessage(content = TextContent(text = "Report for {city}"))],
    completions = Dict{String,Any}("city" => ["paris", "london", "tokyo"])
)
```

#### `PromptArgument`

Prompt input arguments.

```julia
PromptArgument(;
    name::String,                    # Argument name
    description::String = "",        # Description
    required::Bool = false,          # Whether required
    title::Union{String,Nothing} = nothing  # Optional human-friendly display name
)
```

**Dynamic Prompt Example:**

```julia
# Prompt with error handling and validation
validated_prompt = MCPPrompt(
    name = "sql_query",
    description = "Generate SQL query with validation",
    arguments = [
        PromptArgument(
            name = "table",
            description = "Table name",
            required = true
        ),
        PromptArgument(
            name = "columns",
            description = "Comma-separated column names",
            required = false
        )
    ],
    messages = [
        PromptMessage(
            content = TextContent(
                text = "Generate a SELECT query for table {table} with columns {columns}."
            ),
            role = user
        )
    ]
)

# Using the prompt (conceptual - actual usage depends on client)
function apply_prompt(prompt::MCPPrompt, args::Dict)
    # Validate required arguments
    for arg in prompt.arguments
        if arg.required && !haskey(args, arg.name)
            error("Missing required argument: $(arg.name)")
        end
    end
    
    # Apply arguments to messages
    # ... template replacement logic ...
end
```

#### `PromptMessage`

Messages in prompts.

```julia
PromptMessage(;
    # Any of the spec's prompt-message content blocks:
    content::Union{TextContent, ImageContent, AudioContent, ResourceLink, EmbeddedResource},
    role::Role = user                           # Role (user or assistant)
)
```

A single-argument positional form is also available: `PromptMessage(content)` (role
defaults to `user`).

**Note:** The `Role` enum has values `user` and `assistant`. When creating a `PromptMessage`, the role defaults to `user` if not specified.

```julia
# Using the Role enum (requires explicit import)
using ModelContextProtocol: user, assistant  # Import role constants explicitly

message_user = PromptMessage(
    content = TextContent(text = "User message"),
    role = user  # Explicit user role
)

message_assistant = PromptMessage(
    content = TextContent(text = "Assistant response"),
    role = assistant  # Assistant role
)
```

**Example:**

```julia
analysis_prompt = MCPPrompt(
    name = "analyze_code",
    description = "Code review prompt",
    arguments = [
        PromptArgument(
            name = "language",
            required = true,
            description = "Programming language"
        )
    ],
    messages = [
        PromptMessage(
            content = TextContent(text = "Review this {language} code:")
        )
    ]
)
```

### Icons

#### `MCPIcon`

Icon metadata for the `icons` field of tools, resources, resource templates, prompts,
and the server itself. Field names are the wire names (they serialize verbatim,
omitting `nothing` fields).

```julia
MCPIcon(;
    src::String,                                  # http/https URL or data: URI
    mimeType::Union{String,Nothing} = nothing,    # e.g. "image/png", "image/svg+xml"
    sizes::Union{Vector{String},Nothing} = nothing,  # size hints, e.g. ["48x48", "any"]
    theme::Union{String,Nothing} = nothing        # background the icon is designed for: "light" | "dark"
)
```

```julia
tool = MCPTool(
    name = "chart",
    description = "Render a chart",
    parameters = [],
    handler = (p) -> TextContent(text = "ok"),
    icons = [MCPIcon(src = "https://example.com/chart.png",
                     mimeType = "image/png", sizes = ["48x48"], theme = "light")]
)
```

The `icons` field is emitted whenever it is set — on `tools/list`, `resources/list`,
`resources/templates/list`, `prompts/list`, and `serverInfo` — and omitted when
`nothing`. Icon metadata entered the spec in `2025-11-25`; older clients ignore the
field. To branch on it yourself, gate with `supports(version, :icon_metadata)`.

## Content Types

### Basic Content

#### `TextContent`

```julia
TextContent(;
    type::String = "text",                # Content type identifier (always "text")
    text::String,                          # Text content
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

#### `ImageContent`

```julia
ImageContent(;
    type::String = "image",               # Content type identifier (always "image")
    data::Vector{UInt8},                   # Raw binary data (NOT base64)
    mime_type::String,                     # e.g., "image/png"
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

**Important:** Pass raw bytes, not base64. Encoding happens automatically during serialization.

#### `AudioContent`

```julia
AudioContent(;
    type::String = "audio",               # Content type identifier (always "audio")
    data::Vector{UInt8},                   # Raw audio data (NOT base64)
    mime_type::String,                     # e.g., "audio/wav"
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

Available for clients speaking protocol `2025-03-26` or later.

### Advanced Content

#### `EmbeddedResource`

```julia
EmbeddedResource(;
    type::String = "resource",            # Content type identifier (always "resource")
    resource::Dict{String,Any},           # The embedded resource data
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

#### `ResourceLink`

```julia
ResourceLink(;
    type::String = "resource_link",       # Content type identifier (always "resource_link")
    uri::String,                           # URI of the linked resource
    name::String,                          # Name of the resource (required)
    description::Union{String,Nothing} = nothing,  # Optional description
    mime_type::Union{String,Nothing} = nothing,    # Optional MIME type (serialized as mimeType)
    size::Union{Int,Nothing} = nothing,    # Optional resource size in bytes
    title::Union{String,Nothing} = nothing,  # Optional human-readable title
    annotations::Union{Nothing,Dict{String,Any}} = nothing,  # Optional annotations
    _meta::Union{Nothing,Dict{String,Any}} = nothing  # Optional metadata
)
```

Serialized per the MCP spec as `{"type": "resource_link", "uri": ..., "name": ..., ...}`.

### Resource Contents

#### `TextResourceContents`

```julia
# Note: URI field accepts strings which auto-convert to URI internally
TextResourceContents(;
    uri::URI,                             # Resource URI (accepts strings, stored as URI)
    mime_type::String = "text/plain",     # MIME type of the text content
    text::String                          # Text content
)
```

#### `BlobResourceContents`

```julia
# Note: URI field accepts strings which auto-convert to URI internally
BlobResourceContents(;
    uri::URI,                             # Resource URI (accepts strings, stored as URI)
    mime_type::String = "application/octet-stream",  # MIME type of the binary content
    blob::Vector{UInt8}                   # Binary data
)
```

## Control Types

### `CallToolResult`

Return explicit results or errors from tool handlers.

```julia
CallToolResult(;
    content::Vector{Dict{String,Any}},    # Serialized content dicts
    is_error::Bool = false,               # Whether this is an error (serialized as "isError")
    structured_content::Union{Nothing,AbstractDict} = nothing,  # Structured output matching the tool's output_schema (serialized as "structuredContent")
    _meta::Union{Nothing,AbstractDict} = nothing  # Optional result metadata
)
```

**Note:** `content` accepts pre-serialized dictionaries or `Content` objects —
the latter are converted automatically (`Base.convert(Dict{String,Any}, ::Content)`).

**Example:**

```julia
file_tool = MCPTool(
    name = "read_file",
    description = "Read file contents",
    parameters = [
        ToolParameter(
            name = "path", 
            type = "string", 
            description = "Path to list files from",
            required = true
        )
    ],
    handler = function(params)
        path = params["path"]
        if !isfile(path)
            # Return error result
            return CallToolResult(
                content = [Dict(
                    "type" => "text",
                    "text" => "File not found: $path"
                )],
                is_error = true
            )
        end
        # Normal return
        TextContent(text = read(path, String))
    end
)
```

## Tasks

Tasks run a tool call in the background so a long handler does not hold the serial
server loop. Both eras support them, with different wire shapes and different opt-in
rules — a tool opts in once via `MCPTool(task_support = ...)` and works with either.

### Legacy era (SEP-1686, experimental)

MCP Tasks (SEP-1686, protocol 2025-11-25) run tool calls in the background: a
task-augmented `tools/call` (params carry `"task": {"ttl": …}`) immediately returns a
task handle, the handler executes in a background Julia task, and the client polls
`tasks/get`, retrieves the payload with `tasks/result` (blocks until terminal, then
returns exactly what the call would have returned), cancels with `tasks/cancel`, and
enumerates with `tasks/list` (cursor-paginated).

```julia
# Opt a tool into task execution
long_tool = MCPTool(
    name = "long_job",
    description = "Expensive computation",
    parameters = [],
    handler = (args, ctx) -> begin
        for i in 1:100
            task_cancelled(ctx) && return TextContent(text = "stopped")  # cooperative cancel
            send_progress(ctx, i; total = 100)   # progressToken stays valid for the task
            # ... work ...
        end
        TextContent(text = "done")
    end,
    task_support = :optional    # :forbidden (default) | :optional | :required
)
```

**Semantics:**
- `task_support = :forbidden` (default): task-augmented calls rejected with `-32601`
- `:required`: synchronous calls rejected with `-32601`
- Advertised per tool as `execution.taskSupport` in `tools/list`; the `tasks`
  capability (`{"list":{},"cancel":{},"requests":{"tools":{"call":{}}}}`) is only
  advertised to clients that negotiated `2025-11-25` — older sessions get spec
  fallback (task metadata ignored, synchronous execution)
- Tool `isError` results and handler exceptions map to task status `failed`;
  `tasks/result` still returns the underlying payload or JSON-RPC error verbatim
  (plus the `io.modelcontextprotocol/related-task` `_meta` key)
- Cancelling a terminal task → `-32602`; a cancelled task stays cancelled (late
  results are discarded); blocked `tasks/result` requests wake on cancel
- TTL: requested per call, clamped to a 1-hour server max (default 5 minutes);
  expired terminal tasks are swept; unknown/expired/foreign task ids → `-32602`
- Security: with HTTP auth enabled, tasks are bound to the authenticated principal;
  `tasks/list` is withheld on unauthenticated HTTP (requestors are unidentifiable);
  task ids are cryptographically random
- Optional `notifications/tasks/status` are emitted on terminal transitions (stdout
  for stdio, SSE stream for HTTP)

### Modern era (SEP-2663, tasks extension)

On modern-era (2026-07-28) requests the experimental surface above is replaced by
the `io.modelcontextprotocol/tasks` extension. Creation is server-directed: the
client declares the extension in per-request `_meta`
`clientCapabilities.extensions`, and the tool handler decides — `task_detach(ctx)`
hands the running call off to a background task, immediately answering with a flat
`CreateTaskResult` (`resultType:"task"`, `ttlMs`/`pollIntervalMs`):

```julia
slow_tool = MCPTool(
    name = "slow_job",
    description = "Expensive computation",
    parameters = [],
    handler = (args, ctx) -> begin
        task_detach(ctx)   # false (and the call just runs synchronously) when the
                           # client did not declare the tasks extension
        for i in 1:100
            task_cancelled(ctx) && return TextContent(text = "stopped")
            # ... work ...
        end
        TextContent(text = "done")
    end,
    task_support = :optional    # :required rejects non-declaring clients with -32021
)
```

After detaching, a handler can ask the client for input mid-task with
`task_await_input` — the task parks as `input_required`, `tasks/get` surfaces the
outstanding `inputRequests`, and the client answers via `tasks/update`
`inputResponses`:

```julia
confirming_tool = MCPTool(
    name = "confirm_delete",
    description = "Delete with confirmation",
    parameters = [ToolParameter(name = "filename", type = "string",
                                description = "File to delete", required = true)],
    handler = (args, ctx) -> begin
        task_detach(ctx)
        resp = task_await_input(ctx, elicit_request("Really delete $(args["filename"])?"))
        # resp is the client's response value ({action, content, ...} for elicitation);
        # a vector of requests parks them all at once and returns responses in order
        TextContent(text = "done")
    end,
    task_support = :optional
)
```

**Semantics:**
- Clients poll `tasks/get` (terminal `result`/`error` inlined — no `tasks/result`);
  `tasks/cancel` is an idempotent empty ack (`-32602` only for unknown ids); a tool
  `isError` result **completes** the task (`failed` is reserved for JSON-RPC errors)
- `tasks/get`/`tasks/update`/`tasks/cancel` without the declared extension →
  `-32021` with `data.requiredCapabilities`; `tasks/result`/`tasks/list` → `-32601`
- Returning `InputRequired` *before* detaching runs the normal MRTR round, so a tool
  can gather input synchronously and then escalate to a task (SEP-2663 composition)
- `task_await_input(ctx, request_or_vector)`: requests built with
  `elicit_request`/`sampling_request`/`roots_request`; keys are server-minted and
  never reused within a task; `tasks/update` may answer a subset (the task stays
  `input_required` until all outstanding requests are answered, then returns to
  `working`); not-outstanding keys are ignored; `tasks/cancel` unblocks the waiter
  by throwing `TaskCancelledException` into the handler; requires the creating
  request to have declared the matching client capability (e.g. `elicitation`);
  request params are frozen at registration (owned plain-JSON snapshot; exotic
  values are rejected); a task whose ttl elapses while parked is failed and drained
- Status pushes: `subscriptions/listen` with a `notifications.taskIds` filter
  delivers `notifications/tasks` (a complete DetailedTask, like `tasks/get`) on
  every transition of the subscribed ids; the ack echoes only ids the requestor
  could `tasks/get`, and requesting `taskIds` without the declared extension is
  `-32021`
- Extension tasks and legacy (SEP-1686) tasks share one era-tagged store — neither
  era can see the other's records; on HTTP, `Mcp-Name` must mirror `params.taskId`
  for `tasks/*` requests

**Handler-side API:**

```julia
task_detach(ctx; ttl_ms = nothing, status_message = nothing) -> Bool
# true once the call is task-detached; false (run synchronously) for a legacy-era
# request, a client that did not declare the extension, or a tool that is not
# task-capable. Idempotent — a second call returns true without creating a task.

task_await_input(ctx, request) -> Any
task_await_input(ctx, requests::AbstractVector) -> Vector{Any}
# Requests are built with elicit_request / sampling_request / roots_request (their
# common type, ModelContextProtocol.InputRequest, is internal and not exported)
# Park a detached task on client input; returns the client's response value(s), in
# request order for the vector form. Throws TaskCancelledException if the task
# reaches a terminal state while waiting (client `tasks/cancel`, or ttl expiry —
# `task_cancelled(ctx)` is true only for the former).

task_cancelled(ctx) -> Bool   # cooperative cancellation check, both eras
```

## MRTR (client input from handlers, modern era)

Multi-Round-Trip Requests (SEP-2322) are how a modern-era (`2026-07-28`) tool handler
asks the client for elicitation, sampling, or filesystem roots. There is no
server-initiated request: the handler *returns* an `InputRequired`, the server answers
the call with an `input_required` result, and the client **retries the same call** with
its responses attached. The handler then runs again from the top and reads the answers.
This works on the serial server loop and over stateless HTTP, which is why it replaces
the legacy server-initiated surface.

```julia
InputRequired(requests::AbstractDict; state = nothing)
# requests: your keys (strings) => InputRequest values; the client answers under the
#           same keys. At least one request, or a state, is required.
# state:    JSON-serializable handler state carried to the retry inside the
#           integrity-protected `requestState`. Signed, NOT encrypted — no secrets.

elicit_request(message::String; requested_schema = nothing) -> InputRequest
# `elicitation/create`. requested_schema must be an object schema; when omitted a
# minimal {"type":"object","properties":{}} is synthesized (the wire field is required).

sampling_request(params::AbstractDict) -> InputRequest
# `sampling/createMessage`; params is the CreateMessageRequest params (messages, maxTokens, ...)

roots_request() -> InputRequest
# `roots/list`

input_responses(ctx) -> Dict{String,Any}  # the retry's responses, keyed as you asked; empty on a first call
input_state(ctx) -> Any                   # whatever you passed as `state`; nothing on a first call
```

`state` round-trips through JSON inside `requestState`, so it comes back **parsed**, not
as the original Julia object: a `Dict` returns as a `JSON3.Object` (index it with
`st["key"]` or `st.key`), a vector as a `JSON3.Array`. Keep it to plain JSON data.

```julia
confirm_tool = MCPTool(
    name = "publish",
    description = "Publish a draft after confirming with the user",
    parameters = [ToolParameter(name = "draft_id", type = "string",
                                description = "Draft to publish", required = true)],
    handler = (args, ctx) -> begin
        answers = input_responses(ctx)
        if !haskey(answers, "confirm")
            # First call: ask, and carry any state the retry will need.
            return InputRequired(
                Dict("confirm" => elicit_request(
                    "Publish draft $(args["draft_id"])?";
                    requested_schema = Dict(
                        "type" => "object",
                        "properties" => Dict("ok" => Dict("type" => "boolean")),
                        "required" => ["ok"]))),
                state = Dict("draft" => args["draft_id"]))
        end
        # Retry: the handler re-runs from the top with the answer available.
        draft = input_state(ctx)["draft"]   # JSON3.Object — see note above
        TextContent(text = "published $draft: $(answers["confirm"])")
    end
)
```

**Semantics:**
- Returned from **tool handlers**, on modern-era requests. A legacy session has no wire
  shape for `InputRequired`, so returning one there is an error. (The retry fields
  `inputResponses`/`requestState` are parsed on all three MRTR methods — `tools/call`,
  `resources/read`, `prompts/get` — but only tool handlers produce `InputRequired`.)
- Inside a **legacy** task-augmented execution `InputRequired` is not representable and
  fails the task; the modern equivalent after detaching is `task_await_input`
- Each request type needs the matching client capability declared in the request's
  `_meta` (`elicitation`, `sampling`, `roots`); undeclared → `-32021` with
  `data.requiredCapabilities`
- `requestState` is attacker-controlled input, so it is HMAC-signed over the issue
  time, a TTL (10 minutes), the authenticated principal, and a canonical digest of the
  original params; every retry verifies all of them before the handler runs. The key
  is per-`Server` and ephemeral unless you pass `mcp_server(mrtr_state_key = ...)`
- A valid `requestState` can be **replayed** within its TTL (one-time semantics would
  need shared server state, which the stateless design avoids) — keep handlers
  idempotent across retries
- If a needed response is still missing on the retry, return another `InputRequired`;
  the spec says re-issue, not error
- Returning `InputRequired` *before* `task_detach(ctx)` composes the two: gather input
  synchronously, then escalate to a task. After detaching, use
  [`task_await_input`](#modern-era-sep-2663-tasks-extension) instead

## Transport Types

### `StdioTransport`

Standard input/output transport (default).

```julia
StdioTransport(;
    input::IO = stdin,
    output::IO = stdout
)
```

### `HttpTransport`

HTTP transport with Server-Sent Events support.

```julia
HttpTransport(;
    host::String = "127.0.0.1",          # Bind address
    port::Int = 8080,                    # Port number
    endpoint::String = "/",              # Endpoint path
    allowed_origins::Vector{String} = String[],  # Extra Origins accepted by the DNS-rebinding guard
    allowed_hosts::Vector{String} = String[],    # Extra Host hostnames accepted by the guard (e.g. reverse-proxy domain)
    protocol_version::String = LATEST_PROTOCOL_VERSION,  # "2025-11-25"; response headers echo the per-session negotiated version
    session_required::Bool = false,      # Require session validation
    auth::Union{AuthMiddleware,Nothing} = nothing,  # OAuth Resource Server token validation (nothing = disabled)
    resource_metadata::Union{ProtectedResourceMetadata,Nothing} = nothing,  # RFC 9728 Protected Resource Metadata
    sse_keepalive_secs::Real = 15.0      # Idle interval between SSE keepalive comments. A write is
                                         # the only way to notice a silently-dead peer, so the value
                                         # must be finite and positive (ArgumentError otherwise)
)
```

Loopback-bound transports without auth reject non-local `Host`/`Origin` headers with
403 (DNS-rebinding protection); requests that emit notifications during handling
(progress, log messages) receive them on the POST's SSE response stream, ahead of the
final response — quiet requests get plain JSON.

**Critical HTTP Transport Notes:**
1. Always call `connect(transport)` before `start!(server)`
2. Server blocks on `start!` and runs until interrupted
3. Use `127.0.0.1` instead of `localhost` on Windows

**Example:**

```julia
# Create transport and server
transport = HttpTransport(port = 3000)

# Define tools first
tools = [
    MCPTool(name = "tool1", description = "Tool 1", parameters = [], handler = (p) -> TextContent(text = "Result 1")),
    MCPTool(name = "tool2", description = "Tool 2", parameters = [], handler = (p) -> TextContent(text = "Result 2"))
]

server = mcp_server(
    name = "http-server",
    version = "1.0.0",  # Your server version
    tools = tools
)

# Connect first (binds port)
connect(transport)

# Start server with transport (blocks here). `transport` is keyword-only.
start!(server, transport = transport)  # Server runs until Ctrl+C
```

## Authentication (OAuth Resource Server)

**Scope of this implementation.** The package is an OAuth 2.1 **Resource Server**: it
validates bearer tokens on incoming HTTP requests, advertises where those tokens come
from (RFC 9728), and hands the authenticated principal to your handlers. It is **not an
Authorization Server** — it does not issue tokens, run login or consent screens,
implement Dynamic Client Registration, or handle PKCE redirects. Those belong to an
external AS (Keycloak, Auth0, Okta, GitHub, an in-house IdP). The stdio transport is
unauthenticated by design: its trust boundary is the OS process pipe, not a token.
`docs/src/oauth.md` covers deployment in depth.

### Wiring it up

```julia
using ModelContextProtocol

auth = create_auth_middleware(
    OAuthConfig(
        issuer = "https://auth.example.org/realms/main",   # expected `iss`
        audience = "https://mcp.example.org/mcp",          # expected `aud`
        required_scopes = ["mcp:read"],                    # required on every request
    ),
    validator = JWKSValidator("https://auth.example.org/realms/main/protocol/openid-connect/certs"),
    allowlist = Set(["alice", "bob"]),                     # optional
)

meta = create_protected_resource_metadata(
    "https://mcp.example.org/mcp",
    ["https://auth.example.org/realms/main"],
    scopes = ["mcp:read", "mcp:write"],
)

transport = HttpTransport(port = 8765, auth = auth, resource_metadata = meta)
connect(transport)
start!(server, transport = transport)
```

Each request is authenticated before dispatch: a missing or malformed `Authorization`
header is `401`, an invalid/expired/forged token is `401`, and a valid token that lacks
a required scope or is not allowlisted is `403`. Failures never reveal *why* a token was
rejected (the endpoint must not work as a token oracle). On success the principal is
available to context-aware handlers as `ctx.authenticated_user`.

### Configuration and result types

```julia
OAuthConfig(;
    issuer::String,                            # expected `iss` claim
    audience::String,                          # expected `aud` claim — typically your server URL
    required_scopes::Vector{String} = String[],           # scopes required on every request
    jwks_uri::Union{String,Nothing} = nothing,            # JWKS URL for JWT validation
    introspection_endpoint::Union{String,Nothing} = nothing  # RFC 7662 endpoint
)

AuthenticatedUser(;
    subject::String,                           # `sub` — the stable principal id
    provider::String,                          # e.g. "github", "keycloak"
    username::Union{String,Nothing} = nothing, # human-readable name when available
    scopes::Vector{String} = String[],         # granted OAuth scopes
    claims::Dict{String,Any} = Dict{String,Any}()  # raw token claims
)

AuthMiddleware(;
    config::OAuthConfig,
    validator::TokenValidator,
    allowlist::Union{Set{String},Nothing} = nothing,  # allowed usernames or subjects
    case_insensitive_allowlist::Bool = true,          # username matching only; `subject` is
                                                      # ALWAYS matched exactly
    enabled::Bool = true
)

ProtectedResourceMetadata(;
    resource::String,                                    # your server URL
    authorization_servers::Vector{String},               # AS issuer URLs
    scopes_supported::Vector{String} = String[],
    bearer_methods_supported::Vector{String} = ["header"]
)
```

`AuthResult` is the outcome of an authentication attempt: fields `success::Bool`,
`user::Union{AuthenticatedUser,Nothing}`, `error::Union{String,Nothing}`, and
`error_code::Union{Symbol,Nothing}` (`:invalid_token`, `:missing_token`,
`:invalid_format`, `:insufficient_scope`, …). Construct with `AuthResult(user)` for
success or `AuthResult(message, code)` for failure.

`AuthProvider` and `TokenValidator` are the exported abstract types: subtype
`TokenValidator` and add a `validate_token(::YourValidator, ::AbstractString, ::OAuthConfig)`
method to plug in your own strategy.

### The validator ladder

```julia
JWKSValidator(jwks_uri::String;
    allowed_algs::Vector{String} = ["RS256", "RS384", "RS512"],
    clock_skew_seconds::Int = 60,
    refresh_interval_seconds::Real = 300,
    allow_insecure_http::Bool = false)
JWKSValidator(keyset::JWTs.JWKSet; kwargs...)   # pre-built/static key set
```

**Preferred.** Verifies the JWT signature against a JSON Web Key Set (RFC 7517) *and*
validates claims. Keys are fetched lazily, so construction never touches the network; an
unknown `kid` triggers a re-fetch at most once per `refresh_interval_seconds` (rate
limited so an attacker-supplied `kid` cannot hammer the JWKS endpoint). Tokens whose
header `alg` is outside `allowed_algs` are rejected before any cryptography runs (this
rejects `alg=none`). `file://` URIs work for local key sets; an `http://` URL throws at
construction unless `allow_insecure_http = true`.

```julia
JWTValidator(; insecure_skip_signature_verification::Bool = false,
               clock_skew_seconds::Int = 60)
```

Claims only (`iss`, `aud`, `exp`, `nbf`, scopes) — **no signature verification**, so any
caller could forge the issuer, audience, and scopes. The constructor **throws** unless
you pass `insecure_skip_signature_verification = true`, an explicit acknowledgement.
Choose it only when this server sits behind a gateway that has already verified the
signature.

```julia
IntrospectionValidator(; client_id = nothing, client_secret = nothing)
```

RFC 7662 remote introspection — for opaque tokens that cannot be validated locally.
Requires `OAuthConfig(introspection_endpoint = ...)`.

```julia
GitHubOAuthValidator(; cache_ttl_seconds::Int = 300)
SimpleTokenValidator()   # also SimpleTokenValidator(::Dict{String,AuthenticatedUser})
```

`GitHubOAuthValidator` validates GitHub tokens against the GitHub API (with a TTL
cache). `SimpleTokenValidator` is a static in-memory token map — plaintext storage and
non-constant-time lookups, so it is for development and trusted static API keys only.

### Middleware factories

```julia
create_auth_middleware(config::OAuthConfig;
    validator::TokenValidator,                         # required — no implicit default
    allowlist::Union{Set{String},Nothing} = nothing,
    case_insensitive_allowlist::Bool = true,
    enabled::Bool = true) -> AuthMiddleware

create_simple_auth(tokens::Dict{String,String};        # API key => username
    allowlist::Union{Set{String},Nothing} = nothing,
    case_insensitive_allowlist::Bool = true) -> AuthMiddleware

create_github_auth(;
    allowed_users::Union{Vector{String},Set{String}} = String[],  # empty = any authenticated user
    required_org::Union{String,Nothing} = nothing,     # require org membership
    cache_ttl_seconds::Int = 300,
    case_insensitive_allowlist::Bool = true) -> AuthMiddleware

disable_auth() -> AuthMiddleware                       # dev/testing: everything passes as anonymous
```

### Metadata helpers (RFC 9728)

```julia
create_protected_resource_metadata(resource_url::String,
                                   authorization_servers::Vector{String};
                                   scopes::Vector{String} = String[]) -> ProtectedResourceMetadata

create_github_resource_metadata(resource_url::String;
                                scopes::Vector{String} = ["read:user"]) -> ProtectedResourceMetadata
```

Passing the result as `HttpTransport(resource_metadata = ...)` serves it at
`/.well-known/oauth-protected-resource` and points `WWW-Authenticate` at it, which is
how a compliant client discovers your Authorization Server.

### Request-level helpers

```julia
authenticate_request(middleware::AuthMiddleware,
                     authorization_header::Union{String,Nothing}) -> AuthResult
validate_token(validator::TokenValidator, token::AbstractString,
               config::OAuthConfig) -> AuthResult
extract_bearer_token(authorization_header::String) -> Union{String,Nothing}
clear_cache!(validator)          # drop a GitHub validator's cached user lookups
is_auth_enabled(transport::HttpTransport) -> Bool
```

The transport calls these for you; reach for them directly in tests, in custom
validators, or when you need to check whether a transport is protected (a loopback
transport *without* auth also enables the DNS-rebinding guard).

### Per-tool authorization

Beyond the server-wide `OAuthConfig(required_scopes = ...)`, a single tool can demand
its own scopes:

```julia
delete_tool = MCPTool(
    name = "delete_record",
    description = "Delete a record",
    parameters = [ToolParameter(name = "id", type = "string",
                                description = "Record id", required = true)],
    handler = (args, ctx) -> TextContent(text = "deleted $(args["id"])"),
    required_scopes = ["records:write"]
)
```

Every listed scope must be present on `ctx.authenticated_user.scopes` or the call is
refused. The check runs only when the request carries an authenticated principal: with
no auth configured there is no principal, and the server performs no authorization.

## Auto-Registration System

Automatically discover and load components from a directory structure.

**Path Resolution:** Relative paths provided to `auto_register_dir` are resolved relative to the project root directory.

```
components/
├── tools/
│   ├── calculator.jl    # Define MCPTool objects
│   └── file_ops.jl
├── resources/
│   └── data.jl         # Define MCPResource objects
└── prompts/
    └── templates.jl     # Define MCPPrompt objects
```

**Component File Requirements:**
- Each `.jl` file is loaded in an isolated module
- Exactly one component per file, as the file's **final expression** — the loader
  registers only the value the file evaluates to; anything defined earlier is a
  helper and is silently dropped
- The final expression's type must match the directory (`MCPTool` under `tools/`, etc.)

**Example component files** (one tool each):

```julia
# tools/add.jl
MCPTool(
    name = "add",
    description = "Add two numbers",
    parameters = [
        ToolParameter(name = "a", type = "number", description = "First addend", required = true),
        ToolParameter(name = "b", type = "number", description = "Second addend", required = true)
    ],
    handler = (p) -> TextContent(text = string(p["a"] + p["b"]))
)
```

```julia
# tools/multiply.jl
MCPTool(
    name = "multiply",
    description = "Multiply two numbers",
    parameters = [
        ToolParameter(name = "x", type = "number", description = "First factor", required = true),
        ToolParameter(name = "y", type = "number", description = "Second factor", required = true)
    ],
    handler = (p) -> TextContent(text = string(p["x"] * p["y"]))
)
```

**Usage:**

```julia
server = mcp_server(
    name = "auto-server",
    version = "1.0.0",  # Your server version
    auto_register_dir = "components"
)
start!(server)
```

## Multi-Content Responses

Tools can return multiple content items of different types:

```julia
analysis_tool = MCPTool(
    name = "analyze",
    description = "Analyze with text and visuals",
    parameters = [],  # Required field, use empty array for no parameters
    handler = function(params)
        # Example: generate chart data (in practice, use your chart library)
        chart_data = UInt8[0x89, 0x50, 0x4E, 0x47]  # PNG header bytes
        
        # Return multiple content types
        return [
            TextContent(text = "Analysis complete"),
            ImageContent(
                data = chart_data,  # Must be Vector{UInt8}
                mime_type = "image/png"
            ),
            TextContent(text = "See chart above")
        ]
    end
)
```

## Utility Functions

### `content2dict(content::Content) -> Dict{String,Any}`

Convert Content objects to dictionary representation for JSON serialization.

```julia
# Text content
text = TextContent(text = "Hello")
dict = content2dict(text)
# Returns: Dict("type" => "text", "text" => "Hello")

# Image (automatically base64 encodes)
image = ImageContent(data = [0x89, 0x50], mime_type = "image/png")
dict = content2dict(image)
# Returns: Dict("type" => "image", "data" => "iVA=", "mimeType" => "image/png")

# Resource link (uri and name are both required)
link = ResourceLink(uri = "resource://data", name = "data", title = "Data Resource")
dict = content2dict(link)
# Returns: Dict("type" => "resource_link", "uri" => "resource://data",
#               "name" => "data", "title" => "Data Resource")

# Embedded resource
embedded = EmbeddedResource(
    resource = Dict(
        "uri" => "resource://text",
        "text" => "Content",
        "mimeType" => "text/plain"
    )
)
dict = content2dict(embedded)
# Returns: Dict("type" => "resource", "resource" => Dict(...))
```

**Use cases:**
- Debugging content objects
- Custom serialization
- Building CallToolResult content
- Testing and validation

## Advanced Features

### Progress Notifications

A context-aware handler reports progress on a long operation with `send_progress`,
which emits `notifications/progress` on the transport-appropriate channel: stdout
for stdio; on HTTP, a synchronous handler's notifications ride the calling
request's own POST SSE stream, while a legacy background-task execution (which has
no request route) falls back to the standalone GET SSE notification stream.

```julia
send_progress(ctx, progress::Real; total = nothing, message = nothing) -> Bool
```

- `ctx` is the second argument of a two-arg tool handler, `(args, ctx) -> ...`
- Send an increasing `progress`; add `total` for a determinate bar and `message` for a
  status line
- Returns `false` and does nothing when the client sent no `progressToken`, when the
  server has no transport, or on a detachable modern-era task call (tasks do not carry
  progress notifications) — so it is always safe to call unconditionally. A `true`
  return means the notification was handed to the transport, not that the client
  received it (a disconnected HTTP peer drops it silently).

```julia
indexing_tool = MCPTool(
    name = "reindex",
    description = "Rebuild the search index",
    parameters = [],
    handler = (args, ctx) -> begin
        files = collect_files()
        for (i, f) in enumerate(files)
            send_progress(ctx, i; total = length(files), message = "indexing $f")
            index!(f)
        end
        TextContent(text = "indexed $(length(files)) files")
    end
)
```

### Resource Subscriptions

Modern-era clients subscribe by opening a `subscriptions/listen` stream, which replaces
both the legacy GET stream and `resources/subscribe`. Your code announces changes with
two exported helpers; each returns how many open streams were notified.

```julia
notify_resource_updated(server::Server, uri::AbstractString) -> Int
# Deliver notifications/resources/updated to every listen stream subscribed to that URI

notify_list_changed(server::Server, kind::Symbol) -> Int
# kind ∈ (:tools, :prompts, :resources) — deliver notifications/{kind}/list_changed.
# Call after mutating server.tools / server.prompts / server.resources at runtime.
# Any other symbol throws ArgumentError.
```

```julia
# After the underlying data changes:
update_metrics!()
notify_resource_updated(server, "data://metrics")

# After registering a tool at runtime:
register!(server, new_tool)
notify_list_changed(server, :tools)
```

Both helpers target `subscriptions/listen` streams. Only streams open at the moment of
the change are notified — there is no backlog — and `notify_list_changed` delivers only
when the corresponding `listChanged` capability is declared.

Legacy sessions have `resources/subscribe` / `resources/unsubscribe`, which record the
URI in the session's wire-subscription set and acknowledge with an empty result (both
are idempotent).

`subscribe!` / `unsubscribe!` are a third, **in-process** path: they attach a Julia
callback to a URI on the server, for server-side code that wants to react to changes.
They do not by themselves put anything on the wire.

```julia
subscribe!(server, "resource://data", callback)    # callback is any Function
unsubscribe!(server, "resource://data", callback)  # removed by identity (===)
```

### Session Management (HTTP)

HTTP transport supports session management:
```julia
transport = HttpTransport(
    port = 3000,
    session_required = true  # Require session validation
)
```

Clients receive session ID in `Mcp-Session-Id` header after initialization.

## Common Patterns

### HTTP Server Setup

```julia
using ModelContextProtocol

# Define your tools
echo_tool = MCPTool(
    name = "echo",
    description = "Echo message",
    parameters = [
        ToolParameter(name = "msg", type = "string", description = "Message to echo back", required = true)
    ],
    handler = (p) -> TextContent(text = p["msg"])
)

status_tool = MCPTool(
    name = "status",
    description = "Get server status",
    parameters = [],
    handler = function(params)
        # Return multiple content items
        return [
            TextContent(text = "Server Status: Online"),
            TextContent(text = "Time: $(Dates.now())"),
            TextContent(text = "Version: 1.0.0")
        ]
    end
)

# Create server with tools
server = mcp_server(
    name = "http-example",
    version = "1.0.0",  # Your server version
    tools = [echo_tool, status_tool]
)

# Setup HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",  # Use IP on Windows
    port = 3000,
    session_required = false  # Set to true for session validation
)

# Connect and start
connect(transport)  # Must come first for HTTP
println("Server running on http://127.0.0.1:3000")
start!(server, transport = transport)  # Blocks until interrupted
```

### Stdio Server Setup

```julia
using ModelContextProtocol

# Create server with the same tools defined earlier
server = mcp_server(
    name = "stdio-example",
    version = "1.0.0",
    tools = [echo_tool, status_tool]  # Tools from HTTP example above
)

# For stdio, just call start! (no transport setup needed)
start!(server)  # Uses StdioTransport() by default
# Or explicitly:
start!(server, transport = StdioTransport())
```

### Error Handling

```julia
safe_tool = MCPTool(
    name = "safe_op",
    description = "Perform operation with error handling",
    parameters = [
        ToolParameter(name = "input", type = "string", description = "Value to operate on", required = true)
    ],
    handler = function(params)
        try
            result = risky_operation(params["input"])
            return TextContent(text = result)
        catch e
            return CallToolResult(
                content = [Dict(
                    "type" => "text",
                    "text" => "Error: $(string(e))"
                )],
                is_error = true
            )
        end
    end
)
```

### Working with Parameter Defaults

```julia
config_tool = MCPTool(
    name = "configure",
    description = "Configure settings with smart defaults",
    parameters = [
        ToolParameter(
            name = "timeout",
            type = "number",
            description = "Seconds before giving up",
            default = 30.0  # Applied when not provided
        ),
        ToolParameter(
            name = "retries",
            type = "integer",
            description = "Number of retry attempts",
            default = 3
        )
    ],
    handler = function(params)
        # Defaults are automatically applied
        timeout = params["timeout"]  # Will be 30.0 if not provided
        retries = params["retries"]  # Will be 3 if not provided
        TextContent(text = "Config: timeout=$timeout, retries=$retries")
    end
)
```

### Working with Resources

```julia
# Static resource with fixed data
static_resource = MCPResource(
    uri = "resource://config",
    name = "Configuration",
    mime_type = "application/json",
    data_provider = () -> Dict(
        "setting1" => "value1",
        "setting2" => "value2"
    )
)

# Dynamic resource with real-time data
using Dates
dynamic_resource = MCPResource(
    uri = "resource://metrics",
    name = "System Metrics",
    description = "Real-time system metrics",
    mime_type = "application/json",
    data_provider = function()
        # Called each time resource is accessed
        return Dict(
            "timestamp" => now(),
            "memory_free" => Sys.free_memory(),
            "cpu_threads" => Sys.CPU_THREADS,
            "julia_version" => VERSION
        )
    end
)

# File-based resource
file_resource = MCPResource(
    uri = "file://readme",
    name = "README",
    mime_type = "text/plain",
    data_provider = () -> read("README.md", String)
)

# Resource with annotations
# Resource with annotations (using LittleDict for performance)
using OrderedCollections: LittleDict
annotated_resource = MCPResource(
    uri = "resource://data",
    name = "Annotated Data",
    mime_type = "application/json",
    data_provider = () -> Dict("data" => [1, 2, 3]),
    annotations = LittleDict(
        "version" => "1.0",
        "author" => "System",
        "readonly" => true
    )
)
```

## Integration with Claude Desktop

### stdio Transport

Edit Claude Desktop config:

```json
{
  "mcpServers": {
    "my-julia-server": {
      "command": "julia",
      "args": ["--project=/path/to/project", "server.jl"]
    }
  }
}
```

### HTTP Transport

1. Start your HTTP server:
   ```bash
   julia --project my_http_server.jl
   ```

2. Configure Claude Desktop to connect:
   ```json
   {
     "mcpServers": {
       "my-http-server": {
         "command": "npx",
         "args": ["mcp-remote", "http://127.0.0.1:3000", "--allow-http"]
       }
     }
   }
   ```

**Note:** HTTP server must be running before Claude Desktop connects.

## Protocol Compliance and API Stability

### Protocol Version Support

ModelContextProtocol.jl is a dual-era server (details in
[Protocol Version Negotiation](#protocol-version-negotiation)):

- **Modern era**: `2026-07-28`, selected per request via the `_meta` key
  `io.modelcontextprotocol/protocolVersion`. Stateless — no `initialize`, no session.
- **Legacy era**: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`, negotiated at
  `initialize`. If the client requests a supported version the server echoes it;
  otherwise it responds with `LATEST_PROTOCOL_VERSION` and the client decides (per spec).
- **Feature gating**: handlers gate with `supports(version, :feature)`, where
  `version` merges `ctx.protocol_version` (modern, per-request) with
  `ctx.state.protocol_version` (legacy, negotiated) — see the `supports` section
- **HTTP Header**: Streamable HTTP responses echo the session's negotiated version in
  `MCP-Protocol-Version`

### API Stability Guarantees

| Component | Stability | Notes |
|-----------|-----------|--------|
| Core Functions | Stable | `mcp_server`, `start!`, `register!` |
| Type Constructors | Stable | `MCPTool`, `MCPResource`, `MCPPrompt` |
| Content Types | Stable | `TextContent`, `ImageContent`, etc. |
| Transport APIs | Stable | `StdioTransport`, `HttpTransport` |
| Handler Signatures | Stable | `Dict{String,Any} -> Content` pattern; opt-in two-arg `(args, ctx)` form |
| Auto-registration | Stable | Directory-based component loading |
| Progress Monitoring | Stable | Context-aware handlers + `send_progress` |
| Resource Subscriptions | Implemented | `subscriptions/listen` + `notify_resource_updated` / `notify_list_changed` |
| Authentication | Stable | OAuth Resource Server; no Authorization Server |
| Tasks | Stable (modern) / Experimental (legacy) | SEP-2663 extension; SEP-1686 is experimental |
| MRTR | Stable (modern era only) | `InputRequired` + `input_responses` / `input_state` |

### Semantic Versioning

This package follows semantic versioning:
- **Major**: Breaking API changes
- **Minor**: New features, backward compatible
- **Patch**: Bug fixes, backward compatible

## Complete Example

```julia
#!/usr/bin/env julia
using ModelContextProtocol
using Dates  # Required for now() function

# Tool with defaults
time_tool = MCPTool(
    name = "get_time",
    description = "Get formatted time",
    parameters = [
        ToolParameter(
            name = "format",
            type = "string",
            description = "Time format",
            default = "HH:MM:SS"
        )
    ],
    handler = function(params)
        fmt = get(params, "format", "HH:MM:SS")
        return TextContent(text = Dates.format(now(), fmt))
    end
)

# Tool with error handling
calc_tool = MCPTool(
    name = "calculate",
    description = "Safe calculator",
    parameters = [
        ToolParameter(
            name = "expr",
            type = "string",
            description = "Expression to calculate",
            required = true
        )
    ],
    handler = function(params)
        try
            result = eval(Meta.parse(params["expr"]))
            return TextContent(text = "Result: $result")
        catch e
            return CallToolResult(
                content = [Dict(
                    "type" => "text",
                    "text" => "Invalid expression: $(string(e))"
                )],
                is_error = true
            )
        end
    end
)

# Initialize tracking variables
const start_time = time()
request_count = Ref(0)  # Use Ref for mutable global

# Modified resource to use the tracking variables
stats_resource = MCPResource(
    uri = "stats://server",
    name = "Server Statistics",
    mime_type = "application/json",
    data_provider = () -> begin
        request_count[] += 1  # Increment on each access
        Dict(
            "uptime" => time() - start_time,
            "requests" => request_count[]
        )
    end
)

# Create and start server
server = mcp_server(
    name = "example-server",
    version = "1.0.0",
    tools = [time_tool, calc_tool],
    resources = stats_resource
)

start!(server)
```

## Common Gotchas and Best Practices

### Top 10 Mistakes to Avoid

1. **Forgetting the `parameters` field in MCPTool**
   ```julia
   # ❌ Wrong - will throw error
   MCPTool(name = "bad", description = "Bad tool", handler = (p) -> TextContent(text = "Fail"))
   
   # ✅ Correct - always include parameters
   MCPTool(name = "good", description = "Good tool", parameters = [], handler = (p) -> TextContent(text = "Success"))
   ```

2. **Using localhost instead of 127.0.0.1 on Windows**
   ```julia
   # ❌ May fail on Windows
   HttpTransport(host = "localhost", port = 3000)
   
   # ✅ Always works
   HttpTransport(host = "127.0.0.1", port = 3000)
   ```

3. **Forgetting to call connect() for HTTP transport**
   ```julia
   # ❌ Wrong order
   transport = HttpTransport(port = 3000)
   start!(server, transport = transport)  # Will fail!
   
   # ✅ Correct order
   transport = HttpTransport(port = 3000)
   connect(transport)  # Must come first
   start!(server, transport = transport)
   ```

4. **Passing base64 data to ImageContent**
   ```julia
   # ❌ Wrong - don't base64 encode
   ImageContent(data = base64encode(image_bytes), mime_type = "image/png")
   
   # ✅ Correct - pass raw bytes
   ImageContent(data = image_bytes, mime_type = "image/png")
   ```

5. **Not handling missing parameters with defaults**
   ```julia
   # ❌ Risky - will error if param missing
   handler = (p) -> TextContent(text = "Value: $(p["optional"])")
   
   # ✅ Safe - use get() with default
   handler = (p) -> TextContent(text = "Value: $(get(p, "optional", "default"))")
   ```

6. **Modifying server internals directly**
   ```julia
   # ❌ Never access internal state directly
   # Internal fields may change between versions
   
   # ✅ Use public API
   stop!(server)
   ```

7. **Blocking forever in handlers**
   ```julia
   # ❌ Blocks other requests
   handler = function(params)
       sleep(60)  # Bad!
       TextContent(text = "Done")
   end
   
   # ✅ Quick return
   handler = function(params)
       # Start async work and return immediately
       @async do_slow_work()
       TextContent(text = "Started processing")
   end
   ```

8. **Not using --project flag**
   ```julia
   # ❌ May fail with missing deps
   julia server.jl
   
   # ✅ Always use project
   julia --project server.jl
   ```

9. **Mixing up the handler forms**
   ```julia
   # ✅ Default: params dictionary only
   handler = function(params)
       # Use closures for server-side state
   end

   # ✅ Opt-in: two-arg form receives the per-request context
   handler = function(params, ctx)
       send_progress(ctx, 0.5; message = "halfway")  # progress notifications
       # ctx also carries request_id, progress_token, authenticated_user, state
   end
   ```
   Dispatch is by `applicable` — define whichever form you need; the two-arg form
   wins when both would apply.

10. **Returning wrong Content format in CallToolResult**
    ```julia
    # ❌ Wrong - passing Content objects
    CallToolResult(content = [TextContent(text = "Error")], is_error = true)
    
    # ✅ Correct - must be dictionaries
    CallToolResult(content = [Dict("type" => "text", "text" => "Error")], is_error = true)
    ```

## Troubleshooting

### Common Issues and Solutions

#### Port Already in Use (HTTP)
**Problem:** "bind: address already in use" error when starting HTTP server.

**Solution:**
```bash
# Find process using the port
lsof -i :3000  # On Linux/Mac
netstat -ano | findstr :3000  # On Windows

# Kill the process or use a different port
transport = HttpTransport(port = 3001)  # Use alternative port
```

#### JIT Compilation Timeout
**Problem:** First request times out or takes very long.

**Solution:**
```julia
# Precompile your server before starting
julia --project -e 'using Pkg; Pkg.precompile()'

# Or add warmup in your server script
# Define your tools first
tools = [
    MCPTool(name = "tool1", description = "Tool 1", parameters = [], handler = (p) -> TextContent(text = "Result")),
    MCPTool(name = "tool2", description = "Tool 2", parameters = [], handler = (p) -> TextContent(text = "Result"))
]

server = mcp_server(
    name = "example",
    version = "1.0.0",  # Your server version
    tools = tools
)
# Warm up the JIT by calling handlers once
for tool in server.tools
    try
        tool.handler(Dict())  # Dummy call to trigger compilation
    catch
        # Ignore warmup errors
    end
end
start!(server)
```

#### Windows localhost Connection Issues
**Problem:** Cannot connect to server using `localhost` on Windows.

**Solution:** Always use `127.0.0.1` instead of `localhost`:
```julia
# ✗ Incorrect on Windows
transport = HttpTransport(host = "localhost", port = 3000)

# ✓ Correct
transport = HttpTransport(host = "127.0.0.1", port = 3000)
```

#### Missing Session ID (HTTP)
**Problem:** Requests fail with "Session required" after initialization.

**Solution:** Extract and include session ID from initialization response:
```bash
# Save session ID from init response
SESSION_ID=$(curl -X POST http://127.0.0.1:3000/ \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' \
  | jq -r '.sessionId')

# Use in subsequent requests
curl -X POST http://127.0.0.1:3000/ \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}'
```

#### Tool Handler Errors
**Problem:** Tool crashes or returns unexpected results.

**Solution:** Always wrap handlers in try-catch:
```julia
MCPTool(
    name = "safe_tool",
    description = "Tool with error handling",
    parameters = [],  # Required, even if empty
    handler = function(params)
        try
            # Your tool logic here
            result = process_data(params)
            return TextContent(text = result)
        catch e
            # Return error as CallToolResult
            return CallToolResult(
                content = [Dict("type" => "text", "text" => "Error: $(string(e))")],
                is_error = true
            )
        end
    end
)
```

## Performance Considerations

### JIT Compilation
Julia uses Just-In-Time compilation, which means:
- **First call is slow**: Initial execution compiles the code (5-10 seconds typical)
- **Subsequent calls are fast**: Compiled code runs at native speed
- **Precompilation helps**: Use `Pkg.precompile()` to reduce startup time

### Optimization Tips

1. **Precompile packages:**
   ```bash
   julia --project -e 'using Pkg; Pkg.precompile()'
   ```

2. **Use type annotations in performance-critical code:**
   ```julia
   # Slower
   handler = function(params)
       data = params["data"]
       process(data)
   end
   
   # Faster
   handler = function(params::Dict{String,Any})
       data::Vector{Float64} = params["data"]
       process(data)
   end
   ```

3. **Minimize allocations in handlers:**
   ```julia
   # Allocates new array each call
   handler = (p) -> TextContent(text = join(["Result: ", p["value"]]))
   
   # More efficient
   handler = (p) -> TextContent(text = "Result: $(p["value"])")
   ```

4. **Use `@time` and `@profile` for optimization:**
   ```julia
   # Define a tool for testing
   test_tool = MCPTool(
       name = "test",
       description = "Test tool",
       parameters = [ToolParameter(name = "value", type = "string",
                                   description = "Value to echo", required = true)],
       handler = (p) -> TextContent(text = "Result: $(p["value"])")
   )
   
   # Measure handler performance
   test_params = Dict("value" => "test")
   @time test_tool.handler(test_params)
   
   # Profile for bottlenecks
   using Profile
   @profile for i in 1:100
       test_tool.handler(test_params)
   end
   Profile.print()
   ```

### Memory Management
- Tools handlers are called frequently - avoid memory leaks
- Clean up resources in error paths
- Use `WeakRef` for caching if needed

## Threading and Concurrency

### Execution model
- **Serial loop for synchronous requests**: one server loop processes plain requests in
  order, so a slow handler delays the next request
- **Tasks move work off the loop**: `task_detach(ctx)` (modern era) or a task-augmented
  `tools/call` (legacy era) returns immediately and runs the handler in a background
  Julia task, leaving the loop free for polls, cancels, and other clients
- **Notifications flow while requests are in flight**: `send_progress` and
  subscription notifications reach the client without waiting for the response —
  on HTTP, either on the calling request's own POST SSE stream (synchronous
  handlers) or on the standalone GET stream (background executions)

### Thread Safety Considerations

**Important:** When using shared state in handlers (as shown in "Accessing Server State"), consider thread safety:

```julia
# Thread-safe shared state using locks
const state_lock = ReentrantLock()
const shared_data = Dict{String,Any}()

thread_safe_tool = MCPTool(
    name = "safe_update",
    description = "Thread-safe state updates",
    parameters = [
        ToolParameter(name = "key", type = "string", description = "State key to write", required = true),
        ToolParameter(name = "value", type = "string", description = "Value to store", required = true)
    ],
    handler = function(params)
        lock(state_lock) do
            # Critical section - only one handler at a time
            shared_data[params["key"]] = params["value"]
            return TextContent(text = "Updated $(params["key"])")
        end
    end
)

# Using Atomic for simple counters
const request_counter = Threads.Atomic{Int}(0)

counting_tool = MCPTool(
    name = "atomic_count",
    description = "Thread-safe counter",
    parameters = [],
    handler = function(params)
        count = Threads.atomic_add!(request_counter, 1) + 1
        TextContent(text = "Request #$count")
    end
)
```

### Best Practices
1. **Keep handlers fast**: Offload heavy work to background tasks
2. **Use timeouts**: Prevent indefinite blocking
3. **Return quickly**: Stream results via resources for long operations
4. **Use locks sparingly**: Minimize critical sections
5. **Prefer immutable data**: Reduces synchronization needs

### Long-running work
- Report progress from a two-arg handler with `send_progress(ctx, i; total = n)` — see
  [Progress Notifications](#progress-notifications)
- Move the work off the serial loop entirely with Tasks: `task_detach(ctx)` in the
  modern era, or a task-augmented `tools/call` in the legacy era. The handler runs in a
  background Julia task while the loop stays free for polls and cancels; poll
  `task_cancelled(ctx)` to stop early

## Important Implementation Notes

### Handler Parameters
Tool handlers receive `Dict{String,Any}` parameters by default; a two-arg form opting into the per-request context is also supported:
```julia
# Default: params only
handler = function(params::Dict{String,Any})
    value = params["key"]
    result = string(value) * " processed"
    return TextContent(text = result)
end

# Opt-in: (params, ctx) receives the per-request context
handler = function(params, ctx)
    for i in 1:10
        send_progress(ctx, i; total = 10, message = "step $i")
        # ... work ...
    end
    return TextContent(text = "done")
end
```
`ctx` carries `request_id`, `progress_token`, `authenticated_user` (when HTTP auth is
enabled), `state` (whose `protocol_version` is the negotiated legacy version), and
`protocol_version` (the modern-era per-request version, `nothing` on legacy requests) —
merge the two for `supports(version, :feature)` gating.
`send_progress` is a safe no-op when the client sent no `progressToken`. Note: do NOT
annotate the second argument with `::RequestContext` — the type is intentionally not
exported; just take `ctx` untyped.

### Accessing Server State from Handlers

Beyond the per-request `ctx`, you can use closures to access shared server-side state:

```julia
# Create shared state
const server_state = Dict{String,Any}(
    "request_count" => Ref(0),
    "last_request" => Ref(nothing)
)

# Tool that accesses shared state via closure
stateful_tool = MCPTool(
    name = "track_usage",
    description = "Tool that tracks its usage",
    parameters = [
        ToolParameter(name = "action", type = "string", description = "Action being tracked", required = true)
    ],
    handler = function(params)
        # Access and modify shared state
        server_state["request_count"][] += 1
        server_state["last_request"][] = params["action"]
        
        count = server_state["request_count"][]
        last = server_state["last_request"][]
        
        TextContent(text = "Request #$count: $last")
    end
)

# Alternative: Use a factory function
function create_stateful_tool(initial_count::Int = 0)
    count = Ref(initial_count)
    
    return MCPTool(
        name = "counter",
        description = "Counting tool",
        parameters = [],
        handler = function(params)
            count[] += 1
            TextContent(text = "Count: $(count[])")
        end
    )
end

# Create tool with encapsulated state
counter_tool = create_stateful_tool(100)
```

### Required Fields
⚠️ **CRITICAL: The `parameters` field is ALWAYS required**, even when empty. This is a common source of errors:
```julia
# ✓ Correct - empty array for no parameters
MCPTool(
    name = "no_params",
    description = "Tool without parameters",
    parameters = [],  # Required!
    handler = (p) -> TextContent(text = "Done")
)

# ✗ Incorrect - missing parameters field
MCPTool(
    name = "bad_tool",
    description = "This will fail",
    # parameters field missing - will cause error
    handler = (p) -> TextContent(text = "Done")
)
```

### Project Execution
Always use `--project` flag when running Julia MCP servers:
```bash
# ✓ Correct - loads project dependencies
julia --project server.jl
julia --project=/path/to/project server.jl
julia --project examples/time_server.jl

# For testing with MCP Inspector
julia --project examples/my_server.jl | npx @modelcontextprotocol/inspector

# For production with Claude Desktop config
julia --project=/absolute/path/to/project server.jl

# ✗ Incorrect - may fail with missing dependencies
julia server.jl
```

## Error Types and Handling

### JSON-RPC Error Codes

The package uses standard JSON-RPC error codes:

```julia
# Standard error codes (from ErrorCodes enum)
PARSE_ERROR = -32700        # Invalid JSON
INVALID_REQUEST = -32600    # Invalid JSON-RPC structure
METHOD_NOT_FOUND = -32601   # Unknown method
INVALID_PARAMS = -32602     # Invalid method parameters
INTERNAL_ERROR = -32603     # Internal server error
```

### Error Response Structure

```julia
# Error responses follow JSON-RPC format
{
    "jsonrpc": "2.0",
    "error": {
        "code": -32601,
        "message": "Method not found",
        "data": {"method": "unknown_method"}  # Optional additional data
    },
    "id": 1
}
```

### Handling Errors in Tool Handlers

```julia
# Pattern 1: Return CallToolResult with is_error=true
handler = function(params)
    if haskey(params, "invalid")
        return CallToolResult(
            content = [Dict("type" => "text", "text" => "Invalid parameter")],
            is_error = true
        )
    end
    # Normal processing
end

# Pattern 2: Let exceptions propagate (caught by framework)
handler = function(params)
    # This will be caught and converted to error response
    @assert haskey(params, "required") "Missing required parameter"
    # Normal processing
end

# Pattern 3: Explicit try-catch with logging
handler = function(params)
    try
        risky_operation(params)
    catch e
        @error "Tool failed" exception=(e, catch_backtrace())
        return CallToolResult(
            content = [Dict("type" => "text", "text" => "Operation failed: $(string(e))")],
            is_error = true
        )
    end
end
```

## Debugging Techniques

### Enable Logging

```julia
using Logging

# Set log level for detailed output
ENV["JULIA_DEBUG"] = "ModelContextProtocol"

# Or use a custom logger
global_logger(ConsoleLogger(stderr, Logging.Debug))
```

### Testing Tools Locally

```julia
# Test tool handler directly
tool = MCPTool(
    name = "test",
    description = "Test tool",
    parameters = [],
    handler = (p) -> TextContent(text = "Result")
)

# Call handler directly
result = tool.handler(Dict())
println("Result: ", result)

# Test with actual parameters
test_params = Dict("key" => "value")
result = tool.handler(test_params)
```

### Inspecting Server State

```julia
# After creating server
server = mcp_server(name = "debug-server", version = "1.0.0")

# Inspect registered components (stored as vectors)
println("Tools: ", [tool.name for tool in server.tools])
println("Resources: ", [res.name for res in server.resources])
println("Prompts: ", [prompt.name for prompt in server.prompts])

# Check server configuration
println("Server name: ", server.config.name)
println("Server version: ", server.config.version)
```

### Testing with curl

```bash
# Test HTTP server with verbose output
curl -v -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' \
  | jq .
```

## Notes

### Critical Implementation Details
- Tool handlers receive `Dict{String,Any}` parameters; add a second `ctx` argument to opt into the per-request context (progress, auth, negotiated version)
- Parameters field is ALWAYS required for tools (use `[]` for no parameters)
- Binary data in ImageContent must be raw bytes (`Vector{UInt8}`), NOT base64
- HTTP transport requires `connect()` before `start!()`
- Use `127.0.0.1` instead of `localhost` on Windows
- Auto-registration loads each file in isolated module
- CallToolResult requires pre-serialized content dictionaries
- First execution will be slow due to JIT compilation (5-10 seconds typical)
- Always use `julia --project` to ensure dependencies are loaded

### Type System Notes
- Exported abstract types (`Content`, `ResourceContents`, `Transport`) for extensibility
- Concrete types use `@kwdef` for keyword constructors
- Small dictionaries use `LittleDict` from OrderedCollections.jl
- URI fields accept strings but store as `URI` objects internally

### Protocol Compliance
- Dual-era: modern `2026-07-28` per request via `_meta`, legacy `2025-11-25` down to `2024-11-05` via `initialize`
- JSON-RPC batching not supported (returns error)
- Session management available for HTTP transport (opt-in via `session_required=true`)
- ResourceLink is new in protocol version 2025-06-18
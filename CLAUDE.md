# ModelContextProtocol.jl Development Guide

## HTTP Transport Usage

### Windows Localhost Issues
On Windows, use `127.0.0.1` instead of `localhost` to avoid IPv6 connection issues:
- Server: `HttpTransport(host="127.0.0.1", port=3000)`
- Client: `http://127.0.0.1:3000/`
- MCP Remote: `npx mcp-remote http://127.0.0.1:3000 --allow-http`

### Testing HTTP Transport
1. **Direct curl test**:
   ```bash
   curl -X POST http://127.0.0.1:3000/ -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
   ```

2. **MCP Inspector with mcp-remote bridge**:
   ```bash
   npx @modelcontextprotocol/inspector stdio -- npx mcp-remote http://127.0.0.1:3000 --allow-http
   ```

3. **Claude Desktop configuration**:
   ```json
   {
     "mcpServers": {
       "julia-http": {
         "command": "npx",
         "args": ["mcp-remote", "http://127.0.0.1:3000", "--allow-http"]
       }
     }
   }
   ```

### HTTP Transport Implementation
The HTTP transport implements the Streamable HTTP specification:
- **POST requests**: JSON-RPC messages with immediate JSON responses
- **GET requests**: SSE streams for server-to-client notifications (requires `Accept: text/event-stream` header)

## Commands
- Build: `using Pkg; Pkg.build("ModelContextProtocol")`
- Test all: `using Pkg; Pkg.test("ModelContextProtocol")`
- Test single: `julia --project -e 'using Pkg; Pkg.test("ModelContextProtocol", test_args=["specific_test.jl"])'`
- Documentation: `julia --project=docs docs/make.jl`
- Documentation deployment: Automatic via GitHub Actions on push to main
- REPL: `using ModelContextProtocol` after activating project
- Example server: `julia --project examples/multi_content_tool.jl`

## Integration Tests

Integration tests with external MCP clients (Python SDK) are located in `dev/integration_tests/`. These tests are separate from the main test suite and require additional setup:

### Running Integration Tests

1. **Setup the integration test environment**:
   ```bash
   cd dev/integration_tests
   julia --project -e 'using Pkg; Pkg.instantiate()'
   pip install -r requirements.txt
   ```

2. **Run individual integration tests**:
   ```bash
   # Basic STDIO communication test
   julia --project test_basic_stdio.jl
   
   # Full integration test with Python MCP client
   julia --project test_integration.jl
   
   # Python client compatibility test
   julia --project test_python_client.jl
   ```

3. **Run all integration tests**:
   ```bash
   julia --project runtests.jl
   ```

### What Integration Tests Cover

- **STDIO Protocol**: Tests bidirectional JSON-RPC communication over stdio
- **Python Client Compatibility**: Validates that Julia MCP servers work with the official Python MCP SDK
- **Real Protocol Compliance**: End-to-end testing with actual MCP clients
- **Cross-Language Interoperability**: Ensures the Julia implementation follows the MCP specification correctly

### When to Run Integration Tests

- Before releasing new versions
- When making protocol-level changes
- When adding new MCP features
- For debugging client compatibility issues

**Note**: Integration tests are not run automatically in CI and require manual execution due to their external Python dependencies.

## Project Structure
```
src/
├── ModelContextProtocol.jl     # Main module entry point
├── core/                       # Core server functionality
│   ├── capabilities.jl         # Protocol capability management
│   ├── init.jl                 # Initialization logic
│   ├── server.jl               # Server implementation
│   ├── server_types.jl         # Server-specific types
│   └── types.jl                # Core type definitions
├── features/                   # MCP feature implementations
│   ├── prompts.jl              # Prompt handling
│   ├── resources.jl            # Resource management
│   └── tools.jl                # Tool implementation
├── protocol/                   # JSON-RPC protocol layer
│   ├── handlers.jl             # Request handlers
│   ├── jsonrpc.jl              # JSON-RPC implementation
│   └── messages.jl             # Protocol message types
├── types.jl                    # Public type exports
└── utils/                      # Utility functions
    ├── errors.jl               # Error handling
    ├── logging.jl              # MCP-compliant logging
    └── serialization.jl        # Message serialization
```

## Code Style
- Imports: Group related imports (e.g., `using JSON3, URIs, DataStructures`)
- Types: Use abstract type hierarchy, concrete types with `Base.@kwdef`
- Naming: 
  - PascalCase for types (e.g., `MCPTool`, `TextContent`)
  - snake_case for functions and variables (e.g., `mcp_server`, `request_id`)
  - Use descriptive names that reflect purpose
- Utility Functions:
  - `content2dict(content::Content)`: Convert Content objects to Dict for JSON serialization
  - Uses multiple dispatch for different content types (TextContent, ImageContent, EmbeddedResource)
  - Automatically handles base64 encoding for binary data
- Documentation: 
  - Add full docstrings for all types and methods
  - Use imprative phrasing for the one line description in docstrings "Scan a directory" not "Scans a directory"
  - Use triple quotes with function signature at top including all parameters and return type:
    ```julia
    """
        function_name(param1::Type1, param2::Type2) -> ReturnType
    
    Brief, one line imperative phrase of the function's action.
    
    # Arguments
    - `param1::Type1`: Description of the first parameter
    - `param2::Type2`: Description of the second parameter
    
    # Returns
    - `ReturnType`: Description of the return value
    """
    ```
  - For structs and types, include the constructor pattern and all fields:
    ```julia
    """
        StructName(; field1::Type1=default1, field2::Type2=default2)
    
    Description of the struct's purpose.
    
    # Fields
    - `field1::Type1`: Description of the first field
    - `field2::Type2`: Description of the second field
    """
    ```
  - Include a concise description after the signature
  - Always separate sections with blank lines
  - No examples block required 
- Error handling: Use `ErrorCodes` enum for structured error reporting
- Organization: Follow modular structure with core, features, protocol, utils
- Type annotations: Use for function parameters and struct fields
- Constants: Use UPPER_CASE for true constants

## Key Features
- **Multi-Content Tool Returns**: Tools can return either a single `Content` object or a `Vector{<:Content}` for multiple items
  - Single: `return TextContent(text = "result")`
  - Multiple: `return [TextContent(text = "item1"), ImageContent(data = ..., mime_type = "image/png")]`
  - Mixed content types in same response supported
  - Default `return_type` is `Vector{Content}` - single items are auto-wrapped
  - Set `return_type = TextContent` to validate single content returns
- **MCP Protocol Compliance**: Tools are only returned via `tools/list` request, not in initialization response
  - Initialization response only indicates tool support with `{"tools": {"listChanged": true/false}}`
  - Clients must call `tools/list` after initialization to discover available tools
- **Tool Parameter Defaults**: Tool parameters can have default values specified in ToolParameter struct
  - Define using `default` field: `ToolParameter(name="timeout", type="number", default=30.0)`
  - Handler automatically applies defaults when parameters are not provided
  - Defaults are included in the tool schema returned by `tools/list`
- **Direct CallToolResult Returns**: Tool handlers can return CallToolResult objects directly
  - Provides full control over response structure including error handling
  - Example: `return CallToolResult(content=[...], is_error=true)`
  - When returning CallToolResult, the tool's return_type field is ignored
  - Useful for tools that need to indicate errors or complex response patterns

## Progress Monitoring Capabilities

### Current Implementation
The ModelContextProtocol.jl package includes infrastructure for progress monitoring, but with significant limitations:

1. **Types and Structures**:
   - `ProgressToken` type alias: `Union{String,Int}` for tracking operations
   - `Progress` struct: Contains `token`, `current`, `total`, and optional `message` fields
   - `ProgressParams` struct: Used for progress notifications with token, progress value, and optional total
   - `RequestMeta` struct: Contains optional `progress_token` field for request tracking

2. **Server Infrastructure**:
   - Server maintains `progress_trackers::Dict{Union{String,Int}, Progress}` for tracking ongoing operations
   - Request handlers receive `RequestContext` with optional `progress_token` from the request metadata

3. **Protocol Support**:
   - JSON-RPC notification handler recognizes `"notifications/progress"` method
   - Progress notification messages are defined in the protocol layer

### Current Limitations

1. **No Outbound Notification Mechanism**:
   - The server can receive and process notifications but cannot send them to clients
   - The `process_message` function only handles stdin→stdout request/response flow
   - No `send_notification` or similar function exists for pushing updates to clients

2. **Tool Handler Constraints**:
   - Tool handlers execute synchronously and return a single result
   - No access to server context or communication channels within handlers
   - Cannot emit progress updates during long-running operations

3. **Missing Implementation**:
   - The `handle_notification` function for `"notifications/progress"` is empty (no-op)
   - No examples or documentation showing progress monitoring usage
   - Progress trackers are maintained in server state but never utilized

### Potential Implementation Approaches

1. **Server Context Enhancement**:
   ```julia
   # Add notification capability to RequestContext
   mutable struct RequestContext
       server::Server
       request_id::Union{RequestId,Nothing}
       progress_token::Union{ProgressToken,Nothing}
       notification_channel::Union{Channel,Nothing}  # New field
   end
   ```

2. **Asynchronous Tool Execution**:
   ```julia
   # Modified tool handler pattern
   handler = function(params, ctx::RequestContext)
       # Can send progress notifications via ctx.notification_channel
       if !isnothing(ctx.progress_token)
           put!(ctx.notification_channel, ProgressNotification(...))
       end
   end
   ```

3. **Bidirectional Communication**:
   - Implement a notification queue alongside the request/response flow
   - Add a `send_notification` function that writes to stdout
   - Ensure thread-safe access to stdout for concurrent notifications

4. **Alternative Workarounds**:
   - Return partial results as streaming content
   - Use resource subscriptions for status updates
   - Implement polling-based progress checking via separate tool calls

### Recommendations for Implementation

1. **Short-term**: Document the current limitations clearly in tool implementations
2. **Medium-term**: Add server context access to tool handlers for future extensibility
3. **Long-term**: Implement full bidirectional communication with proper notification support

The infrastructure exists but requires additional implementation to enable progress monitoring from within tool handlers.

## Dev Notes
- use 127.0.0.1 instead of localhost on windows
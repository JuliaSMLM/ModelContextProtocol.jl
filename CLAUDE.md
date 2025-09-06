# ModelContextProtocol.jl Guide

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

## Testing MCP Servers as a Client

### stdio Transport Testing
Test stdio servers using pipe communication:

```bash
# Single request
echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}},"id":1}' | julia --project examples/time_server.jl 2>/dev/null | jq .

# Multiple requests (initialize, then list tools)
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}},"id":1}\n{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' | julia --project examples/time_server.jl 2>/dev/null | tail -1 | jq .

# Call a tool
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}},"id":1}\n{"jsonrpc":"2.0","method":"tools/call","params":{"name":"get_time","arguments":{"format":"HH:MM:SS"}},"id":2}' | julia --project examples/time_server.jl 2>/dev/null | tail -1 | jq .
```

### Streamable HTTP Transport Testing

1. **Start the server** (in one terminal):
   ```bash
   julia --project examples/simple_http_server.jl
   ```

2. **Test with curl** (in another terminal):
   ```bash
   # Initialize
   curl -X POST http://localhost:3000/ \
     -H 'Content-Type: application/json' \
     -H 'MCP-Protocol-Version: 2025-06-18' \
     -H 'Accept: application/json' \
     -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}},"id":1}' | jq .
   
   # List tools (include session ID if provided)
   curl -X POST http://localhost:3000/ \
     -H 'Content-Type: application/json' \
     -H 'Mcp-Session-Id: <session-id-from-init>' \
     -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' | jq .
   
   # Call a tool
   curl -X POST http://localhost:3000/ \
     -H 'Content-Type: application/json' \
     -H 'Mcp-Session-Id: <session-id-from-init>' \
     -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello MCP!"}},"id":3}' | jq .
   ```

3. **Test SSE streaming**:
   ```bash
   # Connect SSE client
   curl -N -H 'Accept: text/event-stream' http://localhost:3000/
   ```

### Common Test Scenarios

1. **Protocol negotiation**:
   - Test with different protocol versions
   - Verify server capabilities response

2. **Tool testing**:
   - List available tools
   - Call tools with valid arguments
   - Test error handling with invalid arguments
   - Test missing required parameters

3. **Session management** (HTTP only):
   - Verify session ID generation on init
   - Test requests with/without session ID
   - Verify 400 Bad Request for missing session when required

4. **Error scenarios**:
   - Call non-existent methods
   - Send malformed JSON
   - Test with invalid tool names
   - Exceed parameter limits

### Automated Testing Script
Create a test script for comprehensive testing:

```julia
# test_client.jl
using HTTP, JSON3

function test_mcp_server(url)
    # Initialize
    init_response = HTTP.post(url,
        ["Content-Type" => "application/json"],
        JSON3.write(Dict(
            "jsonrpc" => "2.0",
            "method" => "initialize",
            "params" => Dict(
                "protocolVersion" => "2025-06-18",
                "clientInfo" => Dict("name" => "test", "version" => "1.0")
            ),
            "id" => 1
        ))
    )
    println("Init: ", String(init_response.body))
    
    # Extract session ID if present
    session_id = HTTP.header(init_response, "Mcp-Session-Id", "")
    
    # List tools
    headers = ["Content-Type" => "application/json"]
    if !isempty(session_id)
        push!(headers, "Mcp-Session-Id" => session_id)
    end
    
    tools_response = HTTP.post(url, headers,
        JSON3.write(Dict(
            "jsonrpc" => "2.0",
            "method" => "tools/list",
            "params" => Dict(),
            "id" => 2
        ))
    )
    println("Tools: ", String(tools_response.body))
end

test_mcp_server("http://localhost:3000/")
```

## Troubleshooting

### Session Validation in HTTP Transport

**Problem**: Session validation happens before checking if request is initialization, causing init requests to fail.

**Solution**: Read and parse request body BEFORE validating session:
```julia
# ✅ CORRECT: Parse body first, then check session
body = String(read(stream))
msg = JSON3.read(body)
is_initialize = get(msg, "method", "") == "initialize"

if !is_initialize && transport.session_required
    # Check session only for non-initialization requests
end

# ❌ WRONG: Don't use HTTP.payload(request) - causes streaming issues
```

### Common Port Conflicts

Use less common ports to avoid conflicts:
- **8765**: Good default test port (less common than 8080)
- **3000-3999**: Often used by web dev servers
- **8080**: Commonly used by proxies/web servers
- **5000-5999**: Often used by Flask/Python servers

Check for running servers:
```bash
ps aux | grep -E "julia.*(server|mcp)" | grep -v grep
```

### Notification Handling (202 Accepted)

Notifications (requests without `id` field) must return 202 Accepted with no body:
```julia
if is_notification
    HTTP.setstatus(stream, 202)
    HTTP.setheader(stream, "Content-Length" => "0")
    HTTP.startwrite(stream)  # Send headers
    # No body for 202 per spec
end
```

### SSE Stream Flushing

Use `Base.flush()` explicitly for HTTP streams to avoid naming conflicts:
```julia
write(stream, event)
Base.flush(stream)  # Not just flush(stream)
```

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

## Technical Notes
- Use 127.0.0.1 instead of localhost on Windows for HTTP transport
- Julia JIT compilation takes 5-10 seconds on first server start
- Port 8765 is good alternative to avoid common conflicts (3000, 8080, etc.)

## MCP Server Testing & Management

### Finding Running Servers
When testing MCP servers, check for running processes:
```bash
# Check for running Julia MCP servers
ps aux | grep "julia.*examples.*" | grep -v grep

# Check specific ports (HTTP servers)
netstat -tlnp | grep ":300[0-9]"  # Common MCP HTTP ports 3000-3009
netstat -tlnp | grep ":8765"      # Alternative test port
```

### Shutting Down Servers
```bash
# Kill specific processes by PID
kill PID1 PID2 PID3

# Kill all Julia MCP processes (use carefully)
pkill -f "julia.*examples.*"

# Force kill if needed
pkill -9 -f "julia.*examples.*"
```

### Best Practices for MCP Client Testing
1. **Always check for running servers before starting new ones**
2. **Use different ports for concurrent testing** (3000, 3001, 3002, etc.)
3. **Kill servers after testing** to free ports and resources
4. **Allow 5-10 seconds for Julia JIT compilation** before making requests
5. **Use proper session management** for HTTP servers (Mcp-Session-Id header)

### Common Issues
- **Port conflicts**: Use `netstat` to check occupied ports
- **Hanging processes**: Use `kill -9` for force termination
- **JIT compilation timeouts**: Allow adequate time for server startup
- **Session validation**: HTTP servers require proper session headers after initialization

## MCP Protocol 2025-06-18 Compliance Status

### ✅ Fully Implemented Features

1. **Core Transport Protocols**
   - ✅ stdio transport (standard input/output)
   - ✅ Streamable HTTP transport with SSE support
   - ✅ Session management (Mcp-Session-Id headers)
   - ✅ Protocol version negotiation (only 2025-06-18 supported)

2. **Version Validation**
   - ✅ Strict protocol version validation (only accepts 2025-06-18)
   - ✅ Proper error responses for unsupported versions
   - ✅ MCP-Protocol-Version header validation in HTTP transport

3. **JSON-RPC Compliance (2025-06-18)**
   - ✅ Removed JSON-RPC batching support (returns proper error)
   - ✅ Single message per request enforcement
   - ✅ Proper JSON-RPC 2.0 validation

4. **Content Types**
   - ✅ TextContent - Text-based responses
   - ✅ ImageContent - Binary image content with base64 encoding
   - ✅ EmbeddedResource - Embedded resource content
   - ✅ ResourceLink - Resource references (NEW in 2025-06-18)

5. **Multi-Content Tool Returns**
   - ✅ Single content return: `return TextContent(...)`
   - ✅ Multiple content return: `return [TextContent(...), ImageContent(...)]`
   - ✅ Mixed content types in single response

6. **Security Features** 
   - ✅ Origin header validation for HTTP transport
   - ✅ Localhost binding by default
   - ✅ Cryptographically secure session IDs (UUID format)
   - ✅ Session ID ASCII validation (0x21-0x7E)

7. **Auto-Registration System**
   - ✅ Directory-based component organization
   - ✅ Automatic tool/prompt/resource discovery
   - ✅ Isolated module loading for each component file

### ❌ Features Not Yet Implemented (Optional/Future)

1. **OAuth Authorization (Optional)**
   - ❌ OAuth Resource Server classification  
   - ❌ Authorization server discovery
   - ❌ Protected resource metadata
   - ❌ Resource Indicators (RFC 8707) support

2. **Elicitation (Optional)**
   - ❌ Server-to-client user interaction requests
   - ❌ elicitation/create method handling
   - ❌ Structured user input with JSON schemas
   - ❌ Nested interaction workflows

3. **Client Features (Client-Side)**
   - ❌ Roots - filesystem access boundaries
   - ❌ Sampling - LLM completion requests
   - ❌ Completion/autocompletion suggestions

4. **Advanced Features (Optional)**
   - ❌ _meta fields on message types (metadata support)
   - ❌ Audio content type (AudioContent)  
   - ❌ Progress notifications with bidirectional updates
   - ❌ Stream resumption with Last-Event-ID
   - ❌ title field support for human-friendly display names

5. **Enterprise Features (Optional)**
   - ❌ Advanced authentication beyond basic session management
   - ❌ Fine-grained authorization per tool/resource
   - ❌ Enterprise SSO integration

### 🎯 Implementation Priority for Future Work

**High Priority** (Core 2025-06-18 compliance):
1. _meta field support on core types
2. title field support for tools/resources/prompts
3. Audio content type (AudioContent)

**Medium Priority** (Enhanced functionality):
1. Progress notification improvements
2. Stream resumption support
3. Elicitation basic support

**Low Priority** (Enterprise/Optional):
1. OAuth authorization support
2. Advanced authentication
3. Client-side features (roots, sampling)

### 🧪 Testing Status
- ✅ Protocol version validation working
- ✅ JSON-RPC batch rejection working  
- ✅ ResourceLink content type working
- ✅ All existing functionality preserved
- ✅ HTTP transport fully compliant with 2025-06-18

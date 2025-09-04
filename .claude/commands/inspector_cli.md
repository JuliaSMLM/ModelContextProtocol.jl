# MCP Inspector CLI Testing Guide

**IMPORTANT**: This guide is for reference in future requests involving MCP testing. Do not take action based on this guide unless explicitly specified in the input argument below.

## Input Argument
- `action`: (optional) Specify what testing action to perform. Options: `test-server`, `test-tools`, `test-resources`, `test-prompts`, `debug-communication`, `none` (default: `none`)

## Overview

The MCP Inspector provides both web UI and CLI modes for testing MCP servers. The Inspector CLI is the standard tool for testing MCP servers and servers must work with it to be compatible with Claude Desktop.

## Installation

### Official MCP Inspector
```bash
# Run directly via npx (no installation needed)
npx @modelcontextprotocol/inspector

# CLI mode syntax
npx @modelcontextprotocol/inspector --cli <server-command> --method <method>
```

### Inspector CLI Options
```
Options:
  -e <env>               environment variables in KEY=VALUE format
  --config <path>        config file path
  --server <n>           server name from config file
  --cli                  enable CLI mode
  --transport <type>     transport type (stdio, sse, http)
  --server-url <url>     server URL for SSE/HTTP transport
  --header <headers...>  HTTP headers as "HeaderName: Value" pairs
  --method <method>      method to invoke (required in CLI mode)
  --tool-name <name>     tool name for tools/call
  --tool-arg <arg>       tool arguments as key=value
```

## Inspector CLI Examples

### Test with Official Filesystem Server
```bash
# List tools
npx @modelcontextprotocol/inspector --cli \
  npx @modelcontextprotocol/server-filesystem /tmp \
  --method tools/list

# Call a tool
npx @modelcontextprotocol/inspector --cli \
  npx @modelcontextprotocol/server-filesystem /tmp \
  --method tools/call \
  --tool-name read_file \
  --tool-arg path=/tmp/test.txt
```

### Test with Julia MCP Servers

**IMPORTANT**: The Inspector CLI requires command and arguments to be separated, not quoted as a single string.

```bash
# Correct syntax - arguments separated after --cli
npx @modelcontextprotocol/inspector --cli julia --project=/path/to/project /path/to/server.jl --method tools/list

# Example with full paths
npx @modelcontextprotocol/inspector --cli \
  julia \
  --project=/home/kalidke/julia_shared_dev/ModelContextProtocol \
  /home/kalidke/julia_shared_dev/ModelContextProtocol/examples/time_server.jl \
  --method tools/list

# Test tools/call
npx @modelcontextprotocol/inspector --cli \
  julia \
  --project=/home/kalidke/julia_shared_dev/ModelContextProtocol \
  /home/kalidke/julia_shared_dev/ModelContextProtocol/examples/time_server.jl \
  --method tools/call \
  --tool-name current_time

# Test resources/read
npx @modelcontextprotocol/inspector --cli \
  julia \
  --project=/home/kalidke/julia_shared_dev/ModelContextProtocol \
  /home/kalidke/julia_shared_dev/ModelContextProtocol/examples/time_server.jl \
  --method resources/read \
  --tool-arg uri="character-info://harry-potter/birthday"

# Test prompts/get
npx @modelcontextprotocol/inspector --cli \
  julia \
  --project=/home/kalidke/julia_shared_dev/ModelContextProtocol \
  /home/kalidke/julia_shared_dev/ModelContextProtocol/examples/time_server.jl \
  --method prompts/get \
  --tool-arg name=movie_analysis \
  --tool-arg genre=horror \
  --tool-arg year=1980
```

**Note**: Currently Julia servers may hang with Inspector CLI due to stdio communication issues. The processes start correctly but communication may not complete. Use direct JSON-RPC testing for debugging.

## Direct CLI Testing for Julia Servers (Debugging)

For debugging Julia servers that aren't working with Inspector CLI, use direct JSON-RPC testing:

### 1. Protocol Information
- **Required Version**: `2025-06-18` (not `2024-11-05`)
- **Inspector sends**: Proper initialization with correct version
- **Message sequence**: initialize → notifications/initialized → method call

### 2. Basic Server Testing

```bash
# Single request
echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}},"id":1}' | \
  julia --project examples/test_inspector.jl 2>/dev/null | jq .

# Multiple requests
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}},"id":1}\n{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' | \
  julia --project examples/test_inspector.jl 2>/dev/null | jq -s .
```

### 3. Testing Tools

```bash
# List tools
(echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'; \
 echo '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}') | \
  julia --project examples/test_inspector.jl 2>/dev/null | tail -1 | jq .

# Call a tool
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}\n{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello!"}},"id":2}' | \
  julia --project examples/test_inspector.jl 2>/dev/null | tail -1 | jq .
```

### 4. Testing Resources

```bash
# List resources
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}\n{"jsonrpc":"2.0","method":"resources/list","params":{},"id":2}' | \
  julia --project examples/test_inspector.jl 2>/dev/null | tail -1 | jq .

# Read a resource
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}\n{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"test://hello"},"id":2}' | \
  julia --project examples/test_inspector.jl 2>/dev/null | tail -1 | jq .
```

### 5. Testing Prompts

```bash
# List prompts
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}\n{"jsonrpc":"2.0","method":"prompts/list","params":{},"id":2}' | \
  julia --project examples/test_inspector.jl 2>/dev/null | tail -1 | jq .

# Get a prompt
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}\n{"jsonrpc":"2.0","method":"prompts/get","params":{"name":"greeting","arguments":{"name":"World"}},"id":2}' | \
  julia --project examples/test_inspector.jl 2>/dev/null | tail -1 | jq .
```

## HTTP Transport Testing

For HTTP-based MCP servers:

### 1. Start HTTP Server
```bash
julia --project examples/simple_http_server.jl
```

### 2. Test with curl
```bash
# Initialize (save session ID from response)
curl -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' | jq .

# List tools (use session ID from init)
curl -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -H 'Mcp-Session-Id: <session-id-from-init>' \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' | jq .
```

## Test Script for Julia Servers

Create a reusable test script:

```bash
#!/bin/bash
# test_julia_mcp.sh

SERVER="julia --project examples/test_inspector.jl"
PROTOCOL="2025-06-18"

# Create request file
cat > /tmp/mcp_test.json << EOF
{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"$PROTOCOL","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{"message":"test"}},"id":3}
EOF

# Run tests
cat /tmp/mcp_test.json | $SERVER 2>/dev/null | jq -s .
```

## Debugging Tips

### 1. Check Server Output
```bash
# See all output including errors
echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' | \
  julia --project examples/test_inspector.jl 2>&1
```

### 2. Log Inspector Messages
Create a debug server to see what Inspector sends:

```julia
# debug_server.jl
using JSON3

log = open("/tmp/mcp_debug.log", "w")
while !eof(stdin)
    line = readline(stdin)
    println(log, "Received: ", line)
    flush(log)
    # Process and respond...
end
```

### 3. Test Inspector Protocol Sequence
The Inspector CLI sends this sequence:
1. `{"method":"initialize","params":{"protocolVersion":"2025-06-18",...},"id":0}`
2. `{"method":"notifications/initialized","jsonrpc":"2.0"}` (notification)
3. `{"method":"tools/list","jsonrpc":"2.0","id":1}`

## Common Issues & Solutions

### Issue: Inspector CLI Timeout with Julia Servers
**Symptom**: Command hangs and times out
**Cause**: Server implementation issue that needs to be fixed
**Solution**: Debug with direct JSON-RPC testing to identify the issue

### Issue: Protocol Version Mismatch
**Error**: "Unsupported protocol version"
**Solution**: Use `2025-06-18` not `2024-11-05`

### Issue: Empty Tool Lists
**Cause**: Tools not registered before server starts
**Solution**: Register tools before calling `start!(server)`

### Issue: Session Management (HTTP)
**Error**: 400 Bad Request
**Solution**: Include `Mcp-Session-Id` header from init response

## Best Practices

1. **Test with Inspector CLI**: Servers must work with Inspector CLI to work with Claude Desktop
2. **Always test init first**: Verify protocol compatibility
3. **Use jq**: Makes JSON responses readable
4. **Capture stderr**: Helps debug server issues
5. **Allow JIT time**: First Julia request may be slow (5-10s)

## Alternative Testing Tools

### mcp-cli by wong2
```bash
npx @wong2/mcp-cli
```

### MCP Tools (Go-based, different project)
```bash
brew tap f/McpTools
brew install mcp
```

## Summary

The MCP Inspector CLI is the standard tool for testing MCP servers. Servers must work with the Inspector CLI to be compatible with Claude Desktop. For debugging servers that aren't working properly with the Inspector, direct JSON-RPC testing can help identify issues.
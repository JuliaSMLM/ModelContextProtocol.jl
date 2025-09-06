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
# WARNING: Inspector CLI has a bug with prompt arguments - they are not passed correctly
# Use direct JSON-RPC testing instead (see below)
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

# Get a prompt (with arguments)
echo -e '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}\n{"jsonrpc":"2.0","method":"prompts/get","params":{"name":"movie_analysis","arguments":{"genre":"horror"}},"id":2}' | \
  julia --project examples/time_server.jl 2>/dev/null | tail -1 | jq .

# Note: The Inspector CLI currently has a bug with prompt arguments. 
# Use direct JSON-RPC testing as shown above for prompts with arguments.
```

## HTTP Transport Testing

For HTTP-based MCP servers:

### 1. Start HTTP Server
```bash
julia --project examples/simple_http_server.jl
# Wait 5-10 seconds for Julia JIT compilation on first start
```

### 2. Test with curl

#### IMPORTANT: HTTP Accept Header Requirements
HTTP servers **require BOTH** Accept headers:
- `application/json` - For JSON-RPC responses
- `text/event-stream` - For SSE notifications

Missing either header will result in `406 Not Acceptable` error.

```bash
# Initialize (save session ID from response)
curl -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' | jq .

# Extract and save session ID
SESSION_ID=$(curl -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' \
  -s -D - | grep -i "mcp-session-id" | cut -d' ' -f2 | tr -d '\r')

# List tools (use session ID from init)
curl -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' | jq .
```

### 3. Test HTTP Servers with MCP Inspector CLI

HTTP servers cannot be tested directly with Inspector CLI. Use the `mcp-remote` bridge:

```bash
# Test HTTP server via mcp-remote
npx @modelcontextprotocol/inspector --cli \
  npx mcp-remote http://127.0.0.1:3000 --allow-http \
  --method tools/list

# For servers on different ports
npx @modelcontextprotocol/inspector --cli \
  npx mcp-remote http://127.0.0.1:3004 --allow-http \
  --method tools/list
```

## Test Script for Julia Servers

Create a reusable test script in the project's tmp/ folder:

```bash
#!/bin/bash
# tmp/test_julia_mcp.sh

# Ensure we're in the project directory
cd "$(dirname "$0")/.."

SERVER="julia --project examples/test_inspector.jl"
PROTOCOL="2025-06-18"

# Create request file in tmp/
cat > tmp/mcp_test.json << EOF
{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"$PROTOCOL","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{"message":"test"}},"id":3}
EOF

# Run tests
cat tmp/mcp_test.json | $SERVER 2>/dev/null | jq -s .

# Clean up
rm -f tmp/mcp_test.json
```

## Debugging Tips

### 1. Check Server Output
```bash
# See all output including errors
echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' | \
  julia --project examples/test_inspector.jl 2>&1
```

### 2. Log Inspector Messages
Create a debug server in tmp/ to see what Inspector sends:

```julia
# tmp/debug_server.jl
using JSON3

# Use project tmp/ folder for logs
log = open("tmp/mcp_debug.log", "w")
while !eof(stdin)
    line = readline(stdin)
    println(log, "Received: ", line)
    flush(log)
    # Process and respond...
end
close(log)
```

Remember to clean up debug logs:
```bash
rm -f tmp/mcp_debug.log tmp/debug_server.jl
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

### Issue: JSON Special Characters in Shell
**Error**: `ArgumentError("encountered invalid escape character in json string")`
**Cause**: Shell escaping of special characters like `!` in JSON strings
**Solutions**:
1. Avoid special characters in test data when possible
2. Use proper quoting:
   ```bash
   # Problem: Shell may escape the exclamation mark
   curl -d '{"message":"Hello MCP!"}'  # May send "Hello MCP\!"
   
   # Solution 1: Avoid special characters
   curl -d '{"message":"Hello MCP"}'
   
   # Solution 2: Use printf to construct JSON
   JSON=$(printf '{"message":"Hello MCP!"}')
   curl -d "$JSON"
   
   # Solution 3: Use a heredoc for complex JSON
   curl -d @- <<EOF
   {"message":"Hello MCP!"}
   EOF
   ```

### Issue: HTTP Accept Headers Missing
**Error**: `406 Not Acceptable: Must accept both application/json and text/event-stream`
**Cause**: HTTP transport requires both Accept headers for proper content negotiation
**Solution**: Always include both headers:
```bash
-H 'Accept: application/json, text/event-stream'
```

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

## Server Cleanup After Testing

### IMPORTANT: Always Clean Up Test Servers

MCP test servers can continue running in the background after testing. Always check for and clean up running servers:

```bash
# Check for running Julia MCP servers
ps aux | grep -E "julia.*(examples|mcp|server)" | grep -v grep

# Check for specific example servers
ps aux | grep -E "julia.*(time_server|minimal_debug|reg_dir|simple_http)" | grep -v grep

# Check for MCP Inspector processes
ps aux | grep -E "mcp-inspector|@modelcontextprotocol/inspector" | grep -v grep

# Check for servers on common MCP ports
netstat -tlnp | grep -E ":(3000|3004|8765)"
lsof -i :3000  # Check specific port
```

### Kill Running Servers

```bash
# Kill specific process by PID
kill <PID>

# Kill multiple PIDs at once
kill PID1 PID2 PID3

# Force kill if process won't stop
kill -9 <PID>

# Kill all Julia example servers (use carefully!)
pkill -f "julia.*examples.*"

# Kill all MCP inspector processes
pkill -f "mcp-inspector"
pkill -f "@modelcontextprotocol/inspector"
```

### Best Practices for Server Management

1. **Use Project tmp/ Folder for Test Scripts**: Keep test artifacts organized
   ```bash
   # Create tmp folder if it doesn't exist (gitignored)
   mkdir -p tmp/
   
   # Put test scripts in tmp/
   cat > tmp/test_mcp.sh << 'EOF'
   #!/bin/bash
   echo "Testing MCP server..."
   # test commands here
   EOF
   
   # Clean up after testing
   rm -f tmp/test_*.sh tmp/*.json tmp/*.log
   ```

2. **Before Testing**: Check for existing servers to avoid port conflicts
   ```bash
   ps aux | grep julia.*examples | grep -v grep
   ```

3. **After Testing**: Always clean up servers AND test files
   ```bash
   # Save PIDs when starting servers for easy cleanup
   julia --project examples/time_server.jl & 
   SERVER_PID=$!
   # ... do testing ...
   kill $SERVER_PID
   
   # Clean up test artifacts
   rm -f tmp/test_* tmp/*.json tmp/*.log
   ```

4. **Use Different Ports**: When testing multiple servers concurrently
   - Default: 3000
   - Alternatives: 3001-3009, 8765, 8080

5. **Create Cleanup Script**: For frequent testing
   ```bash
   #!/bin/bash
   # tmp/cleanup_mcp.sh
   echo "Cleaning up MCP servers..."
   pkill -f "julia.*examples.*time_server"
   pkill -f "julia.*examples.*reg_dir"
   pkill -f "mcp-inspector"
   echo "Cleaning up test files..."
   rm -f tmp/test_*.sh tmp/*.json tmp/*.log tmp/mcp_*
   echo "Done!"
   ```

6. **Monitor Long-Running Tests**: Set timeouts
   ```bash
   timeout 30s julia --project examples/test_server.jl
   ```

### Test File Organization

Always use the `tmp/` folder for test artifacts:

```bash
# Project structure for testing
ModelContextProtocol/
├── tmp/                    # Gitignored folder for test artifacts
│   ├── test_*.sh          # Test scripts
│   ├── mcp_*.json         # Test JSON files
│   ├── *.log              # Debug logs
│   └── cleanup_mcp.sh     # Cleanup script
├── examples/              # Example servers (don't modify)
└── .gitignore            # Should include tmp/
```

**Ensure tmp/ is in .gitignore:**
```bash
# Check if tmp/ is gitignored
grep "^tmp/" .gitignore || echo "tmp/" >> .gitignore
```

### Common Leftover Processes

These processes are commonly left running after testing:
- `julia ... examples/time_server.jl` - Basic example server
- `julia ... examples/minimal_debug.jl` - Debug server
- `julia ... examples/reg_dir_http.jl` - HTTP server (keeps port open)
- `npm exec @modelcontextprotocol/inspector` - Inspector UI
- `node ... mcp-inspector` - Inspector backend

## Summary

The MCP Inspector CLI is the standard tool for testing MCP servers. Servers must work with the Inspector CLI to be compatible with Claude Desktop. For debugging servers that aren't working properly with the Inspector, direct JSON-RPC testing can help identify issues. **Always remember to clean up test servers after testing to avoid port conflicts and resource usage.**
---
name: mcp-inspector
description: Test Model Context Protocol (MCP) servers using the MCP Inspector CLI with correct syntax
---

# MCP Inspector Testing Skill

This skill provides comprehensive testing capabilities for Model Context Protocol (MCP) servers, particularly Julia-based servers using ModelContextProtocol.jl. It uses the correct Inspector CLI syntax verified through extensive testing.

## Purpose

Test MCP servers to verify:
- Protocol compliance (2025-06-18 specification)
- Tool, resource, and prompt functionality
- Response format validation
- Error handling
- Multi-content returns

## When to Use This Skill

- Testing new MCP server implementations
- Debugging MCP protocol issues
- Validating tool/resource/prompt definitions
- Verifying cross-client compatibility
- Creating test reports for MCP servers

## Prerequisites

### 1. Resolve Dependencies (CRITICAL)

```bash
# For Julia projects - ALWAYS run these first from project root
cd /path/to/project
julia --project -e 'using Pkg; Pkg.resolve(); Pkg.precompile()'

# If examples have separate Project.toml
cd examples && julia --project -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'
cd ..
```

**Why**: Julia manifests may be resolved with different versions, causing dependency errors (especially MbedTLS_jll).

### 2. Work from Project Root

```bash
# ✅ CORRECT - from project root
cd /path/to/project
npx @modelcontextprotocol/inspector --cli julia --project=. examples/server.jl ...

# ❌ WRONG - from subdirectory
cd examples
npx @modelcontextprotocol/inspector --cli julia --project examples/server.jl ...
# Results in "examples/examples/server.jl: No such file" error
```

## Correct Inspector CLI Syntax

### Command Structure

```bash
npx @modelcontextprotocol/inspector --cli \
  <server-command> <server-args> \
  --method <method-name> \
  [--tool-name <name>] \
  [--tool-arg key=value ...] \
  [--uri <uri>] \
  [--prompt-name <name>] \
  [--prompt-args key=value ...]
```

### CRITICAL: Correct Flags

**Tool Arguments**:
- ✅ Use `--tool-arg key=value` (can be repeated)
- ❌ NOT `--params '{"key":"value"}'`

**Prompt Arguments**:
- ✅ Use `--prompt-args key=value` (can be repeated, note plural)
- ❌ NOT `--prompt-arg` (singular)

**Resource URI**:
- ✅ Use `--uri "scheme://path"`

## Testing stdio Servers

### Basic Operations

**List Tools**:
```bash
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method tools/list
```

**List Resources**:
```bash
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method resources/list
```

**List Prompts**:
```bash
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method prompts/list
```

### Call Tool (No Parameters)

```bash
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method tools/call \
  --tool-name current_time
```

### Call Tool (With Parameters)

```bash
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/multi_content_tool.jl \
  --method tools/call \
  --tool-name flexible_response \
  --tool-arg format=text
```

**Multiple Parameters**:
```bash
--method tools/call \
--tool-name analyze \
--tool-arg param1=value1 \
--tool-arg param2=value2 \
--tool-arg param3=value3
```

### Read Resource

```bash
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method resources/read \
  --uri "character-info://harry-potter/birthday"
```

### Get Prompt (Currently Broken)

```bash
# This will fail due to server-side _meta bug
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method prompts/get \
  --prompt-name movie_analysis \
  --prompt-args genre="science fiction" \
  --prompt-args year=1999
```

**Note**: `prompts/get` currently fails due to ModelContextProtocol.jl serializing `_meta: null` instead of omitting the field.

## Testing HTTP Servers

### Start Server First

```bash
# Terminal 1: Start server
cd /path/to/project
julia --project=. examples/simple_http_server.jl

# Wait 5-10 seconds for Julia compilation
```

### Test via mcp-remote Bridge

```bash
# Terminal 2: Test with Inspector
npx @modelcontextprotocol/inspector --cli \
  npx mcp-remote http://127.0.0.1:3000 --allow-http \
  --method tools/list
```

### Or Test with curl

```bash
curl -X POST http://127.0.0.1:3000/ \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18"},"id":1}' \
| jq .
```

## Standard Test Suite

### Complete Server Test

```bash
#!/bin/bash
cd /path/to/project

echo "=== SETUP ==="
julia --project -e 'using Pkg; Pkg.resolve(); Pkg.precompile()'

echo -e "\n=== TOOLS/LIST ==="
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method tools/list

echo -e "\n=== RESOURCES/LIST ==="
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method resources/list

echo -e "\n=== PROMPTS/LIST ==="
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method prompts/list

echo -e "\n=== TOOLS/CALL (no params) ==="
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method tools/call \
  --tool-name current_time

echo -e "\n=== RESOURCES/READ ==="
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method resources/read \
  --uri "character-info://harry-potter/birthday"

echo -e "\n=== TOOLS/CALL (with params) ==="
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/multi_content_tool.jl \
  --method tools/call \
  --tool-name flexible_response \
  --tool-arg format=text

echo -e "\n=== TOOLS/CALL (multi-content) ==="
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/multi_content_tool.jl \
  --method tools/call \
  --tool-name flexible_response \
  --tool-arg format=both
```

## Known Issues

### 1. ModelContextProtocol.jl _meta Field Bug

**Symptom**: `prompts/get` fails with validation error about `_meta` field

**Cause**: Server serializes `_meta: null` instead of omitting the field

**Status**: Server-side bug, NOT Inspector CLI issue

**Workaround**: None - needs fix in ModelContextProtocol.jl

### 2. EmbeddedResource Conversion Error

**Symptom**: Tools returning EmbeddedResource content fail with MethodError

**Cause**: Server cannot convert TextResourceContents to Dict for serialization

**Status**: Server-side bug

**Workaround**: Avoid EmbeddedResource content type

### 3. Auto-Registration (FIXED)

**Previous Issue**: `reg_dir.jl` example returned empty tool/resource/prompt lists

**Cause**: Julia scoping bug with `names()` introspection + Julia 1.12 world age semantics

**Status**: ✅ **FIXED** - Now uses `include()` return value instead of module introspection

**Verification**:
```bash
npx @modelcontextprotocol/inspector --cli julia --project=. examples/reg_dir.jl -- --method tools/list
# Returns: 3 tools (gen_2d_array, julia_version, inspect_workspace)
```

**Component File Requirement**: Component must be the last expression in the file

See: `REG_DIR_BUG_ANALYSIS_AND_FIX.md` for technical details

### 4. Julia Version Dependency Issues

**Symptom**: `Package MbedTLS_jll is required but does not seem to be installed`

**Cause**: Manifest resolved with different Julia version

**Workaround**: Run `Pkg.resolve()` before testing (see Prerequisites)

## Response Validation

### Valid Tool Response

```json
{
  "content": [
    {
      "type": "text",
      "text": "Tool result text"
    }
  ],
  "is_error": false
}
```

### Valid Multi-Content Response

```json
{
  "content": [
    {
      "type": "text",
      "text": "Text content"
    },
    {
      "type": "image",
      "data": "base64data",
      "mimeType": "image/png"
    }
  ],
  "is_error": false
}
```

### Valid Resource Response

```json
{
  "contents": [
    {
      "uri": "scheme://path",
      "mimeType": "application/json",
      "text": "{\"data\":\"value\"}"
    }
  ]
}
```

## Examples

### Example 1: Basic Tool Test

```bash
cd /home/kalidke/julia_shared_dev/ModelContextProtocol

# Setup
julia --project -e 'using Pkg; Pkg.resolve()'

# Test
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method tools/call \
  --tool-name current_time
```

### Example 2: Tool with Parameters

```bash
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/multi_content_tool.jl \
  --method tools/call \
  --tool-name flexible_response \
  --tool-arg format=both
```

### Example 3: Resource Read

```bash
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method resources/read \
  --uri "character-info://harry-potter/birthday"
```

### Example 4: Full Server Validation

```bash
# List all capabilities
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method tools/list > tools.json

npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/time_server.jl \
  --method resources/list > resources.json

# Test each tool
jq -r '.tools[].name' tools.json | while read tool; do
  echo "Testing: $tool"
  npx @modelcontextprotocol/inspector --cli \
    julia --project=. examples/time_server.jl \
    --method tools/call \
    --tool-name "$tool"
done

# Test each resource
jq -r '.resources[].uri' resources.json | while read uri; do
  echo "Testing: $uri"
  npx @modelcontextprotocol/inspector --cli \
    julia --project=. examples/time_server.jl \
    --method resources/read \
    --uri "$uri"
done
```

## Best Practices

1. **Always resolve dependencies first**: Run `Pkg.resolve()` and `Pkg.precompile()`
2. **Work from project root**: Not from subdirectories
3. **Use correct flags**:
   - `--tool-arg` for tool parameters (repeatable)
   - `--prompt-args` for prompt parameters (plural, repeatable)
   - `--uri` for resource URIs
4. **Test systematically**:
   - List all components first
   - Test each individually
   - Validate responses
5. **Account for Julia JIT**: First request takes 5-10 seconds
6. **Check for server bugs**: Some failures are server-side, not CLI issues

## Performance Notes

- **Julia JIT compilation**: First request takes 5-10 seconds (normal)
- **Subsequent requests**: <100ms typically
- **Inspector overhead**: Minimal, <1 second per request
- **HTTP server startup**: Add 5-10 seconds before testing

## Troubleshooting

### Server Won't Start

```bash
# Check dependencies
julia --project -e 'using Pkg; Pkg.status()'

# Resolve dependencies
julia --project -e 'using Pkg; Pkg.resolve()'

# Run with full error output
julia --project examples/server.jl 2>&1 | less
```

### Inspector Connection Closed

Check you're in the correct directory:
```bash
# Verify current directory
pwd

# Verify server file exists
ls -la examples/server.jl

# Run from project root
cd /path/to/project
npx @modelcontextprotocol/inspector --cli julia --project=. examples/server.jl ...
```

### HTTP Port Already in Use

```bash
# Find and kill existing server
ps aux | grep "julia.*server.jl"
kill <PID>

# Or use different port in server code
```

## Success Metrics

Based on testing with ModelContextProtocol.jl:

- ✅ tools/list: **Working**
- ✅ resources/list: **Working**
- ✅ prompts/list: **Working**
- ✅ tools/call (no params): **Working**
- ✅ tools/call (with params): **Working**
- ✅ resources/read: **Working**
- ✅ Multi-content returns: **Working**
- ❌ prompts/get: **Broken** (server bug)
- ❌ EmbeddedResource: **Broken** (server bug)
- ❌ Auto-registration: **Broken** (server bug)

**Success Rate**: 70% (7/10 operations working)

## References

- **MCP Specification**: https://modelcontextprotocol.io/specification/2025-06-18/
- **Inspector CLI**: https://github.com/modelcontextprotocol/inspector
- **Inspector Documentation**: https://modelcontextprotocol.io/docs/tools/inspector
- **ModelContextProtocol.jl**: https://github.com/JuliaSMLM/ModelContextProtocol.jl
- **Test Report**: See `MCP_INSPECTOR_TESTING_REPORT.md` in project root

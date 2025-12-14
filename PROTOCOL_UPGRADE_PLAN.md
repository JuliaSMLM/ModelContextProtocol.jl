# MCP Protocol 2025-11-25 Upgrade Plan

## Overview

Upgrade ModelContextProtocol.jl from protocol version `2025-06-18` to `2025-11-25`.

**Branch Strategy:**
- `feature/protocol-2025-11-25` - Base branch with protocol version change
- Feature branches off base for each major feature
- Merge features back to base, then base to main

## Phase 1: Base Protocol Version Update

**Branch:** `feature/protocol-2025-11-25` (current)

### Tasks
1. Update `SERVER_PROTOCOL_VERSION` in `src/protocol/handlers.jl`
2. Update default `protocol_version` in `src/transports/http.jl`
3. Update all test files with new protocol version strings
4. Update documentation references
5. Add support for accepting both 2025-06-18 and 2025-11-25 during negotiation
6. Bump package version to 0.5.0

### Files to Modify
- `src/protocol/handlers.jl` - SERVER_PROTOCOL_VERSION constant
- `src/transports/http.jl` - HttpTransport default
- `test/transports/*.jl` - Test protocol strings
- `test/integration/*.jl` - Integration test strings
- `CHANGELOG.md` - Document changes
- `Project.toml` - Version bump

---

## Phase 2: Icon Metadata Support (SEP-973)

**Branch:** `feature/icon-metadata` (off protocol-2025-11-25)

### New Feature
Servers can expose icons as metadata for tools, resources, resource templates, and prompts.

### Tasks
1. Add `icon::Union{String,Nothing}` field to:
   - `MCPTool`
   - `MCPResource`
   - `ResourceTemplate`
   - `MCPPrompt`
2. Update serialization to include icon in JSON output
3. Update `tools/list`, `resources/list`, `prompts/list` responses
4. Add tests for icon metadata

### Files to Modify
- `src/types.jl` - Add icon fields
- `src/utils/serialization.jl` - Handle icon serialization
- `src/features/tools.jl` - Include icon in tool response
- `src/features/resources.jl` - Include icon in resource response
- `src/features/prompts.jl` - Include icon in prompt response
- `test/features/*.jl` - New tests

---

## Phase 3: Implementation Description Field

**Branch:** `feature/implementation-description` (off protocol-2025-11-25)

### New Feature
Optional `description` field on `Implementation` interface for human-readable context.

### Tasks
1. Add `description::Union{String,Nothing}` to `Implementation` struct
2. Include in initialization response
3. Update `create_mcp_server` to accept description

### Files to Modify
- `src/types.jl` - Add description to Implementation
- `src/core/init.jl` - Accept description parameter
- `src/protocol/messages.jl` - Include in InitializeResult

---

## Phase 4: Tasks Support (Experimental) (SEP-1686)

**Branch:** `feature/tasks` (off protocol-2025-11-25)

### New Feature
Durable request tracking with polling and deferred result retrieval.

### New Types
```julia
@enum TaskState working input_required completed failed cancelled

struct TaskInfo
    id::String
    state::TaskState
    message::Union{String,Nothing}
    result::Union{Any,Nothing}
    created_at::DateTime
    updated_at::DateTime
end
```

### New Methods
- `tasks/list` - List active tasks
- `tasks/get` - Get task status/result
- `tasks/cancel` - Cancel a running task

### Tasks
1. Define TaskState enum and TaskInfo struct
2. Add task registry to Server state
3. Implement task lifecycle management
4. Add task-related request handlers
5. Enable tools to return task IDs for long-running operations
6. Mark as experimental in capabilities

### Files to Modify
- `src/types.jl` - New task types
- `src/core/server.jl` - Task registry
- `src/protocol/handlers.jl` - Task handlers
- `src/protocol/messages.jl` - Task request/response types
- `src/core/capabilities.jl` - Experimental flag

---

## Phase 5: Enhanced Elicitation (SEP-1034, SEP-1036, SEP-1330)

**Branch:** `feature/elicitation-enhancements` (off protocol-2025-11-25)

### New Features
- Default values in primitive types (string, number, enum)
- URL mode elicitation for browser-based OAuth
- Enhanced enum schema (titled, untitled, single/multi-select)

### Tasks
1. Add `default` field to elicitation primitive types
2. Add URL mode elicitation request type
3. Update EnumSchema with title support and multi-select
4. Update ElicitResult structure

### Files to Modify
- `src/types.jl` - Elicitation types
- `src/protocol/messages.jl` - Elicitation requests
- `src/features/elicitation.jl` - (new file if needed)

---

## Phase 6: Tool Calling in Sampling (SEP-1577)

**Branch:** `feature/sampling-tools` (off protocol-2025-11-25)

### New Feature
Add `tools` and `toolChoice` parameters to sampling requests.

### Tasks
1. Add `tools` field to SamplingRequest
2. Add `toolChoice` field to SamplingRequest
3. Update sampling handler to include tools
4. Add tests

### Files to Modify
- `src/protocol/messages.jl` - SamplingRequest fields
- `src/features/sampling.jl` - Handler updates
- Tests

---

## Phase 7: JSON Schema 2020-12 Default (SEP-1613)

**Branch:** `feature/schema-dialect` (off protocol-2025-11-25)

### New Feature
Establish JSON Schema 2020-12 as default dialect.

### Tasks
1. Add `$schema` field to generated schemas
2. Document schema dialect in API
3. Ensure compatibility with 2020-12 features

### Files to Modify
- `src/features/tools.jl` - Schema generation
- Documentation

---

## Phase 8: SSE Stream Polling (SEP-1699)

**Branch:** `feature/sse-polling` (off protocol-2025-11-25)

### New Feature
Servers can disconnect SSE streams at will to support polling.

### Tasks
1. Add server-initiated disconnect capability
2. Update GET stream handling for polling support
3. Event IDs should encode stream identity
4. Document polling behavior

### Files to Modify
- `src/transports/http.jl` - SSE handling
- Documentation

---

## Implementation Order (Recommended)

1. **Phase 1** - Base protocol version (required first)
2. **Phase 3** - Implementation description (simple, low risk)
3. **Phase 2** - Icon metadata (simple addition)
4. **Phase 7** - JSON Schema dialect (documentation/metadata)
5. **Phase 8** - SSE polling (transport enhancement)
6. **Phase 5** - Elicitation enhancements (moderate complexity)
7. **Phase 6** - Sampling tools (moderate complexity)
8. **Phase 4** - Tasks (most complex, experimental)

---

## Testing Strategy

Each feature branch should include:
1. Unit tests for new types
2. Integration tests with mock clients
3. Protocol compliance tests
4. Backward compatibility verification

---

## Documentation Updates

Per feature:
1. Update `api_overview.md`
2. Update `docs/src/*.md`
3. Update `CLAUDE.md` compliance status
4. Add examples for new features

---

## Not Implemented (Out of Scope)

These 2025-11-25 features are client-side or optional enterprise:
- OAuth Client ID Metadata Documents (SEP-991) - Authorization
- Client credentials flow (SEP-1046) - Authorization
- Cross App Access (SEP-990) - Enterprise authorization
- OpenID Connect Discovery - Authorization enhancement

These can be added in future releases if needed.

# HTTP Transport Implementation Plan for ModelContextProtocol.jl

## Overview
Adding HTTP+SSE transport support to ModelContextProtocol.jl while maintaining backward compatibility with STDIO transport.

## Architecture

### 1. Transport Abstraction Layer
Create abstract interface for all transports:
- `abstract type Transport end`
- Core methods: `read_message`, `write_message`, `close`, `is_connected`

### 2. Concrete Transports
- `StdioTransport` - Current stdin/stdout implementation
- `HttpSseTransport` - New HTTP with Server-Sent Events

### 3. Server Modifications
- Add transport field to Server struct
- Modify start! to accept transport parameter (default: StdioTransport)
- Refactor run_server_loop to use transport abstraction

## Implementation Phases

### Phase 1: Transport Abstraction ✓
- [ ] Create abstract Transport type
- [ ] Define transport interface
- [ ] Add transport field to Server
- [ ] Create transport tests

### Phase 2: STDIO Refactoring
- [ ] Implement StdioTransport
- [ ] Refactor run_server_loop
- [ ] Ensure existing tests pass
- [ ] Add STDIO-specific tests

### Phase 3: HTTP+SSE Implementation
- [ ] Add HTTP.jl dependency
- [ ] Implement HttpSseTransport
- [ ] Create SSE endpoint (/sse)
- [ ] Create messages endpoint (/messages)
- [ ] Session management
- [ ] HTTP transport tests

### Phase 4: Authentication
- [ ] Auth provider interface
- [ ] OAuth 2.1 implementation
- [ ] Integration with HTTP transport
- [ ] Security tests

### Phase 5: Documentation
- [ ] API documentation
- [ ] Examples
- [ ] Migration guide
- [ ] README updates

## Key Design Decisions
1. HTTP.jl as static dependency (not Requires.jl)
2. Maintain backward compatibility - STDIO remains default
3. Clean abstraction to avoid ugly compatibility hacks
4. Follow MCP specification for HTTP+SSE

## Technical Notes
- Session tracking via session IDs in query params
- SSE for server-to-client streaming
- POST /messages for client-to-server
- Proper error handling for network issues
- OAuth 2.1 for authentication (HTTP only)

## Progress Tracking
Started: 2025-01-25
Branch: http-sse
# MCP Transport Specification - Streamable HTTP

**Protocol Version**: 2025-03-26  
**Last Updated**: 2025-09-02  
**Source**: https://modelcontextprotocol.io/docs/concepts/transports

**Note**: This document describes the current **Streamable HTTP** transport which replaces the deprecated HTTP+SSE transport from protocol version 2024-11-05.  

## Overview

The Model Context Protocol supports multiple transport mechanisms for communication between clients and servers. All transports use JSON-RPC 2.0 as the message format but differ in how messages are transmitted.

## Supported Transports

### 1. stdio Transport

The stdio transport is the simplest transport mechanism where:
- Server reads from standard input (stdin)
- Server writes to standard output (stdout)
- Client launches server as a subprocess
- Messages are newline-delimited JSON

**Requirements:**
- Messages MUST be valid JSON-RPC 2.0
- Messages MUST be UTF-8 encoded
- Messages MUST be delimited by newlines (`\n`)
- Server MUST NOT write non-MCP output to stdout
- Server MAY write logging to stderr

**Message Flow:**
```
Client Process                    Server Process
     |                                 |
     |------ stdin (request) --------->|
     |                                 |
     |<------ stdout (response) -------|
```

### 2. Streamable HTTP Transport

The Streamable HTTP transport enables servers to operate as independent processes handling multiple client connections. This is the current specification as of protocol version 2025-03-26.

**Endpoints:**
- Single HTTP endpoint (e.g., `/`) supporting both POST and GET methods
- POST: For sending JSON-RPC messages
- GET: For establishing SSE streams (optional)

**Request Requirements:**
- Clients MUST include `Accept` header with both:
  - `application/json`
  - `text/event-stream`
- POST requests MUST have `Content-Type: application/json`
- Clients SHOULD include `MCP-Protocol-Version` header (defaults to previous version if missing)
- Requests MUST include `Mcp-Session-Id` header after initialization (if session assigned)

**Response Patterns:**

1. **For Requests (expecting responses):**
   - Server returns `200 OK` with `Content-Type: application/json`
   - Body contains the JSON-RPC response
   - Server MAY return response via SSE stream instead

2. **For Notifications (no response expected):**
   - Server returns `202 Accepted`
   - No body required

3. **For SSE Streams (GET requests):**
   - Server returns `200 OK` with `Content-Type: text/event-stream`
   - Stream remains open for server-initiated messages
   - Server sends events using SSE format

**SSE Event Format:**
```
event: message
data: {"jsonrpc":"2.0","method":"notifications/resources/list_changed"}
id: <event-id>

```

**Session Management:**
- Server MAY assign session ID during initialization via `Mcp-Session-Id` header
- Session ID MUST contain only visible ASCII characters (0x21 to 0x7E)
- Session ID SHOULD be globally unique and cryptographically secure
- Client MUST include `Mcp-Session-Id` header in all subsequent requests
- Servers requiring session SHOULD respond with 400 Bad Request to requests missing session ID
- Server MAY terminate sessions (404 response) requiring reinitialization
- Sessions enable:
  - Connection resumption
  - Message redelivery
  - State persistence

**Stream Resumption:**
- Client sends `Last-Event-ID` header with last received event ID
- Server resumes from specified event if possible
- Server starts fresh stream if resumption not possible

**Security Requirements:**
- Servers SHOULD validate `Origin` header
- Servers SHOULD bind to localhost when possible
- Servers SHOULD implement authentication
- Servers SHOULD use HTTPS in production

## Message Lifecycle

Regardless of transport, all MCP interactions follow this lifecycle:

1. **Initialization**
   - Client sends `initialize` request
   - Server responds with capabilities
   - Protocol version negotiated

2. **Capability Discovery**
   - Client requests available tools/resources/prompts
   - Server provides listings

3. **Operation Execution**
   - Client sends requests
   - Server processes and responds
   - Notifications may be sent by either party

4. **Shutdown**
   - Client sends `shutdown` notification
   - Server performs cleanup
   - Connection closed

## Transport Selection Guidelines

**Use stdio when:**
- Simple subprocess model is sufficient
- Single client-server relationship
- Minimal setup required

**Use Streamable HTTP when:**
- Multiple clients need to connect
- Server needs to run independently
- Session management required
- Web-based clients need access
- Firewall traversal needed
- Real-time streaming via SSE needed

## Implementation Requirements

All transport implementations MUST:
1. Preserve JSON-RPC message structure
2. Handle connection lifecycle properly
3. Support bidirectional communication
4. Implement error handling
5. Maintain message ordering per JSON-RPC spec

## Error Handling

Transport errors should be reported as JSON-RPC errors with appropriate codes:
- `-32700`: Parse error
- `-32600`: Invalid request
- `-32601`: Method not found
- `-32602`: Invalid params
- `-32603`: Internal error
- `-32000 to -32099`: Server-defined errors

## Future Considerations

The protocol is designed to be transport-agnostic. Future transports may include:
- WebSockets
- gRPC
- Named pipes
- Unix domain sockets

Any new transport must preserve the JSON-RPC message format and lifecycle requirements.
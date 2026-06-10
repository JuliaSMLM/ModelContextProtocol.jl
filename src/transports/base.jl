# src/transports/base.jl

"""
    Transport

Abstract base type for all MCP transport implementations.
Defines the interface for reading and writing messages between client and server.
"""
abstract type Transport end

"""
    TransportError(message::String) <: Exception

Exception type for transport-specific errors.

# Fields
- `message::String`: The error message describing what went wrong
"""
struct TransportError <: Exception
    message::String
end

# Required interface methods that must be implemented by concrete transports

"""
    read_message(transport::Transport) -> Union{String,Nothing}

Read a single message from the transport.

# Arguments
- `transport::Transport`: The transport instance to read from

# Returns
- `Union{String,Nothing}`: The message string if available, or nothing if no message or connection closed
"""
function read_message end

"""
    pending_auth_context(transport::Transport) -> Union{Nothing,Any}

Return the authenticated user associated with the message most recently read from
`transport`, or `nothing` when the transport has no per-request authentication
(e.g. stdio). Transports that authenticate requests override this; the default is
`nothing`.
"""
pending_auth_context(::Transport) = nothing

"""
    write_message(transport::Transport, message::String) -> Nothing

Write a message to the transport.

# Arguments
- `transport::Transport`: The transport instance to write to
- `message::String`: The message to send

# Returns
- `Nothing`

# Throws
- `TransportError`: If the message cannot be sent
"""
function write_message end

"""
    send_notification(transport::Transport, message::String) -> Nothing

Deliver a server-to-client JSON-RPC notification over `transport`.

The default writes the message directly — correct for stdio, where notifications and
responses share one stream. Transports that multiplex per-request responses (e.g. HTTP,
where `write_message` routes to the *calling request's* response channel) override this to
send notifications over a separate out-of-band channel, so a mid-request notification
never corrupts that request's response.

# Arguments
- `transport::Transport`: The transport instance to send over
- `message::String`: The serialized JSON-RPC notification

# Returns
- `Nothing`
"""
send_notification(transport::Transport, message::String) = write_message(transport, message)

"""
    capture_response_route(transport::Transport) -> Any

Capture a route handle for delivering the CURRENT request's response later, from
outside the server loop (used by `tasks/result`, which must block until the task
completes without blocking the loop). The returned handle is passed to
`deliver_response`.

The default returns `nothing` — for stream transports like stdio, responses carry
their correlation in the JSON-RPC `id`, so no per-request route exists. Transports
that route responses per request (HTTP) override this to detach and return the
current request's route so the loop can move on to the next request.

# Arguments
- `transport::Transport`: The transport instance

# Returns
- An opaque route handle understood by `deliver_response` for this transport
"""
capture_response_route(::Transport) = nothing

"""
    deliver_response(transport::Transport, route::Any, message::String) -> Nothing

Deliver a serialized JSON-RPC response for a request whose route was captured earlier
with `capture_response_route`. Safe to call from a background task. The default
ignores the route and writes to the shared stream (correct for stdio, where
`write_message` is lock-serialized).

# Arguments
- `transport::Transport`: The transport instance
- `route::Any`: The handle returned by `capture_response_route`
- `message::String`: The serialized JSON-RPC response

# Returns
- `Nothing`
"""
deliver_response(transport::Transport, ::Any, message::String) = write_message(transport, message)

"""
    set_negotiated_version!(transport::Transport, version::String) -> Nothing

Inform the transport of the protocol version negotiated during `initialize`, so
transports that advertise a version per response (e.g. the HTTP `MCP-Protocol-Version`
header) echo the negotiated one rather than a static default. Default is a no-op
(stdio carries no version metadata).

# Arguments
- `transport::Transport`: The transport instance to update
- `version::String`: The negotiated MCP protocol version

# Returns
- `Nothing`
"""
set_negotiated_version!(::Transport, ::String) = nothing

"""
    close(transport::Transport) -> Nothing

Close the transport connection and clean up resources.

# Arguments
- `transport::Transport`: The transport instance to close

# Returns
- `Nothing`
"""
function close end

"""
    is_connected(transport::Transport) -> Bool

Check if the transport is currently connected and operational.

# Arguments
- `transport::Transport`: The transport instance to check

# Returns
- `Bool`: true if connected and ready, false otherwise
"""
function is_connected end

# Optional interface methods with default implementations

"""
    connect(transport::Transport) -> Nothing

Establish the transport connection.
Default implementation does nothing (for transports that are always connected).

# Arguments
- `transport::Transport`: The transport instance to connect

# Returns
- `Nothing`

# Throws
- `TransportError`: If connection cannot be established
"""
function connect(transport::Transport)
    # Default: no-op for transports that don't need explicit connection
    nothing
end

"""
    flush(transport::Transport) -> Nothing

Flush any buffered data in the transport.
Default implementation does nothing.

# Arguments
- `transport::Transport`: The transport instance to flush

# Returns
- `Nothing`
"""
function flush(transport::Transport)
    # Default: no-op for unbuffered transports
    nothing
end
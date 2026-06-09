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
# src/transports/stdio.jl

"""
    StdioTransport(; input::IO=stdin, output::IO=stdout)

Transport implementation using standard input/output streams.
This is the default transport for local MCP server processes.

# Fields
- `input::IO`: Input stream for reading messages (default: stdin)
- `output::IO`: Output stream for writing messages (default: stdout)  
- `connected::Bool`: Connection status (always true for stdio)
"""
mutable struct StdioTransport <: Transport
    input::IO
    output::IO
    connected::Bool
    
    function StdioTransport(; input::IO=stdin, output::IO=stdout)
        new(input, output, true)
    end
end

"""
    read_message(transport::StdioTransport) -> Union{String,Nothing}

Read a line from the input stream.

# Arguments
- `transport::StdioTransport`: The stdio transport instance

# Returns
- `Union{String,Nothing}`: The message string, or nothing if empty or EOF
"""
function read_message(transport::StdioTransport)::Union{String,Nothing}
    if !transport.connected
        return nothing
    end
    
    try
        message = readline(transport.input)
        # Check for EOF (readline returns empty string at EOF)
        if eof(transport.input) && isempty(message)
            transport.connected = false
            return nothing
        end
        # Return nothing for empty messages to skip processing
        return isempty(message) ? nothing : message
    catch e
        if e isa EOFError
            transport.connected = false
            return nothing
        else
            rethrow(e)
        end
    end
end

"""
    write_message(transport::StdioTransport, message::String) -> Nothing

Write a message to the output stream with a newline.

# Arguments
- `transport::StdioTransport`: The stdio transport instance
- `message::String`: The message to write

# Returns
- `Nothing`

# Throws
- `TransportError`: If writing fails
"""
function write_message(transport::StdioTransport, message::String)::Nothing
    if !transport.connected
        throw(TransportError("Cannot write to closed transport"))
    end
    
    try
        println(transport.output, message)
        Base.flush(transport.output)
    catch e
        throw(TransportError("Failed to write message: $e"))
    end
    
    nothing
end

"""
    close(transport::StdioTransport) -> Nothing

Mark the transport as closed. Does not actually close stdin/stdout.

# Arguments
- `transport::StdioTransport`: The stdio transport instance

# Returns
- `Nothing`
"""
function close(transport::StdioTransport)::Nothing
    transport.connected = false
    nothing
end

"""
    is_connected(transport::StdioTransport) -> Bool

Check if the stdio transport is connected.

# Arguments
- `transport::StdioTransport`: The stdio transport instance

# Returns
- `Bool`: Connection status
"""
function is_connected(transport::StdioTransport)::Bool
    transport.connected
end

"""
    flush(transport::StdioTransport) -> Nothing

Flush the output stream.

# Arguments
- `transport::StdioTransport`: The stdio transport instance

# Returns
- `Nothing`
"""
function flush(transport::StdioTransport)::Nothing
    Base.flush(transport.output)
    nothing
end

# Pretty printing
function Base.show(io::IO, transport::StdioTransport)
    status = transport.connected ? "connected" : "disconnected"
    in_desc = transport.input === stdin ? "stdin" : "custom"
    out_desc = transport.output === stdout ? "stdout" : "custom"
    print(io, "StdioTransport($in_desc→$out_desc, $status)")
end
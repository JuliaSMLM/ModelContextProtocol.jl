# src/transports/http.jl

using HTTP
using JSON3
using UUIDs: uuid4

"""
    HttpTransport(; host::String="127.0.0.1", port::Int=8080, endpoint::String="/")

Transport implementation using HTTP with chunked transfer encoding for streaming.
Follows the MCP HTTP transport specification.

# Fields
- `host::String`: Host address to bind to (default: "127.0.0.1")
- `port::Int`: Port number to listen on (default: 8080)
- `endpoint::String`: HTTP endpoint path (default: "/")
- `server::Union{HTTP.Server,Nothing}`: HTTP server instance
- `connected::Bool`: Connection status
- `server_task::Union{Task,Nothing}`: Server task handle
- `active_streams::Dict{String,HTTP.Stream}`: Active streaming connections
- `request_queue::Channel{Tuple{String,String}}`: Queue for incoming requests (id, message)
- `response_channels::Dict{String,Channel{String}}`: Response channels per request
"""
mutable struct HttpTransport <: Transport
    host::String
    port::Int
    endpoint::String
    server::Union{HTTP.Server,Nothing}
    connected::Bool
    server_task::Union{Task,Nothing}
    active_streams::Dict{String,HTTP.Stream}
    request_queue::Channel{Tuple{String,String}}
    response_channels::Dict{String,Channel{String}}
    current_request_id::Union{String,Nothing}
    
    function HttpTransport(; host::String="127.0.0.1", port::Int=8080, endpoint::String="/")
        new(
            host,
            port,
            endpoint,
            nothing,
            false,
            nothing,
            Dict{String,HTTP.Stream}(),
            Channel{Tuple{String,String}}(32),  # Buffer up to 32 requests
            Dict{String,Channel{String}}(),
            nothing
        )
    end
end

"""
    handle_request(transport::HttpTransport, stream::HTTP.Stream)

Handle incoming HTTP requests and set up streaming response.

# Arguments
- `transport::HttpTransport`: The transport instance
- `stream::HTTP.Stream`: The HTTP stream

# Returns
- `Nothing`
"""
function handle_request(transport::HttpTransport, stream::HTTP.Stream)
    request = stream.message
    method = HTTP.method(request)
    target = request.target
    path = HTTP.URI(target).path
    
    # Only handle POST requests to our endpoint
    if method != "POST" || path != transport.endpoint
        HTTP.setstatus(stream, 404)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        write(stream, "Not Found")
        return nothing
    end
    
    # Check Content-Type
    content_type = HTTP.header(request, "Content-Type", "")
    if !startswith(content_type, "application/json")
        HTTP.setstatus(stream, 415)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        write(stream, "Unsupported Media Type")
        return nothing
    end
    
    try
        # Read request body
        body = String(read(stream))
        
        # Generate unique request ID
        request_id = string(uuid4())
        
        # Create response channel for this request
        response_channel = Channel{String}(10)
        transport.response_channels[request_id] = response_channel
        transport.active_streams[request_id] = stream
        
        # Queue the request for processing
        put!(transport.request_queue, (request_id, body))
        
        # Set up streaming response headers
        HTTP.setstatus(stream, 200)
        HTTP.setheader(stream, "Content-Type" => "application/json")
        HTTP.setheader(stream, "Transfer-Encoding" => "chunked")
        HTTP.setheader(stream, "Cache-Control" => "no-cache")
        HTTP.startwrite(stream)
        
        # Handle streaming responses
        try
            while true
                # Wait for response messages
                response = take!(response_channel)
                
                # Check for end-of-stream marker
                if response == "END_STREAM"
                    break
                end
                
                # Write response as chunk
                write(stream, response)
                write(stream, "\n")  # Add newline for readability
                Base.flush(stream)
            end
        catch e
            if !(e isa InvalidStateException)
                @debug "Error in response handler" error=e
            end
        finally
            # Cleanup
            delete!(transport.active_streams, request_id)
            delete!(transport.response_channels, request_id)
            Base.close(response_channel)
        end
        
    catch e
        @error "Error handling request" error=e
        if !HTTP.iswritestarted(stream)
            HTTP.setstatus(stream, 500)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            HTTP.startwrite(stream)
            write(stream, "Internal Server Error")
        end
    end
    
    nothing
end

"""
    connect(transport::HttpTransport) -> Nothing

Start the HTTP server and begin listening for connections.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Nothing`

# Throws
- `TransportError`: If the server cannot be started
"""
function connect(transport::HttpTransport)
    if transport.connected
        return nothing
    end
    
    # Set connected before starting to avoid race condition
    transport.connected = true
    
    # Start server
    try
        @info "Starting HTTP server" host=transport.host port=transport.port endpoint=transport.endpoint
        
        # Start server in background (serve! returns immediately)
        transport.server = HTTP.serve!(transport.host, transport.port; stream=true) do stream
            handle_request(transport, stream)
        end
    catch e
        @error "Failed to start HTTP server" error=e
        transport.connected = false
        rethrow(e)
    end
    
    # Wait a moment for server to start
    sleep(0.5)
    
    @info "HTTP server started" url="http://$(transport.host):$(transport.port)$(transport.endpoint)"
    nothing
end

"""
    close(transport::HttpTransport) -> Nothing

Stop the HTTP server and close all connections.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Nothing`
"""
function close(transport::HttpTransport)::Nothing
    if !transport.connected
        return nothing
    end
    
    transport.connected = false
    
    # Send end-of-stream to all active connections
    for (id, channel) in transport.response_channels
        try
            put!(channel, "END_STREAM")
        catch
            # Channel might be closed already
        end
    end
    
    # Close request queue
    Base.close(transport.request_queue)
    
    # Stop server
    if !isnothing(transport.server)
        try
            HTTP.close(transport.server)
        catch e
            @debug "Error closing HTTP server" error=e
        end
        transport.server = nothing
    end
    
    @info "HTTP server stopped"
    nothing
end

"""
    is_connected(transport::HttpTransport) -> Bool

Check if the HTTP server is running and accepting connections.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Bool`: true if connected, false otherwise
"""
function is_connected(transport::HttpTransport)::Bool
    transport.connected
end

"""
    read_message(transport::HttpTransport) -> Union{String,Nothing}

Read a message from the request queue.
Blocks until a request is available or the transport is disconnected.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Union{String,Nothing}`: The message string, or nothing if disconnected
"""
function read_message(transport::HttpTransport)::Union{String,Nothing}
    if !transport.connected
        return nothing
    end
    
    try
        # Block until request is available
        request_id, message = take!(transport.request_queue)
        
        # Store the current request ID for response correlation
        transport.current_request_id = request_id
        
        return message
    catch e
        if e isa InvalidStateException && !isopen(transport.request_queue)
            # Channel is closed, transport is shutting down
            transport.connected = false
            return nothing
        else
            rethrow(e)
        end
    end
end

"""
    write_message(transport::HttpTransport, message::String) -> Nothing

Write a message to the current request's response stream.

# Arguments
- `transport::HttpTransport`: The transport instance
- `message::String`: The message to send

# Returns
- `Nothing`
"""
function write_message(transport::HttpTransport, message::String)::Nothing
    if !transport.connected
        return nothing
    end
    
    # Get the current request ID
    if isdefined(transport, :current_request_id) && !isnothing(transport.current_request_id)
        request_id = transport.current_request_id
        
        # Send message to the response channel
        if haskey(transport.response_channels, request_id)
            try
                put!(transport.response_channels[request_id], message)
            catch e
                @debug "Failed to write message" error=e
            end
        end
    else
        @debug "No active request to write response to"
    end
    
    nothing
end


"""
    end_response(transport::HttpTransport) -> Nothing

Signal the end of the current response stream.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Nothing`
"""
function end_response(transport::HttpTransport)::Nothing
    if !transport.connected
        return nothing
    end
    
    # Get the current request ID
    if isdefined(transport, :current_request_id) && !isnothing(transport.current_request_id)
        request_id = transport.current_request_id
        
        # Send end-of-stream marker
        if haskey(transport.response_channels, request_id)
            try
                put!(transport.response_channels[request_id], "END_STREAM")
            catch e
                @debug "Failed to end response" error=e
            end
        end
        
        # Clear current request ID
        transport.current_request_id = nothing
    end
    
    nothing
end

# Pretty printing
function Base.show(io::IO, transport::HttpTransport)
    status = transport.connected ? "connected" : "disconnected"
    active = length(transport.active_streams)
    print(io, "HttpTransport(http://$(transport.host):$(transport.port)$(transport.endpoint), $status, $active active)")
end
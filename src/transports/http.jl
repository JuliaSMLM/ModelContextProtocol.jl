# src/transports/http.jl

using HTTP
using JSON3
using UUIDs: uuid4

"""
    HttpTransport(; host::String="127.0.0.1", port::Int=8080, endpoint::String="/")

Transport implementation following the MCP Streamable HTTP specification (2025-06-18).
Supports Server-Sent Events (SSE) for streaming and session management.

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
    sse_streams::Dict{String,HTTP.Stream}  # SSE connections
    request_queue::Channel{Tuple{String,String}}
    response_channels::Dict{String,Channel{String}}
    notification_queue::Channel{String}  # For SSE notifications
    current_request_id::Union{String,Nothing}
    session_id::Union{String,Nothing}  # Session management
    session_required::Bool  # Whether session is required after init
    protocol_version::String  # MCP protocol version
    event_counter::Int64  # SSE event IDs
    allowed_origins::Vector{String}  # CORS security
    
    function HttpTransport(; 
        host::String="127.0.0.1", 
        port::Int=8080, 
        endpoint::String="/",
        allowed_origins::Vector{String}=String[],
        protocol_version::String="2025-06-18",
        session_required::Bool=false
    )
        new(
            host,
            port,
            endpoint,
            nothing,
            false,
            nothing,
            Dict{String,HTTP.Stream}(),
            Dict{String,HTTP.Stream}(),  # SSE streams
            Channel{Tuple{String,String}}(32),  # Buffer up to 32 requests
            Dict{String,Channel{String}}(),
            Channel{String}(100),  # Notification queue
            nothing,
            nothing,  # No session initially
            session_required,
            protocol_version,
            0,  # Event counter starts at 0
            allowed_origins
        )
    end
end

"""
    is_valid_session_id(session_id::String) -> Bool

Validate that a session ID contains only visible ASCII characters (0x21 to 0x7E).

# Arguments
- `session_id::String`: The session ID to validate

# Returns
- `Bool`: true if valid, false otherwise
"""
function is_valid_session_id(session_id::String)::Bool
    for char in session_id
        code = Int(char)
        if code < 0x21 || code > 0x7E
            return false
        end
    end
    return true
end

"""
    generate_session_id() -> String

Generate a cryptographically secure session ID that meets MCP requirements.
Must contain only visible ASCII characters (0x21 to 0x7E).

# Returns
- `String`: A valid session ID
"""
function generate_session_id()::String
    # Use UUID which contains only alphanumeric and hyphens (all valid ASCII)
    return string(uuid4())
end

"""
    format_sse_event(data::String; event::Union{String,Nothing}=nothing, id::Union{Int64,String,Nothing}=nothing) -> String

Format a message as a Server-Sent Event.

# Arguments
- `data::String`: The data to send
- `event::Union{String,Nothing}`: Optional event type
- `id::Union{Int64,String,Nothing}`: Optional event ID

# Returns
- `String`: Formatted SSE event
"""
function format_sse_event(data::String; event::Union{String,Nothing}=nothing, id::Union{Int64,String,Nothing}=nothing)
    parts = String[]
    
    if !isnothing(event)
        push!(parts, "event: $event")
    end
    
    if !isnothing(id)
        push!(parts, "id: $id")
    end
    
    # Split data by newlines and format each line
    for line in split(data, '\n')
        push!(parts, "data: $line")
    end
    
    # SSE events end with double newline
    return join(parts, "\n") * "\n\n"
end

"""
    handle_sse_stream(transport::HttpTransport, stream::HTTP.Stream, stream_id::String)

Handle a Server-Sent Events connection for notifications and streaming responses.

# Arguments
- `transport::HttpTransport`: The transport instance
- `stream::HTTP.Stream`: The HTTP stream
- `stream_id::String`: Unique identifier for this SSE stream

# Returns
- `Nothing`
"""
function handle_sse_stream(transport::HttpTransport, stream::HTTP.Stream, stream_id::String)
    request = stream.message
    
    # Check for Last-Event-ID header for resumption
    last_event_id = HTTP.header(request, "Last-Event-ID", "")
    if !isempty(last_event_id)
        # In a full implementation, we'd resume from this event
        @debug "SSE resumption requested" last_event_id=last_event_id
    end
    
    # Set up SSE headers
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.setheader(stream, "Connection" => "keep-alive")
    HTTP.setheader(stream, "X-Accel-Buffering" => "no")  # Disable nginx buffering
    
    # Start writing the stream
    HTTP.startwrite(stream)
    
    # Send initial connection event
    transport.event_counter += 1
    connection_event = format_sse_event(
        JSON3.write(Dict("type" => "connection", "status" => "connected")),
        event="connection",
        id=transport.event_counter
    )
    write(stream, connection_event)
    flush(stream)
    
    # Store the SSE stream
    transport.sse_streams[stream_id] = stream
    
    try
        # Keep connection alive and send notifications
        while transport.connected && isopen(stream)
            # Check for notifications to send with timeout
            notification = nothing
            ch = transport.notification_queue
            
            # Use a non-blocking check with timeout
            t = @async begin
                try
                    take!(ch)
                catch e
                    if e isa InvalidStateException
                        nothing  # Queue closed
                    else
                        rethrow(e)
                    end
                end
            end
            
            # Wait for notification with timeout
            timer = Timer(0.1)  # 100ms timeout
            notification = nothing
            while !istaskdone(t) && isopen(timer)
                sleep(0.01)
            end
            close(timer)
            
            if istaskdone(t)
                result = fetch(t)
                if isnothing(result)
                    break  # Queue closed, shutting down
                end
                notification = result
            end
            
            if !isnothing(notification)
                transport.event_counter += 1
                event = format_sse_event(
                    notification,
                    event="message",
                    id=transport.event_counter
                )
                write(stream, event)
                Base.flush(stream)
            end
        end
    catch e
        @debug "SSE stream closed" stream_id=stream_id error=e
    finally
        # Clean up
        delete!(transport.sse_streams, stream_id)
    end
end

"""
    handle_request(transport::HttpTransport, stream::HTTP.Stream)

Handle incoming HTTP requests following the Streamable HTTP specification.
Returns a single JSON response per request.

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
    
    # Handle both POST and GET requests to our endpoint
    if path != transport.endpoint
        HTTP.setstatus(stream, 404)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        write(stream, "Not Found")
        return nothing
    end
    
    # Handle GET requests for SSE notification stream
    if method == "GET"
        accept_header = HTTP.header(request, "Accept", "")
        if contains(accept_header, "text/event-stream")
            # Generate unique stream ID
            stream_id = string(uuid4())
            
            # Handle SSE stream
            handle_sse_stream(transport, stream, stream_id)
        else
            HTTP.setstatus(stream, 406)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            write(stream, "Not Acceptable - GET requests must Accept: text/event-stream")
        end
        return nothing
    end
    
    # Handle POST requests
    if method != "POST"
        HTTP.setstatus(stream, 405)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        write(stream, "Method Not Allowed")
        return nothing
    end
    
    # Check MCP-Protocol-Version header - required for 2025-06-18 spec
    client_protocol_version = HTTP.header(request, "MCP-Protocol-Version", "")
    if !isempty(client_protocol_version) && client_protocol_version != transport.protocol_version
        @debug "Unsupported protocol version" client=client_protocol_version server=transport.protocol_version
        HTTP.setstatus(stream, 400)
        HTTP.setheader(stream, "Content-Type" => "application/json")
        error_response = JSON3.write(Dict(
            "jsonrpc" => "2.0",
            "error" => Dict(
                "code" => -32602,
                "message" => "Unsupported protocol version", 
                "data" => Dict(
                    "supported" => [transport.protocol_version],
                    "requested" => client_protocol_version
                )
            ),
            "id" => nothing
        ))
        write(stream, error_response)
        return nothing
    end
    
    # Security: Validate Origin header if configured
    if !isempty(transport.allowed_origins)
        origin = HTTP.header(request, "Origin", "")
        if !isempty(origin) && !(origin in transport.allowed_origins)
            @debug "Rejected request from unauthorized origin" origin=origin
            HTTP.setstatus(stream, 403)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            write(stream, "Forbidden: Invalid Origin")
            return nothing
        end
    end
    
    # Check Content-Type first
    content_type = HTTP.header(request, "Content-Type", "")
    if !startswith(content_type, "application/json")
        HTTP.setstatus(stream, 415)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        write(stream, "Unsupported Media Type")
        return nothing
    end
    
    # Check Accept header per 2025-06-18 spec - MUST include both application/json and text/event-stream
    accept_header = HTTP.header(request, "Accept", "")
    if !contains(accept_header, "application/json") || !contains(accept_header, "text/event-stream")
        HTTP.setstatus(stream, 406)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        write(stream, "Not Acceptable: Must accept both application/json and text/event-stream")
        return nothing
    end
    
    # Check for session ID header
    session_id = HTTP.header(request, "Mcp-Session-Id", "")
    
    try
        # Read request body
        body = String(read(stream))
        
        # Parse to check if it's an initialization request
        local is_initialize = false
        local is_notification = false
        try
            msg = JSON3.read(body)
            is_initialize = get(msg, "method", "") == "initialize"
            is_notification = !haskey(msg, "id")  # Notifications don't have IDs
        catch
            # If parsing fails, let the server handle it
        end
        
        # Session validation - only check after we know if it's initialization
        if !is_initialize
            # After initialization, session may be required
            if transport.session_required && !isnothing(transport.session_id) && isempty(session_id)
                @debug "Missing required session ID"
                HTTP.setstatus(stream, 400)  # 400 Bad Request per spec
                HTTP.setheader(stream, "Content-Type" => "application/json")
                error_response = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "error" => Dict(
                        "code" => -32000,
                        "message" => "Session ID required"
                    ),
                    "id" => nothing
                ))
                write(stream, error_response)
                return nothing
            end
            
            # Validate provided session ID
            if !isempty(session_id) && !isnothing(transport.session_id) && session_id != transport.session_id
                @debug "Invalid session ID" provided=session_id expected=transport.session_id
                HTTP.setstatus(stream, 400)  # 400 Bad Request per spec (not 401)
                HTTP.setheader(stream, "Content-Type" => "application/json")
                error_response = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "error" => Dict(
                        "code" => -32000,
                        "message" => "Invalid session"
                    ),
                    "id" => nothing
                ))
                write(stream, error_response)
                return nothing
            end
        end
        
        # Generate session ID on initialization if not exists
        if is_initialize && isnothing(transport.session_id)
            transport.session_id = generate_session_id()
            @debug "Generated session ID" session_id=transport.session_id
            # Don't automatically require session - let server config decide
        end
        
        # For notifications, return 202 Accepted immediately
        if is_notification
            HTTP.setstatus(stream, 202)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            HTTP.setheader(stream, "MCP-Protocol-Version" => transport.protocol_version)
            if !isnothing(transport.session_id)
                HTTP.setheader(stream, "Mcp-Session-Id" => transport.session_id)
            end
            HTTP.setheader(stream, "Content-Length" => "0")
            # No body for 202 Accepted per spec
            HTTP.startwrite(stream)  # Ensure headers are sent
            
            # Still queue the notification for processing
            put!(transport.request_queue, ("notification-" * string(uuid4()), body))
            return nothing
        end
        
        # Generate unique request ID
        request_id = string(uuid4())
        
        # Create response channel for this request (buffer size 1 for single response)
        response_channel = Channel{String}(1)
        transport.response_channels[request_id] = response_channel
        transport.active_streams[request_id] = stream
        
        # Queue the request for processing
        put!(transport.request_queue, (request_id, body))
        
        # Wait for the single response
        try
            response = take!(response_channel)
            
            # Check if we should send via SSE or direct response
            accept_header = HTTP.header(request, "Accept", "")
            use_sse = contains(accept_header, "text/event-stream") && !isempty(transport.sse_streams)
            
            if use_sse && length(transport.sse_streams) > 0
                # Send response via SSE stream
                for (_, sse_stream) in transport.sse_streams
                    try
                        transport.event_counter += 1
                        event = format_sse_event(
                            response,
                            event="response",
                            id=transport.event_counter
                        )
                        write(sse_stream, event)
                        flush(sse_stream)
                    catch e
                        @debug "Failed to write to SSE stream" error=e
                    end
                end
                
                # Still send 200 OK for the POST request
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type" => "application/json")
                HTTP.setheader(stream, "MCP-Protocol-Version" => transport.protocol_version)
                if !isnothing(transport.session_id)
                    HTTP.setheader(stream, "Mcp-Session-Id" => transport.session_id)
                end
                write(stream, response)
            else
                # Write the response directly
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type" => "application/json")
                HTTP.setheader(stream, "Cache-Control" => "no-cache")
                HTTP.setheader(stream, "MCP-Protocol-Version" => transport.protocol_version)
                if !isnothing(transport.session_id)
                    HTTP.setheader(stream, "Mcp-Session-Id" => transport.session_id)
                end
                write(stream, response)
            end
            
        catch e
            if !(e isa InvalidStateException)
                @debug "Error waiting for response" error=e
                if !HTTP.iswritestarted(stream)
                    HTTP.setstatus(stream, 500)
                    HTTP.setheader(stream, "Content-Type" => "application/json")
                    error_response = JSON3.write(Dict(
                        "jsonrpc" => "2.0",
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Internal error"
                        ),
                        "id" => nothing
                    ))
                    write(stream, error_response)
                end
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
            HTTP.setheader(stream, "Content-Type" => "application/json")
            error_response = JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "error" => Dict(
                    "code" => -32603,
                    "message" => "Internal error: $(e)"
                ),
                "id" => nothing
            ))
            write(stream, error_response)
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
    
    # Close all response channels
    for (id, channel) in transport.response_channels
        try
            Base.close(channel)
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

Write a message to the current request's response channel.
The request handler will send this as the HTTP response.

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
                # Clear current request ID after sending response
                transport.current_request_id = nothing
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
    send_notification(transport::HttpTransport, notification::String) -> Nothing

Send a notification to all connected SSE streams.

# Arguments
- `transport::HttpTransport`: The transport instance
- `notification::String`: The notification message to send

# Returns
- `Nothing`
"""
function send_notification(transport::HttpTransport, notification::String)::Nothing
    if !transport.connected
        return nothing
    end
    
    # Queue notification for SSE streams
    try
        put!(transport.notification_queue, notification)
    catch e
        @debug "Failed to queue notification" error=e
    end
    
    nothing
end

"""
    broadcast_to_sse(transport::HttpTransport, message::String; event::String="message") -> Nothing

Broadcast a message immediately to all SSE streams.

# Arguments
- `transport::HttpTransport`: The transport instance
- `message::String`: The message to broadcast
- `event::String`: The event type (default: "message")

# Returns
- `Nothing`
"""
function broadcast_to_sse(transport::HttpTransport, message::String; event::String="message")::Nothing
    if isempty(transport.sse_streams)
        return nothing
    end
    
    transport.event_counter += 1
    sse_event = format_sse_event(
        message,
        event=event,
        id=transport.event_counter
    )
    
    # Send to all SSE streams
    for (stream_id, stream) in transport.sse_streams
        try
            write(stream, sse_event)
            flush(stream)
        catch e
            @debug "Failed to write to SSE stream" stream_id=stream_id error=e
            # Remove dead streams
            delete!(transport.sse_streams, stream_id)
        end
    end
    
    nothing
end

"""
    end_response(transport::HttpTransport) -> Nothing

Deprecated: No longer needed as HTTP transport now sends complete responses.
This method exists for backward compatibility but does nothing.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Nothing`
"""
function end_response(transport::HttpTransport)::Nothing
    # No-op: responses are now sent immediately in write_message
    nothing
end

# Pretty printing
function Base.show(io::IO, transport::HttpTransport)
    status = transport.connected ? "connected" : "disconnected"
    active = length(transport.active_streams)
    print(io, "HttpTransport(http://$(transport.host):$(transport.port)$(transport.endpoint), $status, $active active)")
end
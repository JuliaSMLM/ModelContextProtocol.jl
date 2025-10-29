# src/core/server.jl


"""
    register!(server::Server, component::Union{Tool,Resource,MCPPrompt}) -> Server

Register a tool, resource, or prompt with the MCP server.

# Arguments
- `server::Server`: The server to register the component with
- `component`: The component to register (can be a tool, resource, or prompt)

# Returns
- `Server`: The server instance for method chaining
"""
function register! end

function register!(server::Server, tool::Tool)
    push!(server.tools, tool)
    server
end

function register!(server::Server, resource::Resource)
    push!(server.resources, resource)
    server
end

function register!(server::Server, prompt::MCPPrompt)
    push!(server.prompts, prompt)
    server
end

"""
    process_message(server::Server, state::ServerState, message::String) -> Union{String,Nothing}

Process an incoming JSON-RPC message and generate an appropriate response.

# Arguments
- `server::Server`: The MCP server instance
- `state::ServerState`: Current server state
- `message::String`: Raw JSON-RPC message to process

# Returns
- `Union{String,Nothing}`: A serialized response string or nothing for notifications
"""
function process_message(server::Server, state::ServerState, message::String)::Union{String,Nothing}
    # Parse the incoming message
    parsed = try
        @debug "Parsing message"
        parse_message(message)
    catch e
        error_info = ErrorInfo(
            code = ErrorCodes.PARSE_ERROR,
            message = "Failed to parse message: $(e)"
        )
        # Log the error
        @error "JSON-RPC error" error_code=ErrorCodes.PARSE_ERROR error_message=error_info.message

        # Return JSON-RPC error response
        return serialize_message(JSONRPCError(
            id = nothing,
            error = error_info
        ))
    end
  
    if parsed isa JSONRPCError
        return serialize_message(parsed)
    end
    
    try
        if parsed isa JSONRPCRequest
            # Handle request
            response = handle_request(server, parsed)
            return serialize_message(response) # Make sure to serialize the response
        elseif parsed isa JSONRPCNotification 
            handle_notification(RequestContext(server=server), parsed)
            return nothing
        end
    catch e
        id = if parsed isa JSONRPCRequest
            parsed.id
        else
            nothing
        end

        error_info = ErrorInfo(
            code = ErrorCodes.INTERNAL_ERROR,
            message = "Internal server error: $(e)"
        )
        # Log the error
        @error "JSON-RPC error" error_code=ErrorCodes.INTERNAL_ERROR error_message=error_info.message request=parsed

        # Return JSON-RPC error response
        return serialize_message(JSONRPCError(
            id = id,
            error = error_info
        ))
    end
end

"""
    run_server_loop(server::Server, state::ServerState; log_file::Union{String,Nothing}=nothing) -> Nothing

Execute the main server loop that reads JSON-RPC messages from stdin and writes responses to stdout.
Implements optimized CPU usage by blocking on input rather than active polling.

# Arguments
- `server::Server`: The MCP server instance
- `state::ServerState`: The server state object to track running status
- `log_file::Union{String,Nothing}`: Optional file path for logging all stdio communication

# Returns
- `Nothing`: The function runs until interrupted or state.running becomes false
"""
function run_server_loop(server::Server, state::ServerState; log_file::Union{String,Nothing}=nothing)
    state.running = true

    # Open log file if specified
    log_io = if !isnothing(log_file)
        open(log_file, "w")
    else
        nothing
    end

    @debug "Server loop starting"
    flush(stdout)
    flush(stderr)
    
    # Pre-allocate common error responses to reduce allocations
    error_templates = Dict{Int, ErrorInfo}(
        ErrorCodes.PARSE_ERROR => ErrorInfo(
            code = ErrorCodes.PARSE_ERROR,
            message = "Failed to parse message"
        ),
        ErrorCodes.INTERNAL_ERROR => ErrorInfo(
            code = ErrorCodes.INTERNAL_ERROR,
            message = "Internal server error"
        )
    )
    
    while state.running
        try
            # readline() is already blocking, so it doesn't consume CPU while waiting
            message = readline()

            # Skip empty messages to avoid unnecessary processing
            isempty(message) && continue

            # Log incoming message
            if !isnothing(log_io)
                timestamp = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS.sss")
                println(log_io, "[$timestamp] REQUEST:")
                println(log_io, message)
                println(log_io, "---")
                flush(log_io)
            end

            # Process the message only if non-empty
            @debug "Processing message" raw=message
            response = process_message(server, state, message)

            if !isnothing(response)
                @debug "Sending response" response=response

                # Log outgoing response
                if !isnothing(log_io)
                    timestamp = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS.sss")
                    println(log_io, "[$timestamp] RESPONSE:")
                    println(log_io, response)
                    println(log_io, "---")
                    flush(log_io)
                end

                println(response)
                flush(stdout)
            end
        catch e
            if e isa InterruptException
                @info "Server shutting down..."
                break
            elseif e isa EOFError
                @info "Input stream closed, shutting down..."
                break
            end
            
            @error "Error processing message" exception=e
            
            # Try to send error response with pre-allocated template
            try
                error_info = get(error_templates, ErrorCodes.INTERNAL_ERROR, 
                    ErrorInfo(
                        code = ErrorCodes.INTERNAL_ERROR,
                        message = "Internal server error: $(e)"
                    )
                )
                
                error_response = serialize_message(JSONRPCError(
                    id = nothing,
                    error = error_info
                ))

                # Log error response
                if !isnothing(log_io)
                    timestamp = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS.sss")
                    println(log_io, "[$timestamp] ERROR RESPONSE:")
                    println(log_io, error_response)
                    println(log_io, "---")
                    flush(log_io)
                end

                println(error_response)
                flush(stdout)
            catch response_error
                @error "Failed to send error response" exception=response_error
            end
        end
    end

    # Close log file if it was opened
    if !isnothing(log_io)
        close(log_io)
    end
end

"""
    start!(server::Server; log_file::Union{String,Nothing}=nothing) -> Nothing

Start the MCP server, setting up logging and entering the main server loop.

# Arguments
- `server::Server`: The server instance to start
- `log_file::Union{String,Nothing}`: Optional file path for logging all stdio communication

# Returns
- `Nothing`: The function returns after the server stops

# Throws
- `ServerError`: If the server is already running
"""
function start!(server::Server; log_file::Union{String,Nothing}=nothing)::Nothing
    if server.active
        # Use MCPLogger format for errors
        @error "Server already running"
        throw(ServerError("Server already running"))
    end

    state = ServerState()

    # Set up MCP-compliant logging
    logger = MCPLogger(stderr, Logging.Info)
    global_logger(logger)

    @info "Starting MCP server: $(server.config.name)"
    if !isnothing(log_file)
        @info "Logging stdio to: $log_file"
    end

    try
        run_server_loop(server, state; log_file=log_file)
    catch e
        server.active = false
        @error "Server error" exception=e
        rethrow(e)
    finally
        server.active = false
        @info "Server stopped"
    end

    nothing
end

"""
    stop!(server::Server) -> Nothing

Stop a running MCP server.

# Arguments
- `server::Server`: The server instance to stop

# Returns
- `Nothing`: The function returns after setting the server to inactive

# Throws
- `ServerError`: If the server is not currently running
"""
function stop!(server::Server)
    if !server.active
        throw(ServerError("Server not running"))
    end
    
    server.active = false
    nothing
end

"""
    subscribe!(server::Server, uri::String, callback::Function) -> Server

Subscribe to updates for a specific resource identified by URI.

# Arguments
- `server::Server`: The server instance
- `uri::String`: The resource URI to subscribe to
- `callback::Function`: The function to call when the resource is updated

# Returns
- `Server`: The server instance for method chaining
"""
function subscribe!(server::Server, uri::String, callback::Function)
    subscription = Subscription(uri, callback, now())
    push!(server.subscriptions[uri], subscription)
    server
end

"""
    unsubscribe!(server::Server, uri::String, callback::Function) -> Server

Remove a subscription for a specific resource URI and callback function.

# Arguments
- `server::Server`: The server instance
- `uri::String`: The resource URI to unsubscribe from
- `callback::Function`: The callback function to remove

# Returns
- `Server`: The server instance for method chaining
"""
function unsubscribe!(server::Server, uri::String, callback::Function)
    filter!(s -> s.callback !== callback, server.subscriptions[uri])
    server
end

# Pretty printing
Base.show(io::IO, config::ServerConfig) = print(io, "ServerConfig($(config.name) v$(config.version))")
Base.show(io::IO, server::Server) = print(io, "MCP Server($(server.config.name), $(server.active ? "active" : "inactive"))")



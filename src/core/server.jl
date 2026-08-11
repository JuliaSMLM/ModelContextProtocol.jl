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
    # SEP-2243: annotations are validated against the NORMALIZED schema (what
    # tools/list will advertise) — invalid ones are rejected at registration
    # instead of being advertised to clients that would have to discard the
    # tool — and the resulting mirror table is persisted for the
    # handle_modern_request preflight. For register!-managed tools the three
    # artifacts (advertised schema, validation, enforcement) cannot diverge;
    # direct mutation of server fields bypasses this like any raw mutation.
    if tool isa MCPTool
        server.tool_header_paths[tool.name] = validate_tool_headers(tool)
        # Same-name re-registration REPLACES the tool: dispatch resolves by
        # first match, so appending would leave the OLD handler active while
        # the persisted mirror table already described the new tool
        idx = findfirst(t -> t isa MCPTool && t.name == tool.name, server.tools)
        if idx !== nothing
            server.tools[idx] = tool
            return server
        end
    end
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

function register!(server::Server, template::ResourceTemplate)
    push!(server.resource_templates, template)
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
function process_message(server::Server, state::ServerState, message::String;
                         authenticated_user=nothing,
                         param_headers=nothing)::Union{String,Nothing}
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

    # Era resolved: everything except a modern-era request (notifications, legacy
    # requests) may deliver log records to the client again. Modern requests keep
    # the suppression the loop armed; handle_modern_request re-asserts it for
    # callers that don't go through the loop.
    if !(parsed isa JSONRPCRequest && parsed.meta.protocol_version !== nothing)
        task_local_storage(:mcp_suppress_log_notifications, false)
    end

    try
        if parsed isa JSONRPCRequest
            # Handle request. A nothing response means the handler deferred it
            # (e.g. a blocking tasks/result) — a background task will deliver the
            # response via deliver_response when ready, so the loop sends nothing.
            response = handle_request(server, state, parsed; authenticated_user=authenticated_user,
                                      param_headers=param_headers)
            return isnothing(response) ? nothing : serialize_message(response)
        elseif parsed isa JSONRPCNotification
            handle_notification(RequestContext(server=server, state=state, authenticated_user=authenticated_user), parsed)
            return nothing
        end
    catch e
        # Only return error responses for requests, not notifications
        if parsed isa JSONRPCRequest
            error_info = ErrorInfo(
                code = ErrorCodes.INTERNAL_ERROR,
                message = "Internal server error: $(e)"
            )
            # Log the error
            @error "JSON-RPC error" error_code=ErrorCodes.INTERNAL_ERROR error_message=error_info.message
            # Return JSON-RPC error response
            return serialize_message(JSONRPCError(
                id = parsed.id,
                error = error_info
            ))
        else
            # For notifications, just log the error and return nothing
            @error "Notification processing error" error=e
            return nothing
        end
    end
end

"""
    run_server_loop(server::Server, state::ServerState) -> Nothing

Execute the main server loop that reads JSON-RPC messages from the transport and writes responses back.
Implements optimized CPU usage by blocking on input rather than active polling.

# Arguments
- `server::Server`: The MCP server instance with configured transport
- `state::ServerState`: The server state object to track running status

# Returns
- `Nothing`: The function runs until interrupted or state.running becomes false
"""
function run_server_loop(server::Server, state::ServerState)
    state.running = true
    
    # Ensure transport is available
    if isnothing(server.transport)
        throw(ServerError("No transport configured"))
    end
    
    transport = server.transport
    
    @debug "Server loop starting"
    flush(transport)
    
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
    
    # server.active is part of the run condition so that stop! ends the loop while
    # the transport is STILL OPEN — the shutdown path must deliver each
    # subscriptions/listen stream's graceful closing result before the transport
    # (and its channels) are torn down. HTTP's read_message returns nothing after a
    # bounded wait precisely so this condition is re-checked regularly.
    while server.active && state.running && is_connected(transport)
        try
            message = read_message(transport)

            # Handle different message conditions
            if isnothing(message)
                # For HTTP transport, keep running even without messages (the
                # bounded wait inside read_message already paced the loop)
                if isa(transport, HttpTransport)
                    continue
                else
                    # For stdio transport, null message means EOF
                    break
                end
            elseif isempty(message)
                # Skip empty messages (e.g., blank lines between requests)
                continue
            end
            
            # Process the message. The task-local notification route lets
            # send_notification deliver request-scoped notifications (progress, log
            # messages) onto this request's response stream; background tasks never
            # inherit it, so their notifications stay on the out-of-band channel.
            # The route must cover this loop's own @debug lines too — at setLevel
            # "debug" they become notifications, and routed to a per-request channel
            # they can never block the loop, whereas the out-of-band queue has no
            # guaranteed consumer.
            # Log-notification suppression is re-armed per message and defaults ON:
            # the era of a message is unknown until it is parsed, and a modern
            # request must never receive notifications/message (its client set no
            # logLevel). process_message flips the flag OFF once the message
            # resolves as legacy; a modern request keeps it on through the whole
            # iteration, covering pre-parse and post-dispatch @debug lines alike.
            # (Cost: the pre-parse "Processing message" debug line is stderr-only
            # even for legacy debug sessions — era is genuinely unknown there.)
            task_local_storage(:mcp_suppress_log_notifications, true)
            task_local_storage(:mcp_notification_route, notification_route(transport))
            try
                @debug "Processing message" raw=message
                response = process_message(server, state, message; authenticated_user=pending_auth_context(transport),
                                           param_headers=pending_param_headers(transport))

                # Keep the transport's advertised version in sync with the negotiated one
                # (set by handle_initialize) so e.g. HTTP response headers echo it
                isnothing(state.protocol_version) || set_negotiated_version!(transport, state.protocol_version)

                if !isnothing(response)
                    @debug "Sending response" response=response
                    write_message(transport, response)
                end
            finally
                task_local_storage(:mcp_notification_route, nothing)
            end
        catch e
            if e isa InterruptException
                @info "Server shutting down..."
                break
            elseif e isa TransportError
                @error "Transport error" exception=e
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
                write_message(transport, error_response)
            catch response_error
                @error "Failed to send error response" exception=response_error
            end
        end
    end
    
    @debug "Server loop ended"
end

"""
    start!(server::Server; transport::Union{Transport,Nothing}=nothing) -> Nothing

Start the MCP server, setting up logging and entering the main server loop.

# Arguments
- `server::Server`: The server instance to start
- `transport::Union{Transport,Nothing}`: Optional transport to use. If not provided, uses StdioTransport

# Returns
- `Nothing`: The function returns after the server stops

# Throws
- `ServerError`: If the server is already running
"""
function start!(server::Server; transport::Union{Transport,Nothing}=nothing)::Nothing
    if server.active
        # Use MCPLogger format for errors
        @error "Server already running"
        throw(ServerError("Server already running"))
    end
    
    # Set transport - use provided transport, server's existing transport, or default to stdio
    if !isnothing(transport)
        server.transport = transport
    elseif isnothing(server.transport)
        server.transport = StdioTransport()
    end
    # else: use server's existing transport
    
    state = ServerState()
    # Expose the loop's session state on the server so the exported notify_*
    # helpers (called with only `server`) can reach wire_subscriptions
    server.legacy_state = state

    # Set up MCP-compliant logging. The logger delivers notifications/message to the
    # client over the transport once the session initializes (handle_initialize flips
    # transport_active); until then — and after shutdown — records fall back to stderr.
    logger = MCPLogger(stderr, Logging.Info)
    logger.transport = server.transport
    global_logger(logger)

    @info "Starting MCP server: $(server.config.name)"

    task_queue = nothing
    try
        server.active = true
        # A restart after stop! (or a previous loop exit) needs a fresh
        # notifications/tasks dispatcher — its queue was closed on shutdown.
        # THIS run's queue is captured locally: the finally must close its own
        # generation only, never a fresh queue an overlapping restart installed.
        ensure_task_notifications!(server)
        task_queue = server.task_notification_queue
        run_server_loop(server, state)
    catch e
        server.active = false
        @error "Server error" exception=e
        rethrow(e)
    finally
        server.active = false
        # Retire the session state on EVERY loop exit: notify_* called after
        # shutdown must see no legacy session, not a stale one whose transport
        # is being torn down (a restart installs a fresh state)
        server.legacy_state = nothing
        logger.transport_active[] = false
        # End subscriptions/listen streams gracefully (an empty result on each
        # listen request) BEFORE the transport goes away, so clients can tell an
        # orderly shutdown from an abrupt drop
        try
            close_subscriptions!(server)
        catch e
            @debug "Error closing subscription streams" error=e
        end
        # End THIS run's notifications/tasks dispatcher on EVERY loop exit (EOF
        # included, where stop! never runs): a parked dispatcher would otherwise
        # retain the server past its lifetime. Generation-local on purpose — an
        # overlapping stop!/start! may already run a fresh queue, which this
        # run's teardown must not touch.
        task_queue === nothing || Base.close(task_queue)
        close(server.transport)
        @info "Server stopped"
    end

    nothing
end

"""
    stop!(server::Server) -> Nothing

Stop a running MCP server: the server loop observes `active == false` on its next
iteration and exits with the transport still open, so shutdown can deliver each
`subscriptions/listen` stream's graceful closing result before the transport closes.

On HTTP this takes effect within the loop's bounded read wait. On stdio the loop
blocks in `readline`, so `stop!` only takes effect when the next message — or EOF —
arrives; the normal stdio lifecycle ends via stdin EOF, which runs the same
graceful-closure path.

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
    # End the notifications/tasks dispatcher (its FIFO drains, then the consumer
    # exits); post-stop transitions simply stop pushing (the enqueue hook's
    # put! on a closed channel is swallowed by _fire_status_change)
    if server.task_notification_queue !== nothing
        Base.close(server.task_notification_queue)
    end
    nothing
end

"""
    subscribe!(server::Server, uri::String, callback::Function) -> Server

Subscribe to updates for a specific resource identified by URI.

The callback is an in-process observer: [`notify_resource_updated`](@ref) invokes
it as `callback(uri)` whenever that URI is announced as changed. It runs on the
announcing task, its errors are logged and swallowed, and it sends nothing to
clients on its own (client delivery is `notify_resource_updated`'s job).

# Arguments
- `server::Server`: The server instance
- `uri::String`: The resource URI to subscribe to
- `callback::Function`: Called as `callback(uri::String)` on each announced update

# Returns
- `Server`: The server instance for method chaining
"""
function subscribe!(server::Server, uri::String, callback::Function)
    subscription = Subscription(uri, callback, now())
    lock(server.subscriptions_lock) do
        push!(server.subscriptions[uri], subscription)
    end
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
    lock(server.subscriptions_lock) do
        filter!(s -> s.callback !== callback, server.subscriptions[uri])
    end
    server
end




# src/protocol/jsonrpc.jl

const REQUEST_PARAMS_MAP = Dict{String,Type}(
    "initialize" => InitializeParams,
    "resources/list" => ListResourcesParams,
    "resources/read" => ReadResourceParams,
    "resources/templates/list" => ListResourceTemplatesParams,
    "resources/subscribe" => SubscribeParams,
    "resources/unsubscribe" => UnsubscribeParams,
    "subscriptions/listen" => SubscriptionsListenParams,
    "tools/call" => CallToolParams,
    "tools/list" => ListToolsParams,
    "prompts/list" => ListPromptsParams,
    "prompts/get" => GetPromptParams,
    "logging/setLevel" => SetLevelParams,
    "tasks/get" => GetTaskParams,
    "tasks/result" => TaskResultParams,
    "tasks/cancel" => CancelTaskParams,
    "tasks/update" => UpdateTaskParams,
    "tasks/list" => ListTasksParams,
    "notifications/progress" => ProgressParams
)

"""
    get_params_type(method::String) -> Union{Type,Nothing}

Get the appropriate parameter type for a given JSON-RPC method name.

# Arguments
- `method::String`: The JSON-RPC method name

# Returns
- `Union{Type,Nothing}`: The Julia type to use for parsing parameters, or `nothing` if no specific type is defined
"""
function get_params_type(method::String)::Union{Type,Nothing}
    get(REQUEST_PARAMS_MAP, method, nothing)
end

"""
    get_result_type(id::RequestId) -> Union{Type{<:ResponseResult},Nothing}

Get the expected result type for a response based on the request ID.

# Arguments
- `id::RequestId`: The request ID to look up

# Returns
- `Union{Type{<:ResponseResult},Nothing}`: The expected response result type, or `nothing` if not known

Note: This is a placeholder that needs to be implemented with request tracking.
"""
function get_result_type(id::RequestId)::Union{Type{<:ResponseResult},Nothing}
    # This would need to track request types to know what response type to expect
    nothing
end

"""
    parse_message(json::String) -> MCPMessage

Parse a JSON-RPC message string into the appropriate typed message object.

# Arguments
- `json::String`: The raw JSON-RPC message string

# Returns
- `MCPMessage`: A typed MCPMessage subtype (JSONRPCRequest, JSONRPCResponse, JSONRPCNotification, or JSONRPCError)
"""
function parse_message(json::String)::MCPMessage
    raw = try
        JSON3.read(json)
    catch e
        return JSONRPCError(
            id = nothing,
            error = ErrorInfo(
                code = ErrorCodes.PARSE_ERROR,
                message = "Invalid JSON: $(e)"
            )
        )
    end
    
    # MCP protocol 2025-06-18 removes support for JSON-RPC batching
    if raw isa Array || raw isa Vector
        return JSONRPCError(
            id = nothing,
            error = ErrorInfo(
                code = ErrorCodes.INVALID_REQUEST,
                message = "JSON-RPC batching not supported in MCP protocol 2025-06-18"
            )
        )
    end
    
    # Ensure we have an object, not array
    if !(raw isa JSON3.Object)
        return JSONRPCError(
            id = nothing,
            error = ErrorInfo(
                code = ErrorCodes.INVALID_REQUEST,
                message = "JSON-RPC batching not supported in MCP protocol 2025-06-18"
            )
        )
    end
    
    # Validate basic JSON-RPC structure
    if !haskey(raw, :jsonrpc) || raw.jsonrpc != "2.0"
        return JSONRPCError(
            id = get(raw, :id, nothing),
            error = ErrorInfo(
                code = ErrorCodes.INVALID_REQUEST,
                message = "Invalid JSON-RPC: missing or invalid jsonrpc version"
            )
        )
    end
    
    # Parse based on message type
    try
        if haskey(raw, :method)
            # Request or notification
            if haskey(raw, :id)
                parse_request(raw)
            else
                parse_notification(raw)
            end
        elseif haskey(raw, :result)
            parse_success_response(raw)
        elseif haskey(raw, :error)
            parse_error_response(raw)
        else
            JSONRPCError(
                id = get(raw, :id, nothing),
                error = ErrorInfo(
                    code = ErrorCodes.INVALID_REQUEST,
                    message = "Invalid JSON-RPC message structure"
                )
            )
        end
    catch e
        JSONRPCError(
            id = get(raw, :id, nothing),
            error = ErrorInfo(
                code = ErrorCodes.INTERNAL_ERROR,
                message = "Error parsing message: $(e)"
            )
        )
    end
end

"""
    parse_request(raw::JSON3.Object) -> Request

Parse a JSON-RPC request object into a typed Request struct.

# Arguments
- `raw::JSON3.Object`: The parsed JSON object representing a request

# Returns
- `Request`: A JSONRPCRequest with properly typed parameters based on the method
"""
function parse_request(raw::JSON3.Object)::Request
    method = raw.method

    # Extract from params._meta: the optional progress token (see RequestContext /
    # send_progress) and the modern-era (2026-07-28+) per-request protocol fields.
    # A present io.modelcontextprotocol/protocolVersion STRING marks the request as
    # modern-era and routes it through handle_modern_request. All _meta values are
    # attacker-controlled: a non-object _meta is ignored, non-string versions are
    # treated as absent, and the capability/info objects are kept as raw parsed
    # views (no re-encoding copy).
    progress_token = nothing
    protocol_version = nothing
    client_capabilities = nothing
    client_info = nothing
    log_level = nothing
    has_log_level = false
    if haskey(raw, :params) && raw.params isa JSON3.Object && haskey(raw.params, :_meta)
        meta = raw.params._meta
        if meta isa JSON3.Object
            if haskey(meta, :progressToken)
                progress_token = meta.progressToken
            end
            if haskey(meta, Symbol(META_PROTOCOL_VERSION))
                v = meta[Symbol(META_PROTOCOL_VERSION)]
                v isa AbstractString && (protocol_version = String(v))
            end
            if haskey(meta, Symbol(META_CLIENT_CAPABILITIES))
                caps = meta[Symbol(META_CLIENT_CAPABILITIES)]
                caps isa JSON3.Object && (client_capabilities = caps)
            end
            if haskey(meta, Symbol(META_CLIENT_INFO))
                info = meta[Symbol(META_CLIENT_INFO)]
                info isa JSON3.Object && (client_info = info)
            end
            if haskey(meta, Symbol(META_LOG_LEVEL))
                has_log_level = true
                lv = meta[Symbol(META_LOG_LEVEL)]
                lv isa AbstractString && (log_level = String(lv))
            end
        end
    end

    # MRTR (2026-07-28): on modern requests to the three methods that may answer
    # input_required, harvest the retry fields and compute the canonical digest of
    # the ORIGINAL params (everything except _meta and the retry fields) — the
    # digest is what binds an issued requestState to the exact request it resumes.
    input_responses = nothing
    request_state = nothing
    has_input_responses = false
    has_request_state = false
    params_digest = nothing
    if protocol_version !== nothing && method in MRTR_METHODS &&
       haskey(raw, :params) && raw.params isa JSON3.Object
        has_input_responses = haskey(raw.params, :inputResponses)
        ir = get(raw.params, :inputResponses, nothing)
        if ir isa JSON3.Object
            input_responses = Dict{String,Any}(String(k) => v for (k, v) in pairs(ir))
        end
        has_request_state = haskey(raw.params, :requestState)
        rs = get(raw.params, :requestState, nothing)
        rs isa AbstractString && (request_state = String(rs))
        params_digest = canonical_json_digest(LittleDict{String,Any}(
            String(k) => v for (k, v) in pairs(raw.params)
            if !(k in (:_meta, :inputResponses, :requestState))))
    end

    params_type = get_params_type(method)
    typed_params = if !isnothing(params_type) && haskey(raw, :params) && raw.params isa JSON3.Object
        if isempty(raw.params)
            # Construct default instance instead of nothing. A type with required
            # fields (e.g. UpdateTaskParams) has no zero-arg constructor — fall to
            # nothing so era dispatch answers (-32601 on legacy, -32602 on modern)
            # instead of the construction error aborting the parse
            try
                params_type()
            catch
                nothing
            end
        elseif protocol_version !== nothing
            # Modern-era request: typed-param failures must not abort parsing with
            # a raw exception — the era handler owns validation and answers -32601
            # (method removed) or -32602 (invalid params) as appropriate
            try
                StructTypes.constructfrom(params_type, raw.params)
            catch
                nothing
            end
        else
            StructTypes.constructfrom(params_type, raw.params)
        end
    else
        nothing
    end

    JSONRPCRequest(
        id = raw.id,
        method = method,
        params = typed_params,
        meta = RequestMeta(
            progress_token = progress_token,
            protocol_version = protocol_version,
            client_capabilities = client_capabilities,
            client_info = client_info,
            log_level = log_level,
            has_log_level = has_log_level,
            input_responses = input_responses,
            request_state = request_state,
            has_input_responses = has_input_responses,
            has_request_state = has_request_state,
            params_digest = params_digest
        )
    )
end

"""
    parse_notification(raw::JSON3.Object) -> Notification

Parse a JSON-RPC notification object into a typed Notification struct.

# Arguments
- `raw::JSON3.Object`: The parsed JSON object representing a notification

# Returns
- `Notification`: A JSONRPCNotification with properly typed parameters if possible
"""
function parse_notification(raw::JSON3.Object)::Notification
    method = raw.method
    params = if haskey(raw, :params)
        # Handle empty params object case
        if isempty(raw.params)
            Dict{String,Any}()
        else
            # Convert JSON3.Object to Dict more carefully to avoid MethodError
            try
                Dict{String,Any}(raw.params)
            catch e
                # If conversion fails, convert manually to preserve all fields
                Dict{String,Any}(string(k) => v for (k, v) in pairs(raw.params))
            end
        end
    else
        Dict{String,Any}() 
    end
    
    # Parse method-specific parameters
    typed_params = try
        params_type = get_params_type(method)
        if params_type === nothing || isempty(params)
            params
        else
            JSON3.read(JSON3.write(params), params_type)
        end
    catch e
        # Notifications can't return errors, so just use raw params
        params
    end
    
    JSONRPCNotification(
        method = method,
        params = typed_params
    )
end

"""
    parse_success_response(raw::JSON3.Object) -> Response

Parse a successful JSON-RPC response object into a typed Response struct.

# Arguments
- `raw::JSON3.Object`: The parsed JSON object representing a successful response

# Returns
- `Response`: A JSONRPCResponse with properly typed result if possible, or JSONRPCError if parsing fails
"""
function parse_success_response(raw::JSON3.Object)::Response
    result_type = get_result_type(raw.id)
    
    typed_result = if result_type !== nothing
        try
            JSON3.read(JSON3.write(raw.result), result_type)
        catch e
            return JSONRPCError(
                id = raw.id,
                error = ErrorInfo(
                    code = ErrorCodes.INTERNAL_ERROR,
                    message = "Failed to parse result: $(e)"
                )
            )
        end
    else
        raw.result
    end
    
    JSONRPCResponse(
        id = raw.id,
        result = typed_result
    )
end

"""
    parse_error_response(raw::JSON3.Object) -> Response

Parse a JSON-RPC error response object into a typed Response struct.

# Arguments
- `raw::JSON3.Object`: The parsed JSON object representing an error response

# Returns
- `Response`: A JSONRPCError with properly typed error information
"""
function parse_error_response(raw::JSON3.Object)::Response
    JSONRPCError(
        id = raw.id,
        error = JSON3.read(JSON3.write(raw.error), ErrorInfo)
    )
end

"""
    serialize_message(msg::MCPMessage) -> String

Serialize an MCP message object into a JSON-RPC compliant string.

# Arguments
- `msg::MCPMessage`: The message object to serialize (Request, Response, Notification, or Error)

# Returns
- `String`: A JSON string representation of the message following the JSON-RPC 2.0 specification
"""
function serialize_message(msg::MCPMessage)::String
    if msg isa JSONRPCRequest
        dict = LittleDict{String,Any}(
            "jsonrpc" => "2.0",
            "id" => msg.id,
            "method" => msg.method
        )
        
        # Add params if present
        if !isnothing(msg.params)
            dict["params"] = msg.params
        end
        
        # Add metadata if present
        if !isnothing(msg.meta.progress_token)
            if !haskey(dict, "params")
                dict["params"] = LittleDict{String,Any}()
            end
            if dict["params"] isa Dict
                dict["params"]["_meta"] = LittleDict{String,Any}(
                    "progressToken" => msg.meta.progress_token
                )
            end
        end
        
        return JSON3.write(dict)
        
    elseif msg isa JSONRPCResponse
        return JSON3.write(LittleDict{String,Any}(
            "jsonrpc" => "2.0",
            "id" => msg.id,
            "result" => msg.result
        ))
        
    elseif msg isa JSONRPCError
        return JSON3.write(LittleDict{String,Any}(
            "jsonrpc" => "2.0",
            "id" => msg.id,
            "error" => msg.error
        ))
        
    elseif msg isa JSONRPCNotification
        dict = LittleDict{String,Any}(
            "jsonrpc" => "2.0",
            "method" => msg.method
        )
        
        if !isnothing(msg.params)
            dict["params"] = msg.params
        end
        
        return JSON3.write(dict)
    else
        throw(ArgumentError("Unknown message type: $(typeof(msg))"))
    end
end

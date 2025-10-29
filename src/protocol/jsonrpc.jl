# src/protocol/jsonrpc.jl

const REQUEST_PARAMS_MAP = Dict{String,Type}(
    "initialize" => InitializeParams,
    "resources/list" => ListResourcesParams,
    "resources/read" => ReadResourceParams,
    "tools/call" => CallToolParams,
    "tools/list" => ListToolsParams,
    "prompts/list" => ListPromptsParams,
    "prompts/get" => GetPromptParams,
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
    params_type = get_params_type(method)
    
    typed_params = if !isnothing(params_type) && haskey(raw, :params)
        if isempty(raw.params)
            params_type()  # Construct default instance instead of nothing
        else
            StructTypes.constructfrom(params_type, raw.params)
        end
    else
        nothing
    end
    
    JSONRPCRequest(
        id = raw.id,
        method = method,
        params = typed_params
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
        isempty(raw.params) ? Dict{String,Any}() : raw.params
    else
        Dict{String,Any}()
    end

    # Parse method-specific parameters
    typed_params = try
        params_type = get_params_type(method)
        if params_type === nothing || isempty(params)
            # Convert to Dict if it's a LittleDict to match the expected type
            params isa Dict ? params : Dict{String,Any}(params)
        else
            JSON3.read(JSON3.write(params), params_type)
        end
    catch e
        # Notifications can't return errors, so just use raw params
        # Convert to Dict if needed
        params isa Dict ? params : Dict{String,Any}(params)
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

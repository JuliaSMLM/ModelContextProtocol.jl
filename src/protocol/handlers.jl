# src/protocol/handlers.jl

"""
    RequestHandler

Define base type for all request handlers.
"""
abstract type RequestHandler end

"""
    RequestContext(; server::Server, request_id::Union{RequestId,Nothing}=nothing, 
                 progress_token::Union{ProgressToken,Nothing}=nothing)

Store the current request context for MCP protocol handlers.

# Fields
- `server::Server`: The MCP server instance handling the request
- `request_id::Union{RequestId,Nothing}`: The ID of the current request (if any)
- `progress_token::Union{ProgressToken,Nothing}`: Optional token for progress reporting
"""
Base.@kwdef mutable struct RequestContext
    server::Server
    request_id::Union{RequestId,Nothing} = nothing
    progress_token::Union{ProgressToken,Nothing} = nothing
end

"""
    HandlerResult(; response::Union{Response,Nothing}=nothing, 
                error::Union{ErrorInfo,Nothing}=nothing)

Represent the result of handling a request.

# Fields
- `response::Union{Response,Nothing}`: The response to send (if successful)
- `error::Union{ErrorInfo,Nothing}`: Error information (if request failed)

A HandlerResult must contain either a response or an error, but not both.
"""
Base.@kwdef struct HandlerResult
    response::Union{Response,Nothing} = nothing
    error::Union{ErrorInfo,Nothing} = nothing
end

"""
    serialize_resource_contents(resource::ResourceContents) -> Dict{String,Any}

Serialize resource contents to protocol format.

# Arguments
- `resource::ResourceContents`: The resource contents to serialize

# Returns
- `Dict{String,Any}`: The serialized resource contents
"""
function serialize_resource_contents(resource::ResourceContents)
    if resource isa TextResourceContents
        LittleDict{String,Any}(
            "uri" => resource.uri,
            "text" => resource.text,
            "mimeType" => resource.mime_type
        )
    elseif resource isa BlobResourceContents
        LittleDict{String,Any}(
            "uri" => resource.uri,
            "blob" => base64encode(resource.blob),
            "mimeType" => resource.mime_type
        )
    else
        throw(ArgumentError("Unknown resource contents type: $(typeof(resource))"))
    end
end

"""
    convert_to_content_type(result::Any, return_type::Type) -> Content

Convert various return types to the appropriate MCP Content type.

# Arguments
- `result::Any`: The result value to convert
- `return_type::Type`: The target Content type to convert to

# Returns
- `Content`: The converted Content object or the original result if no conversion is applicable
"""
function convert_to_content_type(result::Any, return_type::Type)
    # Dict to TextContent conversion
    if result isa Dict && return_type == TextContent
        return TextContent(
            type = "text",
            text = JSON3.write(result)
        )
    end
    
    # String to TextContent conversion
    if result isa String && return_type == TextContent
        return TextContent(
            type = "text",
            text = result
        )
    end
    
    # For ImageContent, if we have the raw data as Vector{UInt8} and a mime_type string
    if result isa Tuple{Vector{UInt8}, String} && return_type == ImageContent
        data, mime_type = result
        return ImageContent(
            type = "image",
            data = data,
            mime_type = mime_type
        )
    end
    
    # If no conversion is needed or applicable, return as is
    return result
end

"""
    handle_initialize(ctx::RequestContext, params::InitializeParams) -> HandlerResult

Handle MCP protocol initialization requests by setting up the server and returning capabilities.

# Arguments
- `ctx::RequestContext`: The current request context
- `params::InitializeParams`: The initialization parameters from the client

# Returns
- `HandlerResult`: Contains the server's capabilities and configuration
"""
function handle_initialize(ctx::RequestContext, params::InitializeParams)::HandlerResult
    # Currently we only support MCP protocol version 2025-06-18
    # In the future, this could be extended to support multiple versions
    SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18"]
    supported_version = SUPPORTED_PROTOCOL_VERSIONS[1]  # Use the only supported version for now
    
    # Check if client requested a specific version
    if !isnothing(params.protocolVersion) && params.protocolVersion != supported_version
        # Return error for unsupported versions
        error_info = ErrorInfo(
            code = ErrorCodes.INVALID_PARAMS,
            message = "Unsupported protocol version",
            data = LittleDict{String,Any}(
                "supported" => [supported_version],
                "requested" => params.protocolVersion
            )
        )
        return HandlerResult(
            response=JSONRPCError(
                id=ctx.request_id,
                error=error_info
            )
        )
    end

    # Get full capabilities including available tools and resources
    current_capabilities = capabilities_to_protocol(
        ctx.server.config.capabilities,
        ctx.server
    )

    # Create initialization result with our supported version
    result = InitializeResult(
        serverInfo=Dict(
            "name" => ctx.server.config.name,
            "version" => ctx.server.config.version
        ),
        capabilities=current_capabilities,
        protocolVersion=supported_version,
        instructions=ctx.server.config.instructions
    )

    HandlerResult(
        response=JSONRPCResponse(
            id=ctx.request_id,
            result=result
        )
    )
end

"""
    handle_ping(ctx::RequestContext, params::Nothing) -> HandlerResult

Handle MCP protocol ping requests.

# Arguments
- `ctx::RequestContext`: The current request context
- `params::Nothing`: The ping parameters does not contain any data

# Returns
- `HandlerResult`: Ping returns an empty response payload
"""
function handle_ping(ctx::RequestContext, ::Nothing)::HandlerResult
    HandlerResult(
        response=JSONRPCResponse(
            id=ctx.request_id,
            result=LittleDict{String,Any}()
        )
    )
end

"""
    handle_list_prompts(ctx::RequestContext, params::ListPromptsParams) -> HandlerResult

Handle requests to list available prompts on the MCP server.

# Arguments
- `ctx::RequestContext`: The current request context
- `params::ListPromptsParams`: Parameters for the list request (including optional cursor)

# Returns
- `HandlerResult`: Contains information about all available prompts
"""
function handle_list_prompts(ctx::RequestContext, params::ListPromptsParams)::HandlerResult
    try
        prompts = map(ctx.server.prompts) do prompt::MCPPrompt
            LittleDict{String,Any}(
                "name" => prompt.name,
                "description" => prompt.description,
                "arguments" => [LittleDict{String,Any}(
                    "name" => arg.name,
                    "description" => arg.description,
                    "required" => arg.required
                ) for arg in prompt.arguments]
            )
        end

        result = LittleDict{String,Any}(
            "prompts" => prompts
        )

        # Only add nextCursor if provided
        if !isnothing(params.cursor) && params.cursor != ""
            result["nextCursor"] = params.cursor
        end

        HandlerResult(
            response=JSONRPCResponse(
                id=ctx.request_id,
                result=result
            )
        )
    catch e
        HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INTERNAL_ERROR,
                message="Failed to list prompts: $e"
            )
        )
    end
end

function process_template(text::String, arguments::Dict{String,String})
    # Handle the text character by character to ensure proper brace matching
    result = text
    
    # First, handle conditional blocks
    while true
        # Find the start of a conditional block
        start_idx = findfirst("{?", result)
        isnothing(start_idx) && break
        
        # Find the variable name
        var_end_idx = findfirst("?", result[start_idx[end]+1:end])
        isnothing(var_end_idx) && break
        var_end_idx = var_end_idx[1] + start_idx[end]
        var_name = result[start_idx[end]+1:var_end_idx-1]
        
        # Find the matching closing brace
        content_start = var_end_idx + 1
        brace_count = 1
        content_end = nothing
        
        for i in content_start:length(result)
            if result[i] == '{'
                brace_count += 1
            elseif result[i] == '}'
                brace_count -= 1
                if brace_count == 0
                    content_end = i
                    break
                end
            end
        end
        
        isnothing(content_end) && break
        
        # Extract the content
        content = result[content_start:content_end-1]
        
        # Process the conditional block
        if haskey(arguments, var_name)
            # Replace variables in the content
            processed_content = content
            for (key, value) in arguments
                processed_content = replace(processed_content, "{$key}" => value)
            end
            # Replace the entire conditional block with the processed content
            result = result[1:start_idx[1]-1] * processed_content * result[content_end+1:end]
        else
            # Remove the entire conditional block
            result = result[1:start_idx[1]-1] * result[content_end+1:end]
        end
    end
    
    # Finally, handle any remaining regular variables
    for (key, value) in arguments
        result = replace(result, "{$key}" => value)
    end
    
    return result
end


function handle_get_prompt(ctx::RequestContext, params::GetPromptParams)::HandlerResult
    try
        # Find the prompt
        prompt_idx = findfirst(p -> p.name == params.name, ctx.server.prompts)

        if isnothing(prompt_idx)
            return HandlerResult(
                error=ErrorInfo(
                    code=ErrorCodes.PROMPT_NOT_FOUND,
                    message="Prompt not found: $(params.name)"
                )
            )
        end

        prompt = ctx.server.prompts[prompt_idx]

        # Validate required arguments
        if !isnothing(params.arguments)
            missing_args = filter(arg -> arg.required && !haskey(params.arguments, arg.name),
                prompt.arguments)

            if !isempty(missing_args)
                return HandlerResult(
                    error=ErrorInfo(
                        code=ErrorCodes.INVALID_PARAMS,
                        message="Missing required arguments: $(join(map(a -> a.name, missing_args), ", "))"
                    )
                )
            end
        end

        # Get the arguments (empty dict if none provided)
        args = params.arguments isa Nothing ? LittleDict{String,String}() : params.arguments

        # Process messages with template processor
        processed_messages = map(prompt.messages) do msg
            if msg.content isa TextContent
                # Create new message with processed text
                PromptMessage(
                    role = msg.role,
                    content = TextContent(
                        type = "text",
                        text = process_template(msg.content.text, args)
                    )
                )
            else
                # Pass through non-text messages unchanged
                msg
            end
        end

        # Create proper GetPromptResult
        result = GetPromptResult(
            description = prompt.description,
            messages = processed_messages
        )

        HandlerResult(
            response = JSONRPCResponse(
                id = ctx.request_id,
                result = result
            )
        )
    catch e
        HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INTERNAL_ERROR,
                message="Failed to get prompt: $e"
            )
        )
    end
end


"""
    handle_list_resources(ctx::RequestContext, params::ListResourcesParams) -> HandlerResult

Handle requests to list all available resources on the MCP server.

# Arguments
- `ctx::RequestContext`: The current request context
- `params::ListResourcesParams`: Parameters for the list request (including optional cursor)

# Returns
- `HandlerResult`: Contains information about all registered resources
"""
function handle_list_resources(ctx::RequestContext, params::ListResourcesParams)::HandlerResult
    try
        resources = map(ctx.server.resources) do resource::MCPResource
            LittleDict{String,Any}(
                "uri" => string(resource.uri),
                "name" => resource.name,
                "mimeType" => resource.mime_type,
                "description" => resource.description,
                "annotations" => LittleDict{String,Any}(
                    "audience" => get(resource.annotations, "audience", ["assistant"]),
                    "priority" => get(resource.annotations, "priority", 0.0)
                )
            )
        end

        # Create the result dictionary explicitly
        result_dict = LittleDict{String,Any}(
            "resources" => resources
        )

        # Only add nextCursor if it's provided and not null
        if !isnothing(params.cursor) && params.cursor != ""
            result_dict["nextCursor"] = params.cursor
        end

        HandlerResult(
            response=JSONRPCResponse(
                id=ctx.request_id,
                result=result_dict
            )
        )
    catch e
        HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INTERNAL_ERROR,
                message="Failed to list resources: $e"
            )
        )
    end
end

"""
    handle_read_resource(ctx::RequestContext, params::ReadResourceParams) -> HandlerResult

Handle requests to read content from a specific resource by URI.

# Arguments
- `ctx::RequestContext`: The current request context
- `params::ReadResourceParams`: Parameters containing the URI of the resource to read

# Returns
- `HandlerResult`: Contains either the resource contents or an error if the resource 
  is not found or cannot be read
"""
function handle_read_resource(ctx::RequestContext, params::ReadResourceParams)::HandlerResult
    # Convert the requested URI string to a URI object for comparison
    request_uri = try
        URI(params.uri)
    catch e
        return HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INVALID_URI,
                message="Invalid URI format: $(params.uri)"
            )
        )
    end

    # Find the resource with matching URI
    resource = nothing
    for r in ctx.server.resources
        if string(r.uri) == string(request_uri)
            resource = r
            break
        end
    end

    if isnothing(resource)
        return HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.RESOURCE_NOT_FOUND,
                message="Resource not found: $(params.uri)"
            )
        )
    end

    try
        data = resource.data_provider()
        
        contents = [LittleDict{String,Any}(
            "uri" => string(resource.uri),
            "text" => JSON3.write(data),
            "mimeType" => resource.mime_type
        )]

        # Use the proper ReadResourceResult struct
        HandlerResult(
            response = JSONRPCResponse(
                id = ctx.request_id,
                result = ReadResourceResult(contents = contents)  # Wrap in proper struct
            )
        )

    catch e
        return HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INTERNAL_ERROR,
                message="Error reading resource: $(e)"
            )
        )
    end
end

"""
    handle_call_tool(ctx::RequestContext, params::CallToolParams) -> HandlerResult

Handle requests to call a specific tool with the provided parameters.

# Arguments
- `ctx::RequestContext`: The current request context
- `params::CallToolParams`: Parameters containing the tool name and arguments

# Returns
- `HandlerResult`: Contains either the tool execution results or an error if the tool
  is not found or execution fails
"""
function handle_call_tool(ctx::RequestContext, params::CallToolParams)::HandlerResult
    # Find the tool by name
    tool_idx = findfirst(t -> t.name == params.name, ctx.server.tools)

    if isnothing(tool_idx)
        return HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.TOOL_NOT_FOUND,
                message="Tool not found: $(params.name)"
            )
        )
    end

    tool = ctx.server.tools[tool_idx]

    try
        # Apply default values to arguments if not provided
        args = isnothing(params.arguments) ? LittleDict{String,Any}() : copy(params.arguments)
        
        # Apply defaults for parameters that have them
        for param in tool.parameters
            if !isnothing(param.default) && !haskey(args, param.name)
                args[param.name] = param.default
            end
        end
        
        # Call the tool handler with the arguments
        result = tool.handler(args)
        
        # Check if the handler returned a complete CallToolResult
        if result isa CallToolResult
            # Handler returned a complete result, use it directly
            return HandlerResult(
                response=JSONRPCResponse(
                    id=ctx.request_id,
                    result=result
                )
            )
        end
        
        # Apply automatic conversion to the expected return type
        result = convert_to_content_type(result, tool.return_type)

        # Check if result is a vector of content or single content
        is_vector = result isa Vector && all(x -> x isa Content, result)
        
        # Validate return type matches what's declared
        if is_vector
            # Check if return type accepts vectors of content
            # We need to check if the actual type or Vector{Content} is accepted
            if !(typeof(result) <: tool.return_type) && !(Vector{Content} <: tool.return_type)
                throw(ArgumentError("Tool returned $(typeof(result)), but return_type is $(tool.return_type)"))
            end
        elseif result isa Content
            # Single content - check if it matches declared type or if Vector was expected
            if tool.return_type <: Vector
                # If Vector was expected but single content returned, wrap it
                result = [result]
                is_vector = true
            elseif !(result isa tool.return_type)
                throw(ArgumentError("Tool returned $(typeof(result)), expected $(tool.return_type)"))
            end
        else
            throw(ArgumentError("Tool must return Content or Vector{<:Content}, got $(typeof(result))"))
        end

        # Convert content to protocol format
        content = if is_vector
            # Handle vector of content items
            map(content2dict, result)
        else
            # Handle single content item (backward compatibility)
            [content2dict(result)]
        end

        HandlerResult(
            response=JSONRPCResponse(
                id=ctx.request_id,
                result=CallToolResult(
                    content=content,
                    is_error=false
                )
            )
        )
    catch e
        HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INTERNAL_ERROR,
                message="Tool execution failed: $(e)"
            )
        )
    end
end

"""
    handle_list_tools(ctx::RequestContext, params::ListToolsParams) -> HandlerResult

Handle requests to list all available tools on the MCP server.

# Arguments
- `ctx::RequestContext`: The current request context
- `params::ListToolsParams`: Parameters for the list request (including optional cursor)

# Returns
- `HandlerResult`: Contains information about all registered tools
"""
function handle_list_tools(ctx::RequestContext, params::ListToolsParams)::HandlerResult
    try
        tools = map(ctx.server.tools) do tool
            LittleDict{String,Any}(
                "name" => tool.name,
                "description" => tool.description,
                "inputSchema" => LittleDict{String,Any}(
                    "type" => "object",
                    "properties" => Dict(
                        param.name => begin
                            schema = LittleDict{String,Any}(
                                "type" => param.type,
                                "description" => param.description
                            )
                            # Add default value to schema if it exists
                            if !isnothing(param.default)
                                schema["default"] = param.default
                            end
                            schema
                        end for param in tool.parameters
                    ),
                    "required" => [p.name for p in tool.parameters if p.required]
                )
            )
        end

        result = LittleDict{String,Any}(
            "tools" => tools
        )

        HandlerResult(
            response=JSONRPCResponse(
                id=ctx.request_id,
                result=result
            )
        )
    catch e
        HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INTERNAL_ERROR,
                message="Failed to list tools: $e"
            )
        )
    end
end

"""
    handle_notification(ctx::RequestContext, notification::JSONRPCNotification) -> Nothing

Process notification messages from clients that don't require responses.

# Arguments
- `ctx::RequestContext`: The current request context
- `notification::JSONRPCNotification`: The notification to process

# Returns
- `Nothing`: Notifications don't generate responses
"""
function handle_notification(ctx::RequestContext, notification::JSONRPCNotification)::Nothing
    method = notification.method

    if method == "notifications/initialized"
        ctx.server.active = true
    elseif method == "notifications/cancelled"
        # Handle cancellation
    elseif method == "notifications/progress"
        # Handle progress updates
    end

    return nothing
end

"""
    handle_request(server::Server, request::Request) -> Response

Process an MCP protocol request and route it to the appropriate handler based on the request method.

# Arguments
- `server::Server`: The MCP server instance handling the request
- `request::Request`: The parsed JSON-RPC request to process

# Behavior
This function creates a request context, then dispatches the request to the appropriate
handler based on the request method. Supported methods include:
- `initialize`: Server initialization
- `resources/list`: List available resources
- `resources/read`: Read a specific resource
- `tools/list`: List available tools
- `tools/call`: Invoke a specific tool
- `prompts/list`: List available prompts
- `prompts/get`: Get a specific prompt

If an unknown method is received, a METHOD_NOT_FOUND error is returned.
Any exceptions thrown during processing are caught and converted to INTERNAL_ERROR responses.

# Returns
- `Response`: Either a successful response or an error response depending on the handler result
"""
function handle_request(server::Server, request::Request)::Response
    ctx = RequestContext(
        server=server,
        request_id=request.id,
        progress_token=request.meta.progress_token
    )

    try
        # Handle request with already typed parameters
        result =
            if request.method == "initialize"
                handle_initialize(ctx, request.params::InitializeParams)
            elseif request.method == "ping"
                handle_ping(ctx, request.params::Nothing)
            elseif request.method == "resources/list"
                # Handle null params from clients like Cursor
                params = isnothing(request.params) ? ListResourcesParams() : request.params::ListResourcesParams
                handle_list_resources(ctx, params)
            elseif request.method == "resources/read"
                handle_read_resource(ctx, request.params::ReadResourceParams)
            elseif request.method == "tools/call"
                handle_call_tool(ctx, request.params::CallToolParams)
            elseif request.method == "tools/list"
                # Handle null params from clients like Cursor
                params = isnothing(request.params) ? ListToolsParams() : request.params::ListToolsParams
                handle_list_tools(ctx, params)
            elseif request.method == "prompts/list"
                # Handle null params from clients like Cursor
                params = isnothing(request.params) ? ListPromptsParams() : request.params::ListPromptsParams
                handle_list_prompts(ctx, params)
            elseif request.method == "prompts/get"
                handle_get_prompt(ctx, request.params::GetPromptParams)
            else
                HandlerResult(
                    error=ErrorInfo(
                        code=ErrorCodes.METHOD_NOT_FOUND,
                        message="Unknown method: $(request.method)"
                    )
                )
            end

        # Return response or error
        if !isnothing(result.error)
            JSONRPCError(id=ctx.request_id, error=result.error)
        else
            result.response
        end
    catch e
        logger = MCPLogger(stderr)
        Logging.handle_message(logger, Error, Dict("exception" => e), @__MODULE__, nothing, nothing, @__FILE__, @__LINE__)
        return JSONRPCError(
            id=ctx.request_id,
            error=ErrorInfo(
                code=ErrorCodes.INTERNAL_ERROR,
                message="Internal error: $(e)"
            )
        )
    end
end
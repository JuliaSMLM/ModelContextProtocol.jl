# src/protocol/handlers.jl

"""
Base type for all request handlers
"""
abstract type RequestHandler end

"""
Stores the current request context
"""
Base.@kwdef mutable struct RequestContext
    server::Server
    request_id::Union{RequestId,Nothing} = nothing
    progress_token::Union{ProgressToken,Nothing} = nothing
end

"""
Result of handling a request
"""
Base.@kwdef struct HandlerResult
    response::Union{Response,Nothing} = nothing
    error::Union{ErrorInfo,Nothing} = nothing
end

"""
Handle initialization requests with standardized capability broadcasting
"""
function handle_initialize(ctx::RequestContext, params::InitializeParams)::HandlerResult
    # Get full capabilities including available tools and resources
    current_capabilities = capabilities_to_protocol(
        ctx.server.config.capabilities,
        ctx.server
    )

    # Create initialization result
    result = InitializeResult(
        serverInfo=Dict(
            "name" => ctx.server.config.name,
            "version" => ctx.server.config.version
        ),
        capabilities=current_capabilities,
        protocolVersion=params.protocolVersion,
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
Handles prompt listing requests
"""
function handle_list_prompts(ctx::RequestContext, params::ListPromptsParams)::HandlerResult
    try
        prompts = map(ctx.server.prompts) do prompt::MCPPrompt
            Dict{String,Any}(
                "name" => prompt.name,
                "description" => prompt.description,
                "arguments" => [Dict{String,Any}(
                    "name" => arg.name,
                    "description" => arg.description,
                    "required" => arg.required
                ) for arg in prompt.arguments]
            )
        end

        result = Dict{String,Any}(
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
        args = params.arguments isa Nothing ? Dict{String,String}() : params.arguments

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
Handles resource listing requests
"""
function handle_list_resources(ctx::RequestContext, params::ListResourcesParams)::HandlerResult
    try
        resources = map(ctx.server.resources) do resource::MCPResource
            Dict{String,Any}(
                "uri" => string(resource.uri),
                "name" => resource.name,
                "mimeType" => resource.mime_type,
                "description" => resource.description,
                "annotations" => Dict{String,Any}(
                    "audience" => get(resource.annotations, "audience", ["assistant"]),
                    "priority" => get(resource.annotations, "priority", 0.0)
                )
            )
        end

        # Create the result dictionary explicitly
        result_dict = Dict{String,Any}(
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
Handles resource reading requests
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
        
        contents = [Dict{String,Any}(
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
Handles tool calls
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
        # Call the tool handler with the arguments
        result = tool.handler(params.arguments)

        # Validate return type matches what's declared
        if !(result isa tool.return_type)
            throw(ArgumentError("Tool returned $(typeof(result)), expected $(tool.return_type)"))
        end

        # Convert content to protocol format
        content = if result isa ImageContent
            [Dict{String,Any}(
                "type" => "image",
                "data" => base64encode(result.data),
                "mimeType" => result.mime_type,
                "annotations" => result.annotations
            )]
        elseif result isa TextContent
            [Dict{String,Any}(
                "type" => "text",
                "text" => result.text,
                "annotations" => result.annotations
            )]
        else
            throw(ArgumentError("Unsupported content type: $(typeof(result))"))
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
Handles tool listing requests
"""
function handle_list_tools(ctx::RequestContext, params::ListToolsParams)::HandlerResult
    try
        tools = map(ctx.server.tools) do tool
            Dict{String,Any}(
                "name" => tool.name,
                "description" => tool.description,
                "inputSchema" => Dict{String,Any}(
                    "type" => "object",
                    "properties" => Dict(
                        param.name => Dict{String,Any}(
                            "type" => param.type,
                            "description" => param.description
                        ) for param in tool.parameters
                    ),
                    "required" => [p.name for p in tool.parameters if p.required]
                )
            )
        end

        result = Dict{String,Any}(
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
Handle notifications
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
            elseif request.method == "resources/list"
                handle_list_resources(ctx, request.params::ListResourcesParams)
            elseif request.method == "resources/read"
                handle_read_resource(ctx, request.params::ReadResourceParams)
            elseif request.method == "tools/call"
                handle_call_tool(ctx, request.params::CallToolParams)
            elseif request.method == "tools/list"
                handle_list_tools(ctx, request.params::ListToolsParams)
            elseif request.method == "prompts/list"
                handle_list_prompts(ctx, request.params::ListPromptsParams)
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
        logger.handle_message(logger, Error, Dict("exception" => e), @__MODULE__, nothing, nothing, @__FILE__, @__LINE__)
        JSONRPCError(
            id=ctx.request_id,
            error=ErrorInfo(
                code=ErrorCodes.INTERNAL_ERROR,
                message="Internal error: $(e)"
            )
        )
    end
end
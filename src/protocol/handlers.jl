# src/protocol/handlers.jl

"""
    RequestHandler

Define base type for all request handlers.
"""
abstract type RequestHandler end

"""
    RequestContext(; server::Server, state::ServerState=ServerState(),
                   request_id::Union{RequestId,Nothing}=nothing,
                   progress_token::Union{ProgressToken,Nothing}=nothing)

Store the current request context for MCP protocol handlers.

# Fields
- `server::Server`: The MCP server instance handling the request
- `state::ServerState`: The persistent server state, carrying the negotiated protocol version for feature gating (see `supports`)
- `request_id::Union{RequestId,Nothing}`: The ID of the current request (if any)
- `progress_token::Union{ProgressToken,Nothing}`: Optional token for progress reporting
"""
Base.@kwdef mutable struct RequestContext
    server::Server
    state::ServerState = ServerState()
    request_id::Union{RequestId,Nothing} = nothing
    progress_token::Union{ProgressToken,Nothing} = nothing
    authenticated_user::Union{AuthenticatedUser,Nothing} = nothing  # per-request identity from HTTP auth, else nothing; treat as read-only (may be shared from a validator cache)
    task::Union{TaskRecord,Nothing} = nothing  # set for task-augmented executions (MCP Tasks); enables task_cancelled(ctx)
end

"""
    send_progress(ctx::RequestContext, progress::Real;
                  total::Union{Real,Nothing}=nothing,
                  message::Union{String,Nothing}=nothing) -> Bool

Emit an MCP `notifications/progress` for the current request. A tool handler that
accepts the `RequestContext` (its second argument) can call this during a long
operation to report progress.

Returns `false` (a no-op) when the client did not supply a `progressToken` or no
transport is connected, so it is always safe to call. Send an increasing
`progress`; include `total` for a determinate bar and `message` for a status line.
"""
function send_progress(ctx::RequestContext, progress::Real;
                       total::Union{Real,Nothing}=nothing,
                       message::Union{String,Nothing}=nothing)::Bool
    (ctx.progress_token === nothing || ctx.server.transport === nothing) && return false
    params = Dict{String,Any}(
        "progressToken" => ctx.progress_token,
        "progress" => Float64(progress),
    )
    total !== nothing && (params["total"] = Float64(total))
    message !== nothing && (params["message"] = message)
    try
        send_notification(
            ctx.server.transport,
            serialize_message(JSONRPCNotification(method="notifications/progress", params=params)),
        )
        return true
    catch
        return false
    end
end

"""
    task_cancelled(ctx) -> Bool

Check whether the current task-augmented execution has been cancelled by the client
(via `tasks/cancel`). Long-running, context-aware tool handlers can poll this to stop
work early; the discarded result is never delivered (cancelled tasks stay cancelled).
Always `false` for ordinary (non-task) calls, so it is safe to call unconditionally.

```julia
handler = (args, ctx) -> begin
    for chunk in work_chunks
        task_cancelled(ctx) && return TextContent(text = "aborted")
        process(chunk)
    end
    TextContent(text = "done")
end
```
"""
task_cancelled(ctx::RequestContext)::Bool =
    ctx.task !== nothing && ctx.task.cancel_requested[]

"""
    HandlerResult(; response::Union{Response,Nothing}=nothing, 
                error::Union{ErrorInfo,Nothing}=nothing)

Represent the result of handling a request.

# Fields
- `response::Union{Response,Nothing}`: The response to send (if successful)
- `error::Union{ErrorInfo,Nothing}`: Error information (if request failed)
- `deferred::Bool`: When true, neither field is set and the response will be delivered
  out-of-loop via `deliver_response` (used by the blocking `tasks/result`)

A HandlerResult must contain either a response, an error, or be deferred.
"""
Base.@kwdef struct HandlerResult
    response::Union{Response,Nothing} = nothing
    error::Union{ErrorInfo,Nothing} = nothing
    deferred::Bool = false  # response will be delivered later via deliver_response (e.g. blocking tasks/result)
end

"""
    serialize_resource_contents(resource::ResourceContents) -> LittleDict{String,Any}

Serialize resource contents to the spec wire shape: `{uri, text, mimeType}` for
`TextResourceContents`, `{uri, blob, mimeType}` (base64) for `BlobResourceContents`.

# Arguments
- `resource::ResourceContents`: The resource contents to serialize

# Returns
- `LittleDict{String,Any}`: The serialized resource contents entry
"""
function serialize_resource_contents(resource::ResourceContents)
    if resource isa TextResourceContents
        LittleDict{String,Any}(
            "uri" => string(resource.uri),
            "text" => resource.text,
            "mimeType" => resource.mime_type
        )
    elseif resource isa BlobResourceContents
        LittleDict{String,Any}(
            "uri" => string(resource.uri),
            "blob" => base64encode(resource.blob),
            "mimeType" => resource.mime_type
        )
    else
        throw(ArgumentError("Unknown resource contents type: $(typeof(resource))"))
    end
end

"""
    normalize_read_contents(data, fallback_uri::String, fallback_mime::String)
        -> Vector{LittleDict{String,Any}}

Normalize a resource provider's return value into spec `resources/read` contents
entries: `TextResourceContents`/`BlobResourceContents` (or a vector of them) serialize
directly — the only path that can produce binary `blob` contents; a `String` becomes
the text verbatim; anything else (including custom `ResourceContents` subtypes) is
JSON-encoded into a text entry carrying `fallback_uri`/`fallback_mime`.
"""
function normalize_read_contents(data, fallback_uri::String, fallback_mime::String)
    wire_contents = Union{TextResourceContents,BlobResourceContents}
    if data isa wire_contents
        [serialize_resource_contents(data)]
    elseif data isa Vector && !isempty(data) && all(x -> x isa wire_contents, data)
        [serialize_resource_contents(x) for x in data]
    else
        [LittleDict{String,Any}(
            "uri" => fallback_uri,
            "text" => data isa AbstractString ? String(data) : JSON3.write(data),
            "mimeType" => fallback_mime
        )]
    end
end

_regex_escape(s::AbstractString) =
    replace(s, r"([\\^\$\.\|\?\*\+\(\)\[\]\{\}])" => s"\\\1")

"""
    match_uri_template(template::String, uri::String) -> Union{Nothing,Dict{String,String}}

Match `uri` against an RFC 6570 level-1 URI template. Each `{var}` placeholder matches
one path segment (one or more characters excluding `/`). Returns the extracted
variables on a full match, `nothing` otherwise.
"""
function match_uri_template(template::String, uri::String)::Union{Nothing,Dict{String,String}}
    names = String[]
    pattern = IOBuffer()
    print(pattern, "^")
    pos = 1
    for m in eachmatch(r"\{([A-Za-z0-9_]+)\}", template)
        print(pattern, _regex_escape(template[pos:prevind(template, m.offset)]))
        push!(names, String(m.captures[1]))
        print(pattern, "([^/]+)")
        pos = m.offset + ncodeunits(m.match)
    end
    print(pattern, _regex_escape(template[pos:end]), "\$")
    mm = match(Regex(String(take!(pattern))), uri)
    mm === nothing && return nothing
    Dict{String,String}(n => String(c) for (n, c) in zip(names, mm.captures))
end

"""
    convert_to_content_type(result::Any) -> Any

Apply the documented convenience conversions for tool handler return values:
a `Dict` becomes JSON wrapped in `TextContent`, a `String` becomes `TextContent`,
and a `Tuple{Vector{UInt8},String}` becomes `ImageContent`.

These conversions are independent of the tool's declared `return_type` (the
caller validates the converted result against `return_type` afterwards), so the
documented behavior holds for the default `return_type = Vector{Content}` too.

# Arguments
- `result::Any`: The raw value returned by a tool handler

# Returns
- `Any`: A `Content` object for the convenience cases above; otherwise `result` unchanged
"""
function convert_to_content_type(result::Any)
    # Dict -> JSON string wrapped in TextContent
    if result isa AbstractDict
        return TextContent(type = "text", text = JSON3.write(result))
    end

    # String -> TextContent
    if result isa AbstractString
        return TextContent(type = "text", text = String(result))
    end

    # (raw bytes, mime type) -> ImageContent
    if result isa Tuple{Vector{UInt8}, String}
        data, mime_type = result
        return ImageContent(type = "image", data = data, mime_type = mime_type)
    end

    # Not a convenience type; leave as-is for the caller to validate against return_type
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
    # Negotiate the protocol version per the MCP spec: if the client requests a
    # version we support, echo it back; otherwise respond with our latest version
    # and let the client decide whether it can proceed. See `negotiate_version`.
    client_version = params.protocolVersion
    negotiated_version = negotiate_version(client_version)

    # Persist the negotiated version so later handlers can feature-gate via supports(...)
    ctx.state.protocol_version = negotiated_version

    if !isnothing(client_version) && client_version != negotiated_version
        @debug "Version negotiation" client_requested=client_version negotiated=negotiated_version
    end

    # Get full capabilities including available tools and resources
    current_capabilities = capabilities_to_protocol(
        ctx.server.config.capabilities,
        ctx.server
    )

    # Tasks (experimental) are a 2025-11-25 feature: withhold the capability from
    # clients that negotiated an earlier version (their task metadata is then
    # ignored and tools/call always runs synchronously, per spec)
    supports(negotiated_version, :tasks) || delete!(current_capabilities, "tasks")

    # Create initialization result with the negotiated version
    server_info = Dict{String,Any}(
        "name" => ctx.server.config.name,
        "version" => ctx.server.config.version
    )
    !isempty(ctx.server.config.description) && (server_info["description"] = ctx.server.config.description)
    !isnothing(ctx.server.config.title) && (server_info["title"] = ctx.server.config.title)
    !isnothing(ctx.server.config.icons) && (server_info["icons"] = [icon_to_dict(i) for i in ctx.server.config.icons])

    result = InitializeResult(
        serverInfo=server_info,
        capabilities=current_capabilities,
        protocolVersion=negotiated_version,
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
    handle_set_level(ctx::RequestContext, params::SetLevelParams) -> HandlerResult

Handle `logging/setLevel` requests by adjusting the installed `MCPLogger`'s minimum level.

Accepts the MCP/RFC-5424 levels (`MCP_LOG_LEVELS`) and maps them to Julia `LogLevel`s.
Setting `"debug"` also enables the per-request lifecycle log lines emitted by
`handle_request`. When the global logger is not an `MCPLogger` the request still
succeeds (the preference simply has nothing to apply to).

# Arguments
- `ctx::RequestContext`: The current request context
- `params::SetLevelParams`: The requested minimum level

# Returns
- `HandlerResult`: Empty result on success; `INVALID_PARAMS` error for unknown levels
"""
function handle_set_level(ctx::RequestContext, params::SetLevelParams)::HandlerResult
    if !(params.level in MCP_LOG_LEVELS)
        return HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INVALID_PARAMS,
                message="Invalid log level: $(params.level). Valid levels: $(join(MCP_LOG_LEVELS, ", "))"
            )
        )
    end

    logger = Logging.global_logger()
    if logger isa MCPLogger
        logger.min_level = mcp_level_to_julia(params.level)
        # Re-install: global_logger caches min_enabled_level in the LogState at install
        # time, so a field mutation alone never reaches the @debug/@info early-out check
        Logging.global_logger(logger)
    else
        @debug "logging/setLevel: global logger is not an MCPLogger; level not applied" requested=params.level
    end

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
            d = LittleDict{String,Any}(
                "name" => prompt.name,
                "description" => prompt.description,
                "arguments" => begin
                    map(prompt.arguments) do arg
                        ad = LittleDict{String,Any}(
                            "name" => arg.name,
                            "description" => arg.description,
                            "required" => arg.required
                        )
                        !isnothing(arg.title) && (ad["title"] = arg.title)
                        ad
                    end
                end
            )
            !isnothing(prompt.title) && (d["title"] = prompt.title)
            !isnothing(prompt.icons) && (d["icons"] = [icon_to_dict(i) for i in prompt.icons])
            !isnothing(prompt._meta) && (d["_meta"] = prompt._meta)
            d
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

function process_template(text::String, arguments::AbstractDict{String,String})
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

        # Serialize messages through content2dict so media content uses the spec
        # wire format (base64 `data`, `mimeType`) rather than raw struct fields
        result = LittleDict{String,Any}(
            "description" => prompt.description,
            "messages" => [
                LittleDict{String,Any}(
                    "role" => string(msg.role),
                    "content" => content2dict(msg.content)
                ) for msg in processed_messages
            ]
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
            d = LittleDict{String,Any}(
                "uri" => string(resource.uri),
                "name" => resource.name,
                "mimeType" => resource.mime_type,
                "description" => resource.description,
                "annotations" => LittleDict{String,Any}(
                    "audience" => get(resource.annotations, "audience", ["assistant"]),
                    "priority" => get(resource.annotations, "priority", 0.0)
                )
            )
            !isnothing(resource.title) && (d["title"] = resource.title)
            !isnothing(resource.icons) && (d["icons"] = [icon_to_dict(i) for i in resource.icons])
            !isnothing(resource._meta) && (d["_meta"] = resource._meta)
            d
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
        # No exact match: route through resource templates (RFC 6570 level-1
        # {var} segments). First matching template with a provider serves the read.
        for tmpl in ctx.server.resource_templates
            tmpl.data_provider === nothing && continue
            vars = match_uri_template(tmpl.uri_template, params.uri)
            vars === nothing && continue
            return try
                provider = tmpl.data_provider
                # Providers may opt into a two-arg form to receive the extracted
                # template variables (dispatch by applicability, like tool handlers)
                data = applicable(provider, params.uri, vars) ?
                       provider(params.uri, vars) : provider(params.uri)
                contents = normalize_read_contents(
                    data, params.uri, something(tmpl.mime_type, "application/json"))
                HandlerResult(
                    response = JSONRPCResponse(
                        id = ctx.request_id,
                        result = ReadResourceResult(contents = contents)
                    )
                )
            catch e
                HandlerResult(
                    error=ErrorInfo(
                        code=ErrorCodes.INTERNAL_ERROR,
                        message="Error reading resource: $(e)"
                    )
                )
            end
        end
        return HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.RESOURCE_NOT_FOUND,
                message="Resource not found: $(params.uri)"
            )
        )
    end

    try
        data = resource.data_provider()
        contents = normalize_read_contents(data, string(resource.uri), resource.mime_type)

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
    handle_list_resource_templates(ctx::RequestContext, params::ListResourceTemplatesParams)
        -> HandlerResult

Handle a `resources/templates/list` request: advertise the server's resource templates
in the spec wire shape (`resourceTemplates` entries with `uriTemplate`, `name`, and
optional `description`/`mimeType`/`title`/`icons`/`_meta`).
"""
function handle_list_resource_templates(ctx::RequestContext,
                                        params::ListResourceTemplatesParams)::HandlerResult
    templates = map(ctx.server.resource_templates) do t
        d = LittleDict{String,Any}(
            "uriTemplate" => t.uri_template,
            "name" => t.name
        )
        isempty(t.description) || (d["description"] = t.description)
        t.mime_type !== nothing && (d["mimeType"] = t.mime_type)
        t.title !== nothing && (d["title"] = t.title)
        t.icons !== nothing && (d["icons"] = [icon_to_dict(i) for i in t.icons])
        t._meta !== nothing && (d["_meta"] = t._meta)
        d
    end
    HandlerResult(
        response = JSONRPCResponse(
            id = ctx.request_id,
            result = LittleDict{String,Any}("resourceTemplates" => templates)
        )
    )
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

    # Apply default values to arguments if not provided
    args = isnothing(params.arguments) ? LittleDict{String,Any}() : copy(params.arguments)

    # Apply defaults for parameters that have them
    for param in tool.parameters
        if !isnothing(param.default) && !haskey(args, param.name)
            args[param.name] = param.default
        end
    end

    # Task augmentation (MCP Tasks, experimental). The tool-level rules apply only
    # when the tasks capability was declared to THIS client (negotiated 2025-11-25);
    # when undeclared, the spec requires processing the request normally, ignoring
    # any task metadata.
    if tasks_supported(ctx)
        support = tool.task_support in (:optional, :required) ? tool.task_support : :forbidden
        task_requested = params.task !== nothing
        if task_requested && support === :forbidden
            return HandlerResult(
                error=ErrorInfo(
                    code=ErrorCodes.METHOD_NOT_FOUND,
                    message="Tool does not support task-augmented execution: $(params.name)"
                )
            )
        elseif !task_requested && support === :required
            return HandlerResult(
                error=ErrorInfo(
                    code=ErrorCodes.METHOD_NOT_FOUND,
                    message="Tool requires task-augmented execution: $(params.name)"
                )
            )
        elseif task_requested
            raw_ttl = get(params.task, "ttl", nothing)
            if raw_ttl !== nothing && !(raw_ttl isa Real && !(raw_ttl isa Bool) && raw_ttl >= 0)
                return HandlerResult(
                    error=ErrorInfo(
                        code=ErrorCodes.INVALID_PARAMS,
                        message="Invalid task ttl: must be a non-negative number of milliseconds"
                    )
                )
            end
            requested_ttl = raw_ttl === nothing ? nothing : round(Int, raw_ttl)
            record = create_task!(ctx.server.tasks, "tools/call";
                                  requested_ttl_ms=requested_ttl,
                                  principal=task_principal(ctx))
            # Snapshot the wire shape before spawning so the CreateTaskResult always
            # reports the creation-time "working" status
            wire = lock(ctx.server.tasks.lock) do
                task_wire(record)
            end
            spawn_task_execution!(ctx, tool, args, record)
            return HandlerResult(
                response=JSONRPCResponse(
                    id=ctx.request_id,
                    result=LittleDict{String,Any}("task" => wire)
                )
            )
        end
    end

    # Synchronous execution (the default path)
    outcome = execute_tool_call(tool, args, ctx)
    if outcome isa ErrorInfo
        HandlerResult(error=outcome)
    else
        HandlerResult(
            response=JSONRPCResponse(
                id=ctx.request_id,
                result=outcome
            )
        )
    end
end

"""
    execute_tool_call(tool::MCPTool, args::AbstractDict, ctx::RequestContext)
        -> Union{CallToolResult,ErrorInfo}

Run a tool handler and normalize its return value to a `CallToolResult` (applying the
documented convenience conversions and `return_type` validation), or an `ErrorInfo`
when execution throws. Shared by the synchronous `tools/call` path and background
task-augmented executions.
"""
function execute_tool_call(tool::MCPTool, args::AbstractDict,
                           ctx::RequestContext)::Union{CallToolResult,ErrorInfo}
    try
        # Call the tool handler. Handlers may opt into a context-aware form
        # `handler(args, ctx)` to access the RequestContext — `ctx.authenticated_user`,
        # progress reporting via `send_progress(ctx, ...)`, the request id, etc.; the
        # plain `handler(args)` form keeps working. Dispatch by applicability (not by
        # catching MethodError, which would mask errors thrown inside a handler).
        result = applicable(tool.handler, args, ctx) ? tool.handler(args, ctx) : tool.handler(args)

        # Check if the handler returned a complete CallToolResult
        if result isa CallToolResult
            # Handler returned a complete result, use it directly
            return result
        end

        # Apply the documented convenience conversions (Dict/String/bytes -> Content)
        result = convert_to_content_type(result)

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
                # A Vector was expected but a single Content was returned: wrap it,
                # but only if it satisfies the vector's declared element type (so a
                # convenience-converted value can't silently violate e.g. Vector{ImageContent}).
                elt = eltype(tool.return_type)
                if !(result isa elt)
                    throw(ArgumentError("Tool returned $(typeof(result)), expected element of $(tool.return_type)"))
                end
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

        CallToolResult(
            content=content,
            is_error=false
        )
    catch e
        ErrorInfo(
            code=ErrorCodes.INTERNAL_ERROR,
            message="Tool execution failed: $(e)"
        )
    end
end

#= MCP Tasks (SEP-1686, experimental) — task-augmented tools/call + tasks/* methods =#

"""
    tasks_supported(ctx::RequestContext) -> Bool

Whether the tasks capability is in effect for THIS session: the server is configured
with a `TaskCapability` AND the client negotiated a protocol version with task support
(2025-11-25+). When false, task metadata on requests is ignored (per spec) and the
`tasks/*` methods do not exist.
"""
function tasks_supported(ctx::RequestContext)::Bool
    ctx.state.protocol_version !== nothing &&
        supports(ctx.state.protocol_version, :tasks) &&
        any(c -> c isa TaskCapability, ctx.server.config.capabilities)
end

"""
    task_principal(ctx::RequestContext) -> Union{String,Nothing}

The authorization principal tasks are bound to: the authenticated subject when HTTP
auth is enabled, otherwise `nothing` (single-user transports like stdio).
"""
task_principal(ctx::RequestContext) =
    ctx.authenticated_user === nothing ? nothing : ctx.authenticated_user.subject

"""
    tasks_list_offered(server::Server) -> Bool

Whether `tasks/list` is offered: requires a `TaskCapability` with `list=true`, and is
withheld on an HTTP transport without authentication (the server cannot identify
requestors there, so listing would expose task metadata across clients).
"""
function tasks_list_offered(server::Server)::Bool
    cap_idx = findfirst(c -> c isa TaskCapability, server.config.capabilities)
    cap_idx === nothing && return false
    server.config.capabilities[cap_idx].list || return false
    !(server.transport isa HttpTransport && server.transport.auth === nothing)
end

"""
    tasks_cancel_offered(server::Server) -> Bool

Whether `tasks/cancel` is offered (a `TaskCapability` with `cancel=true`), matching
what the capability advertises.
"""
function tasks_cancel_offered(server::Server)::Bool
    cap_idx = findfirst(c -> c isa TaskCapability, server.config.capabilities)
    cap_idx === nothing && return false
    server.config.capabilities[cap_idx].cancel
end

"""
    spawn_task_execution!(ctx::RequestContext, tool::MCPTool, args::AbstractDict,
                          record::TaskRecord) -> Nothing

Run a tool call in a background Julia task, recording the outcome into `record` and
emitting a `notifications/tasks/status` on the terminal transition. The execution
context carries the original request's progress token (valid for the task lifetime
per spec) and the task record (for `task_cancelled(ctx)`). If the task was cancelled
while running, the outcome is discarded.
"""
function spawn_task_execution!(ctx::RequestContext, tool::MCPTool, args::AbstractDict,
                               record::TaskRecord)::Nothing
    server = ctx.server
    task_ctx = RequestContext(
        server=server,
        state=ctx.state,
        request_id=ctx.request_id,
        progress_token=ctx.progress_token,
        authenticated_user=ctx.authenticated_user,
        task=record
    )
    Threads.@spawn begin
        outcome = try
            execute_tool_call(tool, args, task_ctx)
        catch e
            # execute_tool_call catches handler errors itself; this guards the glue
            ErrorInfo(code=ErrorCodes.INTERNAL_ERROR, message="Tool execution failed: $(e)")
        end
        if finish_task!(server.tasks, record, outcome)
            notify_task_status(server, record)
        end
    end
    nothing
end

"""
    notify_task_status(server::Server, record::TaskRecord) -> Nothing

Send an optional `notifications/tasks/status` with the task's full wire state.
Best-effort: failures are logged at debug level and never propagate (requestors must
not rely on these notifications per spec).
"""
function notify_task_status(server::Server, record::TaskRecord)::Nothing
    transport = server.transport
    transport === nothing && return nothing
    params = lock(server.tasks.lock) do
        Dict{String,Any}(task_wire(record))
    end
    try
        send_notification(
            transport,
            serialize_message(JSONRPCNotification(method="notifications/tasks/status", params=params))
        )
    catch e
        @debug "Failed to send task status notification" error=e
    end
    nothing
end

# Spec-mandated -32601 for tasks/* methods that are not in effect for this session
tasks_unsupported_result(method::String) = HandlerResult(
    error=ErrorInfo(
        code=ErrorCodes.METHOD_NOT_FOUND,
        message="Unknown method: $method"
    )
)

# Spec-mandated -32602 for unknown/expired/forbidden task ids; deliberately identical
# for "never existed", "expired and purged", and "bound to another principal" so task
# existence is not leaked across authorization contexts
task_not_found_result() = HandlerResult(
    error=ErrorInfo(
        code=ErrorCodes.INVALID_PARAMS,
        message="Failed to retrieve task: Task not found"
    )
)

"""
    with_related_task_meta(result::CallToolResult, task_id::String) -> CallToolResult

Return a copy of `result` whose `_meta` carries the spec-required
`io.modelcontextprotocol/related-task` association for `tasks/result` responses.
"""
function with_related_task_meta(result::CallToolResult, task_id::String)::CallToolResult
    meta = result._meta === nothing ? LittleDict{String,Any}() :
           LittleDict{String,Any}(result._meta)
    meta[RELATED_TASK_META_KEY] = LittleDict{String,Any}("taskId" => task_id)
    CallToolResult(
        content=result.content,
        is_error=result.is_error,
        structured_content=result.structured_content,
        _meta=meta
    )
end

"""
    task_terminal_response(request_id, record::TaskRecord) -> Response

Build the `tasks/result` response for a terminal task: exactly what the underlying
request would have returned — its `CallToolResult` (with the related-task `_meta`
added) or its JSON-RPC error. A task cancelled before completion has no underlying
result, so it answers with an error. Caller must hold the store lock.
"""
function task_terminal_response(request_id, record::TaskRecord)::Response
    if record.error !== nothing
        JSONRPCError(id=request_id, error=record.error)
    elseif record.result !== nothing
        JSONRPCResponse(
            id=request_id,
            result=with_related_task_meta(record.result, record.task_id)
        )
    else
        JSONRPCError(
            id=request_id,
            error=ErrorInfo(
                code=ErrorCodes.INVALID_PARAMS,
                message="Task was cancelled before completion: $(record.task_id)"
            )
        )
    end
end

"""
    handle_get_task(ctx::RequestContext, params::GetTaskParams) -> HandlerResult

Handle a `tasks/get` poll: return the task's current state, flattened into the result
per the spec (`GetTaskResult = Result & Task`).
"""
function handle_get_task(ctx::RequestContext, params::GetTaskParams)::HandlerResult
    tasks_supported(ctx) || return tasks_unsupported_result("tasks/get")
    store = ctx.server.tasks
    record = get_task(store, params.taskId, task_principal(ctx))
    record === nothing && return task_not_found_result()
    wire = lock(store.lock) do
        task_wire(record)
    end
    HandlerResult(response=JSONRPCResponse(id=ctx.request_id, result=wire))
end

"""
    handle_task_result(ctx::RequestContext, params::TaskResultParams) -> HandlerResult

Handle a `tasks/result` retrieval. For a terminal task, respond immediately with the
underlying call's result or error. For a non-terminal task the spec requires blocking
until terminal — the response route is detached from the (serial) server loop and a
waiter task delivers the response when the task finishes, so the loop stays free to
process `tasks/get` polls and the `tasks/cancel` that may be what unblocks this very
request.
"""
function handle_task_result(ctx::RequestContext, params::TaskResultParams)::HandlerResult
    tasks_supported(ctx) || return tasks_unsupported_result("tasks/result")
    store = ctx.server.tasks
    record = get_task(store, params.taskId, task_principal(ctx))
    record === nothing && return task_not_found_result()

    immediate = lock(store.lock) do
        task_is_terminal(record) ? task_terminal_response(ctx.request_id, record) : nothing
    end
    immediate !== nothing && return HandlerResult(response=immediate)

    # Non-terminal: block off-loop. (If the task turns terminal between the check
    # above and the wait below, the event is already set and the waiter returns
    # immediately — no missed wakeup.)
    transport = ctx.server.transport
    route = capture_response_route(transport)
    request_id = ctx.request_id
    Threads.@spawn begin
        wait(record.done)
        response = lock(store.lock) do
            task_terminal_response(request_id, record)
        end
        try
            deliver_response(transport, route, serialize_message(response))
        catch e
            @debug "Failed to deliver deferred tasks/result response" error=e
        end
    end
    HandlerResult(deferred=true)
end

"""
    handle_cancel_task(ctx::RequestContext, params::CancelTaskParams) -> HandlerResult

Handle a `tasks/cancel`: transition a non-terminal task to "cancelled" (waking any
blocked `tasks/result` requests) and return the task state. Cancelling a task already
in a terminal status is rejected with -32602 per spec.
"""
function handle_cancel_task(ctx::RequestContext, params::CancelTaskParams)::HandlerResult
    tasks_supported(ctx) || return tasks_unsupported_result("tasks/cancel")
    tasks_cancel_offered(ctx.server) || return tasks_unsupported_result("tasks/cancel")
    store = ctx.server.tasks
    record = get_task(store, params.taskId, task_principal(ctx))
    record === nothing && return task_not_found_result()

    if cancel_task!(store, record)
        notify_task_status(ctx.server, record)
        wire = lock(store.lock) do
            task_wire(record)
        end
        HandlerResult(response=JSONRPCResponse(id=ctx.request_id, result=wire))
    else
        status = lock(store.lock) do
            record.status
        end
        HandlerResult(
            error=ErrorInfo(
                code=ErrorCodes.INVALID_PARAMS,
                message="Cannot cancel task: already in terminal status '$(status)'"
            )
        )
    end
end

"""
    handle_list_tasks(ctx::RequestContext, params::ListTasksParams) -> HandlerResult

Handle a paginated `tasks/list`, restricted to the requestor's authorization context.
Not offered (-32601) when the server cannot identify requestors (HTTP without auth).
"""
function handle_list_tasks(ctx::RequestContext, params::ListTasksParams)::HandlerResult
    tasks_supported(ctx) || return tasks_unsupported_result("tasks/list")
    tasks_list_offered(ctx.server) || return tasks_unsupported_result("tasks/list")
    store = ctx.server.tasks
    page, next = try
        list_tasks(store, task_principal(ctx), params.cursor)
    catch e
        e isa ArgumentError || rethrow(e)
        return HandlerResult(
            error=ErrorInfo(code=ErrorCodes.INVALID_PARAMS, message="Invalid cursor")
        )
    end
    result = lock(store.lock) do
        d = LittleDict{String,Any}("tasks" => [task_wire(r) for r in page])
        next !== nothing && (d["nextCursor"] = next)
        d
    end
    HandlerResult(response=JSONRPCResponse(id=ctx.request_id, result=result))
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
            # Use input_schema if provided, otherwise build from parameters
            schema = if !isnothing(tool.input_schema)
                # Use the raw input_schema directly
                tool.input_schema
            else
                # Build schema from parameters (original behavior). Declare the
                # JSON Schema dialect the MCP spec defaults to (2020-12); a raw
                # input_schema above is passed through verbatim, dialect included.
                LittleDict{String,Any}(
                    "\$schema" => "https://json-schema.org/draft/2020-12/schema",
                    "type" => "object",
                    "properties" => Dict(
                        param.name => begin
                            param_schema = LittleDict{String,Any}(
                                "type" => param.type,
                                "description" => param.description
                            )
                            # Add default value to schema if it exists
                            if !isnothing(param.default)
                                param_schema["default"] = param.default
                            end
                            param_schema
                        end for param in tool.parameters
                    ),
                    "required" => [p.name for p in tool.parameters if p.required]
                )
            end

            d = LittleDict{String,Any}(
                "name" => tool.name,
                "description" => tool.description,
                "inputSchema" => schema
            )
            !isnothing(tool.title) && (d["title"] = tool.title)
            !isnothing(tool.icons) && (d["icons"] = [icon_to_dict(i) for i in tool.icons])
            !isnothing(tool.annotations) && (d["annotations"] = tool.annotations)
            !isnothing(tool.output_schema) && (d["outputSchema"] = tool.output_schema)
            !isnothing(tool._meta) && (d["_meta"] = tool._meta)
            # Tool-level task negotiation (MCP Tasks): only meaningful — and only
            # emitted — for sessions where the tasks capability is in effect
            if tasks_supported(ctx) && tool.task_support in (:optional, :required)
                d["execution"] = LittleDict{String,Any}("taskSupport" => String(tool.task_support))
            end
            d
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
    handle_request(server::Server, state::ServerState, request::Request) -> Response

Process an MCP protocol request and route it to the appropriate handler based on the request method.

# Arguments
- `server::Server`: The MCP server instance handling the request
- `state::ServerState`: The persistent server state, threaded into the request context (carries the negotiated protocol version)
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
function handle_request(server::Server, state::ServerState, request::Request;
                        authenticated_user::Union{AuthenticatedUser,Nothing}=nothing)::Union{Response,Nothing}
    ctx = RequestContext(
        server=server,
        state=state,
        request_id=request.id,
        progress_token=request.meta.progress_token,
        authenticated_user=authenticated_user
    )

    request_start = time()
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
            elseif request.method == "resources/templates/list"
                # Handle null params (cursor is optional)
                params = isnothing(request.params) ? ListResourceTemplatesParams() : request.params::ListResourceTemplatesParams
                handle_list_resource_templates(ctx, params)
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
            elseif request.method == "logging/setLevel"
                handle_set_level(ctx, request.params::SetLevelParams)
            elseif request.method == "tasks/get"
                handle_get_task(ctx, request.params::GetTaskParams)
            elseif request.method == "tasks/result"
                handle_task_result(ctx, request.params::TaskResultParams)
            elseif request.method == "tasks/cancel"
                handle_cancel_task(ctx, request.params::CancelTaskParams)
            elseif request.method == "tasks/list"
                # Handle null params (cursor is optional)
                params = isnothing(request.params) ? ListTasksParams() : request.params::ListTasksParams
                handle_list_tasks(ctx, params)
            else
                HandlerResult(
                    error=ErrorInfo(
                        code=ErrorCodes.METHOD_NOT_FOUND,
                        message="Unknown method: $(request.method)"
                    )
                )
            end

        # Request-lifecycle log line: quiet by default (Debug); enable at runtime with
        # logging/setLevel "debug" to see method/id/duration/outcome per request
        @debug "request completed" method=request.method id=request.id duration_ms=round((time() - request_start) * 1000; digits=2) ok=isnothing(result.error)

        # Return response or error. A deferred result (e.g. a blocking tasks/result)
        # returns nothing: the response will be delivered later via deliver_response.
        if !isnothing(result.error)
            JSONRPCError(id=ctx.request_id, error=result.error)
        elseif result.deferred
            nothing
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
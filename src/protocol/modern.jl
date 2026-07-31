# src/protocol/modern.jl
# Modern-era (2026-07-28+) stateless request handling.
#
# A request carrying `io.modelcontextprotocol/protocolVersion` in its params `_meta`
# is modern-era: it is served statelessly — no `initialize` handshake, version and
# client capabilities validated per request — while `initialize` continues to select
# legacy semantics (dual-era server, per the 2026-07-28 backward-compatibility model).
# Feature handlers are shared between the eras; this file owns era validation, the
# modern method surface, `server/discover`, and the modern result envelope
# (`resultType` + `serverInfo` in result `_meta`).

"""
Methods served in the modern era. Methods REMOVED from the modern era — `ping`,
`logging/setLevel`, `resources/subscribe`/`unsubscribe` (replaced by
`subscriptions/listen`), and the core `tasks/*` family (moved to the
`io.modelcontextprotocol/tasks` extension) — return METHOD_NOT_FOUND on modern
requests even though the legacy era serves them.
"""
const MODERN_METHODS = Set([
    "server/discover",
    "tools/list",
    "tools/call",
    "resources/list",
    "resources/read",
    "resources/templates/list",
    "prompts/list",
    "prompts/get",
])

# Caching hints for server/discover (a CacheableResult): the advertised versions and
# capabilities are static for a server process, so a long shared-cache TTL fits
const DISCOVER_TTL_MS = 3_600_000
const DISCOVER_CACHE_SCOPE = "public"

"""
    modernize_error_code(code::Int) -> Int

Map error codes forbidden on modern-era responses to their replacements: the spec
reserves `-32002` (resource not found in ≤2025-11-25) and replaces it with `-32602`
(Invalid params); implementations of 2026-07-28 MUST NOT emit it.

# Arguments
- `code::Int`: A legacy-era error code

# Returns
- `Int`: The code to emit on a modern-era response
"""
modernize_error_code(code::Int)::Int = code == -32002 ? ErrorCodes.INVALID_PARAMS : code

"""
    modern_result_envelope(response::JSONRPCResponse, server::Server) -> JSONRPCResponse

Apply the modern-era result envelope: every result MUST carry `resultType`
(`"complete"` unless the handler set one) and SHOULD identify the server via
`io.modelcontextprotocol/serverInfo` in the result's `_meta`. The handler result is
normalized to its wire shape (plain dicts) so the fields can be attached regardless
of the concrete result type the handler returned.

# Arguments
- `response::JSONRPCResponse`: The handler's response
- `server::Server`: The server (for `serverInfo`)

# Returns
- `JSONRPCResponse`: A response whose result carries the modern envelope fields
"""
function modern_result_envelope(response::JSONRPCResponse, server::Server)::JSONRPCResponse
    raw = JSON3.read(JSON3.write(response.result), Dict{String,Any})
    haskey(raw, "resultType") || (raw["resultType"] = "complete")
    meta = get(raw, "_meta", nothing)
    if !(meta isa AbstractDict)
        meta = Dict{String,Any}()
        raw["_meta"] = meta
    end
    server_info = Dict{String,Any}(
        "name" => server.config.name,
        "version" => server.config.version,
    )
    meta[META_SERVER_INFO] = server_info
    JSONRPCResponse(id = response.id, result = raw)
end

"""
    handle_discover(ctx::RequestContext) -> HandlerResult

Handle `server/discover` (a server MUST in the modern era): advertise the protocol
versions this server supports across both eras, its capabilities, and optional
instructions, with the CacheableResult fields (`ttlMs`, `cacheScope`) the spec
requires on discovery results. `resultType` and `serverInfo` are attached by the
modern envelope.

# Arguments
- `ctx::RequestContext`: The current request context

# Returns
- `HandlerResult`: The discovery result
"""
function handle_discover(ctx::RequestContext)::HandlerResult
    caps = capabilities_to_protocol(ctx.server.config.capabilities, ctx.server)
    # Legacy-only capabilities don't exist in the modern era: core tasks moved to the
    # io.modelcontextprotocol/tasks extension (not yet advertised) and logging/setLevel
    # was removed (per-request logLevel delivery is not yet advertised either)
    delete!(caps, "tasks")
    delete!(caps, "logging")

    result = LittleDict{String,Any}(
        "supportedVersions" => vcat(MODERN_PROTOCOL_VERSIONS, SUPPORTED_PROTOCOL_VERSIONS),
        "capabilities" => caps,
        "ttlMs" => DISCOVER_TTL_MS,
        "cacheScope" => DISCOVER_CACHE_SCOPE,
    )
    isempty(ctx.server.config.instructions) || (result["instructions"] = ctx.server.config.instructions)

    HandlerResult(
        response = JSONRPCResponse(
            id = ctx.request_id,
            result = result
        )
    )
end

"""
    dispatch_modern(ctx::RequestContext, request::Request) -> HandlerResult

Route a validated modern-era request to its handler. Shared feature handlers
(tools, resources, prompts) are reused from the legacy era; `server/discover` is
modern-only.

# Arguments
- `ctx::RequestContext`: The request context (carries the per-request protocol version)
- `request::Request`: The parsed request

# Returns
- `HandlerResult`: The handler's result
"""
function dispatch_modern(ctx::RequestContext, request::Request)::HandlerResult
    if request.method == "server/discover"
        handle_discover(ctx)
    elseif request.method == "tools/list"
        params = isnothing(request.params) ? ListToolsParams() : request.params::ListToolsParams
        handle_list_tools(ctx, params)
    elseif request.method == "tools/call"
        handle_call_tool(ctx, request.params::CallToolParams)
    elseif request.method == "resources/list"
        params = isnothing(request.params) ? ListResourcesParams() : request.params::ListResourcesParams
        handle_list_resources(ctx, params)
    elseif request.method == "resources/read"
        handle_read_resource(ctx, request.params::ReadResourceParams)
    elseif request.method == "resources/templates/list"
        params = isnothing(request.params) ? ListResourceTemplatesParams() : request.params::ListResourceTemplatesParams
        handle_list_resource_templates(ctx, params)
    elseif request.method == "prompts/list"
        params = isnothing(request.params) ? ListPromptsParams() : request.params::ListPromptsParams
        handle_list_prompts(ctx, params)
    elseif request.method == "prompts/get"
        handle_get_prompt(ctx, request.params::GetPromptParams)
    else
        HandlerResult(
            error = ErrorInfo(
                code = ErrorCodes.METHOD_NOT_FOUND,
                message = "Unknown method: $(request.method)"
            )
        )
    end
end

"""
    handle_modern_request(server::Server, state::ServerState, request::Request;
                          authenticated_user=nothing) -> Union{Response,Nothing}

Serve a modern-era (2026-07-28+) request statelessly: validate the per-request
`_meta` protocol fields, dispatch to the shared feature handlers, and apply the
modern result envelope. Session state is never consulted for era metadata — every
request is self-contained — and the legacy session's negotiated version is left
untouched, so both eras can interleave on one server.

Validation, in order (per the spec):
- unsupported `protocolVersion` → `UnsupportedProtocolVersionError` (-32022) with
  `data.supported`/`data.requested`
- missing `clientCapabilities` → -32602 Invalid params (a required `_meta` field)
- method not in the modern surface → -32601 Method not found

`notifications/message` is never emitted for modern requests: the spec forbids it
for requests that did not set `io.modelcontextprotocol/logLevel`, and per-request
log level support is not yet implemented (emission is a MAY).

# Arguments
- `server::Server`: The MCP server instance
- `state::ServerState`: Server state (used only as context plumbing; not read for era metadata)
- `request::Request`: The parsed request (with `meta.protocol_version` set)
- `authenticated_user`: Per-request identity from HTTP auth, else `nothing`

# Returns
- `Union{Response,Nothing}`: The response to send
"""
function handle_modern_request(server::Server, state::ServerState, request::Request;
                               authenticated_user::Union{AuthenticatedUser,Nothing}=nothing)::Union{Response,Nothing}
    version = request.meta.protocol_version

    # server/discover routes here even without modern _meta (it exists in no other
    # era); a missing protocolVersion is a missing REQUIRED field -> Invalid params
    if version === nothing
        return JSONRPCError(
            id = request.id,
            error = ErrorInfo(
                code = ErrorCodes.INVALID_PARAMS,
                message = "Missing required _meta field: $(META_PROTOCOL_VERSION)"
            )
        )
    end

    if !(version in MODERN_PROTOCOL_VERSIONS)
        return JSONRPCError(
            id = request.id,
            error = ErrorInfo(
                code = ErrorCodes.UNSUPPORTED_PROTOCOL_VERSION,
                message = "Unsupported protocol version",
                data = Dict{String,Any}(
                    "supported" => vcat(MODERN_PROTOCOL_VERSIONS, SUPPORTED_PROTOCOL_VERSIONS),
                    "requested" => version
                )
            )
        )
    end

    if request.meta.client_capabilities === nothing
        return JSONRPCError(
            id = request.id,
            error = ErrorInfo(
                code = ErrorCodes.INVALID_PARAMS,
                message = "Missing required _meta field: $(META_CLIENT_CAPABILITIES)"
            )
        )
    end

    if !(request.method in MODERN_METHODS)
        return JSONRPCError(
            id = request.id,
            error = ErrorInfo(
                code = ErrorCodes.METHOD_NOT_FOUND,
                message = "Unknown method: $(request.method)"
            )
        )
    end

    ctx = RequestContext(
        server = server,
        state = state,
        request_id = request.id,
        progress_token = request.meta.progress_token,
        authenticated_user = authenticated_user,
        protocol_version = version
    )

    request_start = time()
    result = try
        # Suppress notifications/message for the duration: modern requests carry no
        # logLevel yet, and emitting without one is forbidden
        task_local_storage(:mcp_suppress_log_notifications, true) do
            dispatch_modern(ctx, request)
        end
    catch e
        @debug "modern request failed" method=request.method id=request.id error=e
        return JSONRPCError(
            id = ctx.request_id,
            error = ErrorInfo(
                code = ErrorCodes.INTERNAL_ERROR,
                message = "Internal error: $(e)"
            )
        )
    end

    @debug "request completed" method=request.method id=request.id era="modern" duration_ms=round((time() - request_start) * 1000; digits=2) ok=isnothing(result.error)

    if !isnothing(result.error)
        err = result.error
        JSONRPCError(
            id = ctx.request_id,
            error = ErrorInfo(
                code = modernize_error_code(err.code),
                message = err.message,
                data = err.data
            )
        )
    elseif result.deferred
        # No modern method defers today (core tasks are legacy-only); kept for shape
        nothing
    else
        modern_result_envelope(result.response, server)
    end
end

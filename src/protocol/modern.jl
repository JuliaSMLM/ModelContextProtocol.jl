# src/protocol/modern.jl
# Modern-era (2026-07-28+) stateless request handling.
#
# A request carrying `io.modelcontextprotocol/protocolVersion` in its params `_meta`
# is modern-era: it is served statelessly — no `initialize` handshake, version and
# client capabilities validated per request — while `initialize` selects legacy
# semantics (dual-era server, per the 2026-07-28 spec's backward-compatibility
# model). Feature handlers are shared between the eras; this file owns era
# validation, the modern method surface, `server/discover`, and the modern result
# envelope (`resultType` + `serverInfo` in result `_meta` + CacheableResult fields).

"""
Methods served in the modern era, each gated on the capability that provides it
(`nothing` = always available). Methods REMOVED from the modern era — `ping`,
`logging/setLevel`, `resources/subscribe`/`unsubscribe` (replaced by
`subscriptions/listen`), and the core `tasks/*` family (moved to the
`io.modelcontextprotocol/tasks` extension) — return METHOD_NOT_FOUND on modern
requests even though the legacy era serves them. A method whose capability the
server does not declare is equally METHOD_NOT_FOUND: the advertised capability set
and the callable surface must agree.
"""
const MODERN_METHODS = Dict{String,Union{DataType,Nothing}}(
    "server/discover" => nothing,
    "tools/list" => ToolCapability,
    "tools/call" => ToolCapability,
    "resources/list" => ResourceCapability,
    "resources/read" => ResourceCapability,
    "resources/templates/list" => ResourceCapability,
    "prompts/list" => PromptCapability,
    "prompts/get" => PromptCapability,
    "subscriptions/listen" => nothing,
)

"""
Modern methods whose complete results are CacheableResults: the spec REQUIRES
`ttlMs` and `cacheScope` on them.
"""
const MODERN_CACHEABLE_METHODS = Set([
    "server/discover",
    "tools/list",
    "prompts/list",
    "resources/list",
    "resources/templates/list",
    "resources/read",
])

# Caching hints. server/discover advertises a static shape for a server process, so a
# long TTL fits; list/read results default to ttlMs=0 (immediately stale — the spec
# requires the fields' presence, not a caching promise, and 0 preserves today's
# always-fresh behavior).
const DISCOVER_TTL_MS = 3_600_000
const DEFAULT_CACHE_TTL_MS = 0

"""
    modern_cache_scope(server::Server) -> String

The `cacheScope` for this server's cacheable results: `"private"` when bearer auth is
enabled (responses are served inside an authorization context and MUST NOT be shared
across contexts by intermediaries), `"public"` otherwise.

# Arguments
- `server::Server`: The server instance

# Returns
- `String`: `"public"` or `"private"`
"""
function modern_cache_scope(server::Server)::String
    t = server.transport
    (t isa HttpTransport && is_auth_enabled(t)) ? "private" : "public"
end

"""
    modernize_error_code(code::Int) -> Int

Map legacy-range error codes to their modern-era replacements. The 2026-07-28
allocation policy grandfathers `-32000`..`-32019` for legacy responses but modern
responses must use spec codes: not-found conditions for resources (`-32000`), tools
(`-32001`), URIs (`-32002`, reserved — MUST NOT be emitted), and prompts (`-32003`)
are all `-32602` Invalid params in the modern era.

# Arguments
- `code::Int`: A legacy-era error code

# Returns
- `Int`: The code to emit on a modern-era response
"""
modernize_error_code(code::Int)::Int =
    code in (-32000, -32001, -32002, -32003) ? ErrorCodes.INVALID_PARAMS : code

"""
    modern_result_envelope(response::JSONRPCResponse, server::Server) -> JSONRPCResponse

Apply the modern-era result envelope: every result MUST carry `resultType`
(`"complete"` unless the handler set one) and SHOULD identify the server via
`io.modelcontextprotocol/serverInfo` in the result's `_meta` (merged into any
handler-provided `_meta`).

The known handler result types are re-shaped WITHOUT a JSON round-trip, so values
travel by reference — no numeric precision loss (Int64 above 2^53 survives) and no
extra copies of base64 payloads. Only unknown result types fall back to an untyped
JSON3 round-trip (which preserves Int64, unlike a `Dict{String,Any}`-typed read).

# Arguments
- `response::JSONRPCResponse`: The handler's response
- `server::Server`: The server (for `serverInfo`)

# Returns
- `JSONRPCResponse`: A response whose result carries the modern envelope fields
"""
function modern_result_envelope(response::JSONRPCResponse, server::Server)::JSONRPCResponse
    result = response.result

    envelope = if result isa AbstractDict
        # Shallow copy; values by reference
        d = LittleDict{String,Any}()
        for (k, v) in result
            d[String(k)] = v
        end
        d
    elseif result isa CallToolResult
        # Mirror the StructTypes wire contract (names + omitempties) by hand
        d = LittleDict{String,Any}("content" => result.content, "isError" => result.is_error)
        result.structured_content !== nothing && (d["structuredContent"] = result.structured_content)
        result._meta !== nothing && (d["_meta"] = result._meta)
        d
    elseif result isa ReadResourceResult
        LittleDict{String,Any}("contents" => result.contents)
    else
        # Unknown result type: one untyped round-trip (JSON3.Object keeps Int64;
        # a Dict{String,Any}-typed read would coerce numbers to Float64)
        obj = JSON3.read(JSON3.write(result))
        d = LittleDict{String,Any}()
        for (k, v) in pairs(obj)
            d[String(k)] = v
        end
        d
    end

    # resultType MUST be a string; a handler-set value is honored, anything else
    # (absent or non-string) becomes "complete"
    rt = get(envelope, "resultType", nothing)
    rt isa AbstractString || (envelope["resultType"] = "complete")

    # Merge serverInfo into any handler-provided _meta (a non-dict _meta is dropped)
    merged = LittleDict{String,Any}()
    meta = get(envelope, "_meta", nothing)
    if meta isa AbstractDict
        for (k, v) in meta
            merged[String(k)] = v
        end
    elseif meta !== nothing
        @debug "Dropping non-object result _meta on modern response" typeof(meta)
    end
    merged[META_SERVER_INFO] = Dict{String,Any}(
        "name" => server.config.name,
        "version" => server.config.version,
    )
    envelope["_meta"] = merged

    JSONRPCResponse(id = response.id, result = envelope)
end

"""
    handle_discover(ctx::RequestContext) -> HandlerResult

Handle `server/discover` (a server MUST in the modern era): advertise the protocol
versions this server supports across both eras, its modern capability surface, and
optional instructions, with the CacheableResult fields (`ttlMs`, `cacheScope`) the
spec requires on discovery results. `resultType` and `serverInfo` are attached by
the modern envelope.

Capabilities carry only what the modern era actually serves: the features present,
their `listChanged`/`subscribe` flags (delivered via `subscriptions/listen`), and no
legacy-only `tasks`/`logging` — and never the legacy builder's embedded resource
listings, which would leak resource metadata into shared caches and do not match the
modern ServerCapabilities shape.

# Arguments
- `ctx::RequestContext`: The current request context

# Returns
- `HandlerResult`: The discovery result
"""
function handle_discover(ctx::RequestContext)::HandlerResult
    caps = LittleDict{String,Any}()
    for c in ctx.server.config.capabilities
        if c isa ToolCapability
            d = LittleDict{String,Any}()
            c.list_changed && (d["listChanged"] = true)
            caps["tools"] = d
        elseif c isa ResourceCapability
            d = LittleDict{String,Any}()
            c.list_changed && (d["listChanged"] = true)
            c.subscribe && (d["subscribe"] = true)
            caps["resources"] = d
        elseif c isa PromptCapability
            d = LittleDict{String,Any}()
            c.list_changed && (d["listChanged"] = true)
            caps["prompts"] = d
        end
    end

    result = LittleDict{String,Any}(
        "supportedVersions" => vcat(MODERN_PROTOCOL_VERSIONS, SUPPORTED_PROTOCOL_VERSIONS),
        "capabilities" => caps,
        "ttlMs" => DISCOVER_TTL_MS,
        "cacheScope" => modern_cache_scope(ctx.server),
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
    modern_invalid_params(ctx::RequestContext, method::String) -> HandlerResult

Build the -32602 Invalid params result for a modern request whose typed parameters
are missing or malformed.
"""
modern_invalid_params(ctx::RequestContext, method::String) = HandlerResult(
    error = ErrorInfo(
        code = ErrorCodes.INVALID_PARAMS,
        message = "Invalid params for $(method)"
    )
)

"""
    dispatch_modern(ctx::RequestContext, request::Request) -> HandlerResult

Route a validated modern-era request to its handler. Shared feature handlers
(tools, resources, prompts) are reused from the legacy era; `server/discover` is
modern-only. Requests whose typed params failed to parse get -32602 rather than an
internal error.

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
        params = request.params isa ListToolsParams ? request.params : ListToolsParams()
        handle_list_tools(ctx, params)
    elseif request.method == "tools/call"
        request.params isa CallToolParams || return modern_invalid_params(ctx, request.method)
        handle_call_tool(ctx, request.params)
    elseif request.method == "resources/list"
        params = request.params isa ListResourcesParams ? request.params : ListResourcesParams()
        handle_list_resources(ctx, params)
    elseif request.method == "resources/read"
        request.params isa ReadResourceParams || return modern_invalid_params(ctx, request.method)
        handle_read_resource(ctx, request.params)
    elseif request.method == "resources/templates/list"
        params = request.params isa ListResourceTemplatesParams ? request.params : ListResourceTemplatesParams()
        handle_list_resource_templates(ctx, params)
    elseif request.method == "prompts/list"
        params = request.params isa ListPromptsParams ? request.params : ListPromptsParams()
        handle_list_prompts(ctx, params)
    elseif request.method == "prompts/get"
        request.params isa GetPromptParams || return modern_invalid_params(ctx, request.method)
        handle_get_prompt(ctx, request.params)
    elseif request.method == "subscriptions/listen"
        request.params isa SubscriptionsListenParams || return modern_invalid_params(ctx, request.method)
        handle_subscriptions_listen(ctx, request.params)
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
    modern_method_available(server::Server, method::String) -> Bool

Whether `method` exists on this server's modern surface: it must be a modern-era
method AND its providing capability must be declared — the advertised capability set
and the callable surface must agree.

# Arguments
- `server::Server`: The server instance
- `method::String`: The request method

# Returns
- `Bool`: true when the method is callable in the modern era
"""
function modern_method_available(server::Server, method::String)::Bool
    haskey(MODERN_METHODS, method) || return false
    cap = MODERN_METHODS[method]
    cap === nothing && return true
    any(c -> c isa cap, server.config.capabilities)
end

"""
    handle_modern_request(server::Server, state::ServerState, request::Request;
                          authenticated_user=nothing) -> Union{Response,Nothing}

Serve a modern-era (2026-07-28+) request statelessly: validate the per-request
`_meta` protocol fields, dispatch to the shared feature handlers, and apply the
modern result envelope plus the CacheableResult fields where required. The handler
context gets a FRESH `ServerState` — modern requests are self-contained, and a
ctx-aware tool handler must not be able to mutate the legacy session's state.

Validation, in order (per the spec):
- missing `protocolVersion` (only reachable for `server/discover`, which routes
  modern unconditionally) → -32602 Invalid params
- unsupported `protocolVersion` → `UnsupportedProtocolVersionError` (-32022) with
  `data.supported`/`data.requested`
- missing `clientCapabilities` → -32602 Invalid params (a required `_meta` field)
- method not on the modern surface (or its capability undeclared) → -32601

`notifications/message` is never emitted for modern requests: the spec forbids it
for requests that did not set `io.modelcontextprotocol/logLevel`, and per-request
log level support is not yet implemented (emission is a MAY). The suppression flag
is set for the remainder of the loop iteration — the server loop re-arms it per
message — so the loop's own post-dispatch lifecycle records are covered too.

# Arguments
- `server::Server`: The MCP server instance
- `state::ServerState`: The legacy session state (NOT given to handlers; see above)
- `request::Request`: The parsed request (with `meta.protocol_version` set)
- `authenticated_user`: Per-request identity from HTTP auth, else `nothing`

# Returns
- `Union{Response,Nothing}`: The response to send
"""
function handle_modern_request(server::Server, state::ServerState, request::Request;
                               authenticated_user::Union{AuthenticatedUser,Nothing}=nothing)::Union{Response,Nothing}
    # Suppress notifications/message from here through the END of this loop
    # iteration (the loop re-arms the flag per message): parser/dispatch/post-
    # dispatch log records must not reach a modern client that set no logLevel,
    # even when a legacy client previously enabled debug delivery.
    task_local_storage(:mcp_suppress_log_notifications, true)

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

    if !modern_method_available(server, request.method)
        return JSONRPCError(
            id = request.id,
            error = ErrorInfo(
                code = ErrorCodes.METHOD_NOT_FOUND,
                message = "Unknown method: $(request.method)"
            )
        )
    end

    # MRTR retry: an offered requestState is ATTACKER-CONTROLLED and must verify
    # (signature, TTL, principal, method, original-params digest) BEFORE any
    # handler runs. A PRESENT but mistyped retry field is rejected, never treated
    # as absent — a numeric requestState must not bypass verification, and a
    # scalar inputResponses must not silently re-elicit.
    if request.meta.has_request_state && request.meta.request_state === nothing
        return JSONRPCError(
            id = request.id,
            error = ErrorInfo(
                code = ErrorCodes.INVALID_PARAMS,
                message = "Invalid requestState: must be a string"
            )
        )
    end
    if request.meta.has_input_responses && request.meta.input_responses === nothing
        return JSONRPCError(
            id = request.id,
            error = ErrorInfo(
                code = ErrorCodes.INVALID_PARAMS,
                message = "Invalid inputResponses: must be an object"
            )
        )
    end
    mrtr_state = nothing
    if request.meta.request_state !== nothing
        ok, payload = verify_request_state(server, request.meta.request_state,
                                           request.method,
                                           request.meta.params_digest,
                                           mrtr_principal(authenticated_user))
        ok || return JSONRPCError(
            id = request.id,
            error = ErrorInfo(
                code = ErrorCodes.INVALID_PARAMS,
                message = "Invalid requestState: $payload"
            )
        )
        mrtr_state = payload
    end

    # Fresh state: modern requests are stateless, and handlers (including ctx-aware
    # tool handlers) must not see or mutate the legacy session's ServerState
    ctx = RequestContext(
        server = server,
        state = ServerState(),
        request_id = request.id,
        progress_token = request.meta.progress_token,
        authenticated_user = authenticated_user,
        protocol_version = version,
        input_responses = request.meta.input_responses,
        input_state = mrtr_state
    )

    request_start = time()
    result = try
        dispatch_modern(ctx, request)
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
        # subscriptions/listen defers: its route is captured and the stream is
        # served out-of-loop, so there is no response to emit here
        nothing
    elseif !isnothing(result.response) && result.response.result isa InputRequired
        # MRTR: the handler needs client input. A server MUST NOT send
        # inputRequests whose capability this request did not declare — that is
        # the -32021 rejection — otherwise answer with the InputRequiredResult
        # (resultType input_required + inputRequests + a minted requestState).
        ir = result.response.result
        required = undeclared_capability_requirements(ir, request.meta.client_capabilities)
        if !isempty(required)
            JSONRPCError(
                id = ctx.request_id,
                error = ErrorInfo(
                    code = ErrorCodes.MISSING_REQUIRED_CLIENT_CAPABILITY,
                    message = "Request requires undeclared client capabilities: $(join(keys(required), ", "))",
                    data = Dict{String,Any}("requiredCapabilities" => required)
                )
            )
        else
            envelope = input_required_envelope(server, ir, request.method,
                                               request.meta.params_digest,
                                               mrtr_principal(authenticated_user))
            modern_result_envelope(JSONRPCResponse(id = ctx.request_id, result = envelope), server)
        end
    else
        response = modern_result_envelope(result.response, server)
        # CacheableResult fields are REQUIRED on complete results of the cacheable
        # methods (discover set its own above)
        if request.method in MODERN_CACHEABLE_METHODS && response.result isa AbstractDict
            haskey(response.result, "ttlMs") || (response.result["ttlMs"] = DEFAULT_CACHE_TTL_MS)
            haskey(response.result, "cacheScope") || (response.result["cacheScope"] = modern_cache_scope(server))
        end
        response
    end
end

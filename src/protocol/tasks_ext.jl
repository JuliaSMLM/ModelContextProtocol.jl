# src/protocol/tasks_ext.jl
#
# The MCP Tasks extension (`io.modelcontextprotocol/tasks`, SEP-2663) — the modern
# era's replacement for the experimental SEP-1686 core tasks. Task creation is
# server-directed: a client declares the extension in its per-request `_meta`
# clientCapabilities, and a tool handler hands off to background execution with
# `task_detach(ctx)`, which delivers a flat `CreateTaskResult` while the handler
# keeps running. Clients poll `tasks/get` (results inlined; there is no
# `tasks/result`), answer mid-task input via `tasks/update`, and cancel with the
# ack-only `tasks/cancel`. The legacy era's task surface is untouched: the two eras
# share the `TaskStore` but records are era-tagged and never served across eras.

const TASKS_EXTENSION_ID = "io.modelcontextprotocol/tasks"

"""
    tasks_extension_declared(client_capabilities) -> Bool

Whether this request declared the `io.modelcontextprotocol/tasks` extension in its
`_meta` clientCapabilities. Declaration means the extension key is present under
`extensions` with an OBJECT value (the spec's "an empty object indicates support";
a `null` or scalar value declares nothing, matching the MRTR capability rules).
"""
function tasks_extension_declared(client_capabilities)::Bool
    exts = _capability_value(client_capabilities, "extensions")
    _capability_value(exts, TASKS_EXTENSION_ID) isa AbstractDict
end

"""
    tasks_extension_required_error() -> ErrorInfo

The -32021 MissingRequiredClientCapability error for task-surface requests from a
client that did not declare the tasks extension, carrying the spec's
`requiredCapabilities` object naming the extension.
"""
tasks_extension_required_error() = ErrorInfo(
    code = ErrorCodes.MISSING_REQUIRED_CLIENT_CAPABILITY,
    message = "Missing required client capability: extension $(TASKS_EXTENSION_ID)",
    data = Dict{String,Any}(
        "requiredCapabilities" => Dict{String,Any}(
            "extensions" => Dict{String,Any}(TASKS_EXTENSION_ID => Dict{String,Any}())
        )
    )
)

"""
    call_tool_result_wire(result::CallToolResult) -> LittleDict{String,Any}

Serialize a `CallToolResult` to the plain result object inlined on a completed
task (`tasks/get` `result` field): `content`/`isError` plus `structuredContent`
and `_meta` when present. No `resultType` (it is a nested result, not a response
envelope) and no legacy `related-task` `_meta` (the `taskId` is already at the
response root, and SEP-2663 forbids the redundant key).
"""
function call_tool_result_wire(result::CallToolResult)::LittleDict{String,Any}
    d = LittleDict{String,Any}("content" => result.content, "isError" => result.is_error)
    result.structured_content !== nothing && (d["structuredContent"] = result.structured_content)
    result._meta !== nothing && (d["_meta"] = result._meta)
    d
end

"""
    ext_task_wire(record::TaskRecord; detailed::Bool=false) -> LittleDict{String,Any}

Serialize a task record to the SEP-2663 wire shape: `taskId`, `status`, optional
`statusMessage`, `createdAt`/`lastUpdatedAt` (ISO 8601 UTC), `ttlMs` (always
present; `null` = unlimited), and `pollIntervalMs` — integer milliseconds, and
never the legacy `ttl`/`pollInterval` keys. With `detailed=true` the
status-specific DetailedTask payload is inlined: `result` for "completed",
`error` for "failed", `inputRequests` for "input_required". Caller must hold the
store lock.
"""
function ext_task_wire(record::TaskRecord; detailed::Bool=false)::LittleDict{String,Any}
    d = LittleDict{String,Any}(
        "taskId" => record.task_id,
        "status" => record.status
    )
    record.status_message !== nothing && (d["statusMessage"] = record.status_message)
    d["createdAt"] = iso8601_utc(record.created_at)
    d["lastUpdatedAt"] = iso8601_utc(record.last_updated_at)
    d["ttlMs"] = record.ttl_ms
    record.poll_interval_ms !== nothing && (d["pollIntervalMs"] = record.poll_interval_ms)
    if detailed
        if record.status == "completed" && record.result !== nothing
            d["result"] = call_tool_result_wire(record.result)
        elseif record.status == "failed" && record.error !== nothing
            err = LittleDict{String,Any}(
                "code" => record.error.code,
                "message" => record.error.message
            )
            record.error.data !== nothing && (err["data"] = record.error.data)
            d["error"] = err
        elseif record.status == "input_required"
            # Outstanding input requests (tasks/update flow) land here; until that
            # flow exists no record can reach this status, but the shape is fixed
            d["inputRequests"] = LittleDict{String,Any}()
        end
    end
    d
end

"""
    task_detach(ctx; ttl_ms=nothing, status_message=nothing) -> Bool

Hand the current tool call off to background task execution (MCP Tasks extension,
SEP-2663). Callable from a ctx-aware tool handler: when the request is modern-era,
the tool is task-capable (`task_support` `:optional` or `:required`), and the
client declared the `io.modelcontextprotocol/tasks` extension, this durably
creates the task and immediately delivers the `CreateTaskResult`
(`resultType:"task"`) as the call's response — the handler keeps running in the
background, and its eventual return value (or thrown error) becomes the task's
terminal state, observable via `tasks/get`.

Returns `false` — and the handler simply continues as an ordinary synchronous
call — when any precondition is absent (legacy-era request, extension not
declared, tool not task-capable). Idempotent: a second call returns `true`
without creating another task.

# Arguments
- `ctx`: The request context passed to a ctx-aware handler
- `ttl_ms::Union{Int,Nothing}`: Requested retention duration (clamped to the
  store's maximum); `nothing` for the server default
- `status_message::Union{String,Nothing}`: Optional initial `statusMessage`

# Returns
- `Bool`: `true` when the call is (now) task-detached
"""
function task_detach(ctx::RequestContext;
                     ttl_ms::Union{Int,Nothing}=nothing,
                     status_message::Union{String,Nothing}=nothing)::Bool
    st = ctx.detach
    st === nothing && return false
    lock(st.lock) do
        st.record !== nothing && return true
        st.closed && return false
        record = create_task!(ctx.server.tasks, "tools/call";
                              requested_ttl_ms = ttl_ms,
                              principal = task_principal(ctx),
                              era = :ext,
                              status_message = status_message)
        # Snapshot under the store lock so the CreateTaskResult reports creation-time
        # state; the task is durably registered BEFORE the response is delivered, so
        # a tasks/get issued the moment the client sees the taskId always resolves
        wire = lock(ctx.server.tasks.lock) do
            ext_task_wire(record)
        end
        wire["resultType"] = "task"
        response = modern_result_envelope(
            JSONRPCResponse(id = ctx.request_id, result = wire), ctx.server)
        try
            st.transport === nothing ||
                deliver_response(st.transport, st.route, serialize_message(response))
        catch e
            # The task exists and runs regardless; a vanished client re-finds
            # nothing (never learned the taskId) and the record expires via ttl
            @debug "Failed to deliver CreateTaskResult" error=e
        end
        st.record = record
        ctx.task = record  # enables task_cancelled(ctx) for the running handler
        true
    end
end

"""
    spawn_detachable_tool_call!(ctx::RequestContext, tool::MCPTool,
                                args::AbstractDict) -> HandlerResult

Run a task-capable modern-era `tools/call` off the serial server loop: capture the
request's response route, spawn the handler on a background Julia task, and defer.
The handler decides the response shape by what it does first:

- returns without detaching → ordinary synchronous result (the immediate-result
  shortcut), delivered on the captured route
- returns `InputRequired` without detaching → the MRTR round (capability check,
  `input_required` envelope) — this is what lets MRTR exchanges resolve BEFORE
  task creation, per the SEP-2663 composition rule
- calls `task_detach(ctx)` → the `CreateTaskResult` was already delivered; the
  eventual outcome is recorded into the task (a `CallToolResult` completes it,
  a thrown error fails it with the JSON-RPC error inlined)
"""
function spawn_detachable_tool_call!(ctx::RequestContext, tool::MCPTool,
                                     args::AbstractDict)::HandlerResult
    transport = ctx.server.transport
    route = transport === nothing ? nothing : capture_response_route(transport)
    st = TaskDetachState(transport, route)
    ctx.detach = st
    server = ctx.server
    request_id = ctx.request_id
    client_caps = ctx.client_capabilities
    params_digest = ctx.params_digest
    principal = mrtr_principal(ctx.authenticated_user)
    Threads.@spawn begin
        outcome = try
            execute_tool_call(tool, args, ctx)
        catch e
            # execute_tool_call catches handler errors itself; this guards the glue
            ErrorInfo(code = ErrorCodes.INTERNAL_ERROR, message = "Tool execution failed: $(e)")
        end
        record = lock(st.lock) do
            st.closed = true
            st.record
        end
        if record === nothing
            # Never detached: this call's response is the ordinary synchronous one,
            # built exactly as the in-loop modern serve path would
            response = if outcome isa ErrorInfo
                JSONRPCError(
                    id = request_id,
                    error = ErrorInfo(
                        code = modernize_error_code(outcome.code),
                        message = outcome.message,
                        data = outcome.data
                    )
                )
            elseif outcome isa InputRequired
                modern_input_required_response(server, outcome, request_id,
                                               "tools/call", client_caps,
                                               params_digest, principal)
            else
                modern_result_envelope(
                    JSONRPCResponse(id = request_id, result = outcome), server)
            end
            try
                transport === nothing ||
                    deliver_response(transport, route, serialize_message(response))
            catch e
                @debug "Failed to deliver deferred tools/call response" error=e
            end
        else
            # Detached: the CreateTaskResult already answered the request; the
            # outcome is the task's terminal state. InputRequired AFTER detachment
            # has no wire shape (mid-task input is the tasks/update flow) — fail
            # the task rather than store an unrepresentable outcome.
            outcome isa InputRequired && (outcome = ErrorInfo(
                code = ErrorCodes.INVALID_REQUEST,
                message = "input_required is not supported after task detachment"))
            finish_task!(server.tasks, record, outcome)
        end
    end
    HandlerResult(deferred = true)
end

"""
    handle_ext_get_task(ctx::RequestContext, params::GetTaskParams) -> HandlerResult

Handle a modern-era `tasks/get` poll (tasks extension): return the DetailedTask for
the task's current status, with the terminal `result`/`error` inlined. Gated on the
extension declaration (-32021); an unknown, expired, cross-principal, or legacy-era
`taskId` is -32602.
"""
function handle_ext_get_task(ctx::RequestContext, params::GetTaskParams)::HandlerResult
    tasks_extension_declared(ctx.client_capabilities) ||
        return HandlerResult(error = tasks_extension_required_error())
    store = ctx.server.tasks
    record = get_task(store, params.taskId, task_principal(ctx); era = :ext)
    record === nothing && return task_not_found_result()
    wire = lock(store.lock) do
        ext_task_wire(record; detailed = true)
    end
    HandlerResult(response = JSONRPCResponse(id = ctx.request_id, result = wire))
end

"""
    handle_ext_update_task(ctx::RequestContext, params::UpdateTaskParams) -> HandlerResult

Handle a modern-era `tasks/update` (tasks extension): deliver the client's
`inputResponses` to a task waiting for input, acknowledging with an empty result.
Responses keyed to requests that are not currently outstanding are ignored per
spec — which today is every key, since no execution path parks a task in
`input_required` yet (that flow arrives with mid-task input support). Gated on the
extension declaration (-32021); an unknown `taskId` is -32602.
"""
function handle_ext_update_task(ctx::RequestContext, params::UpdateTaskParams)::HandlerResult
    tasks_extension_declared(ctx.client_capabilities) ||
        return HandlerResult(error = tasks_extension_required_error())
    store = ctx.server.tasks
    record = get_task(store, params.taskId, task_principal(ctx); era = :ext)
    record === nothing && return task_not_found_result()
    HandlerResult(response = JSONRPCResponse(
        id = ctx.request_id, result = LittleDict{String,Any}()))
end

"""
    handle_ext_cancel_task(ctx::RequestContext, params::CancelTaskParams) -> HandlerResult

Handle a modern-era `tasks/cancel` (tasks extension): signal cancellation intent and
acknowledge with an empty result. Cancellation is cooperative and eventually
consistent — a running handler observes it via `task_cancelled(ctx)`, and the ack
is idempotent: cancelling an already-terminal task acks identically (-32602 is
reserved for unknown `taskId`s, a deliberate delta from the legacy era's
terminal-cancel rejection). Gated on the extension declaration (-32021).
"""
function handle_ext_cancel_task(ctx::RequestContext, params::CancelTaskParams)::HandlerResult
    tasks_extension_declared(ctx.client_capabilities) ||
        return HandlerResult(error = tasks_extension_required_error())
    store = ctx.server.tasks
    record = get_task(store, params.taskId, task_principal(ctx); era = :ext)
    record === nothing && return task_not_found_result()
    cancel_task!(store, record)  # false = already terminal; the ack is identical
    HandlerResult(response = JSONRPCResponse(
        id = ctx.request_id, result = LittleDict{String,Any}()))
end

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
    ext_task_principal(ctx::RequestContext) -> Union{String,Nothing}

The authorization principal extension tasks are bound to. Unlike the legacy
`task_principal` (subject only), this binds provider AND subject via the
canonical collision-free [`principal_identity`](@ref) — two identity providers
can issue the same `sub`, and a token from the wrong provider must not resolve
another caller's task. `nothing` when auth is not enabled (single-user
transports). Shares its encoding with the MRTR `requestState` principal, so the
composition flow (MRTR round, then task creation) is bound to one identity
end-to-end.
"""
ext_task_principal(ctx::RequestContext) =
    ctx.authenticated_user === nothing ? nothing : principal_identity(ctx.authenticated_user)

"""
    ext_task_authorized(ctx::RequestContext, record::TaskRecord) -> Bool

Re-authorize a task-related request against the task's recorded requirements
(SEP-2663: authorization checks on EVERY task request, not only at creation): when
the request is authenticated, the current token must carry every scope the
originating tool required. A failure is reported as task-not-found by the caller,
indistinguishable from an unknown id.
"""
function ext_task_authorized(ctx::RequestContext, record::TaskRecord)::Bool
    ctx.authenticated_user === nothing && return true
    isempty(record.required_scopes) && return true
    isempty(setdiff(record.required_scopes, ctx.authenticated_user.scopes))
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
            # Point-in-time snapshot of ALL outstanding requests (the spec has the
            # server re-include not-yet-answered entries on every poll; clients
            # deduplicate by key)
            reqs = LittleDict{String,Any}()
            for (key, pending) in record.pending_inputs
                entry = LittleDict{String,Any}("method" => pending.method)
                pending.params === nothing || (entry["params"] = pending.params)
                reqs[key] = entry
            end
            d["inputRequests"] = reqs
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
                              principal = ext_task_principal(ctx),
                              era = :ext,
                              status_message = status_message,
                              required_scopes = st.required_scopes)
        # Publish the record the moment it durably exists, BEFORE anything fallible
        # below: were wire building or delivery to throw, the spawn wrapper must
        # still see the record (to terminalize it and answer the owed response) —
        # a created-but-unpublished record would sit in "working" forever, since
        # the sweep only removes terminal records
        st.record = record
        ctx.task = record  # enables task_cancelled(ctx) for the running handler
        # Snapshot under the store lock so the CreateTaskResult reports creation-time
        # state; the task is durably registered BEFORE the response is delivered, so
        # a tasks/get issued the moment the client sees the taskId always resolves
        wire = lock(ctx.server.tasks.lock) do
            ext_task_wire(record)
        end
        wire["resultType"] = "task"
        payload = serialize_message(modern_result_envelope(
            JSONRPCResponse(id = ctx.request_id, result = wire), ctx.server))
        # The response is about to go out: end the request's log scope first so no
        # notifications/message can trail it — and none may follow for the task's
        # background phase either (the spec forbids them on tasks)
        try
            close_request_log_scope!()
        catch
        end
        try
            deliver_response(st.transport, st.route, payload)
        catch e
            # The task exists and runs regardless; a vanished client re-finds
            # nothing (never learned the taskId) and the record expires via ttl
            try  # best-effort diagnostic: a throwing logger must not escape here
                @debug "Failed to deliver CreateTaskResult" error=e
            catch
            end
        end
        # Delivery was attempted (success, or a dead client that cannot receive
        # anything further either way): the request is no longer owed a response
        st.create_delivered = true
        true
    end
end

"""
    TaskCancelledException()

Thrown by [`task_await_input`](@ref) when the task reaches a terminal state while
the handler is waiting (or had already reached one when it asked) — cancelled by
the client via `tasks/cancel`, or failed by the server because its ttl elapsed
while parked on client input. Handlers that need to distinguish the two can check
`task_cancelled(ctx)`, which is `true` only for a client cancellation. Catch it
for cleanup; otherwise it unwinds the handler, whose discarded outcome never
overwrites the terminal status.
"""
struct TaskCancelledException <: Exception end

Base.showerror(io::IO, ::TaskCancelledException) =
    print(io, "TaskCancelledException: the task was cancelled or expired while waiting for client input")

"""
    task_await_input(ctx, request::InputRequest) -> Any
    task_await_input(ctx, requests::AbstractVector{InputRequest}) -> Vector{Any}

Ask the client for input MID-TASK and block the handler until it answers (tasks
extension, SEP-2663). Callable from a handler that has already detached via
[`task_detach`](@ref): the request(s) are registered under server-minted keys
(unique over the task's lifetime), the task's status flips to `input_required`,
and `tasks/get` surfaces the outstanding requests in `inputRequests`. The client
answers with `tasks/update` `inputResponses`; each response value is returned to
the waiting handler (the vector form returns responses in request order, and only
once ALL of them have arrived — a partial `tasks/update` is accepted, the task
simply stays `input_required` until the rest arrive). Once nothing is pending the
status returns to `working`.

Build requests with [`elicit_request`](@ref), [`sampling_request`](@ref), or
[`roots_request`](@ref) — the same constructors the MRTR flow uses. A server MUST
NOT send input requests the creating request's client capabilities did not
declare, so an undeclared capability throws (failing the task).

Throws [`TaskCancelledException`](@ref) when the task goes terminal while (or
before) waiting. An unanswered request blocks until the client answers or
cancels, or until the task's ttl elapses — a per-wait deadline timer fails an
expired task still parked on client input and unwinds its waiters, so abandoned
tasks cannot pin handler state forever. To distinguish expiry from a client
cancel, check `task_cancelled(ctx)` — `true` only for the latter.

The registered requests are frozen: each request's params are normalized into
an owned plain-JSON snapshot at registration, so a key's content can never
change across polls (the spec's key-stability rule) and the capability check
binds to exactly what will be surfaced. Params must therefore be plain JSON
data — nested dicts/vectors/tuples/sets of strings, numbers, booleans, and
`nothing` (what `elicit_request` and friends naturally produce); anything else
is rejected with an `ArgumentError`.

Before detachment there is no `inputRequests` surface: a handler that needs input
to DECIDE (e.g. whether to proceed at all) returns [`InputRequired`](@ref) for
the MRTR round on the original request instead.

# Arguments
- `ctx`: The request context passed to a ctx-aware handler
- `request`/`requests`: The input request(s) to surface to the client

# Returns
- The client's response value (single form), or a `Vector{Any}` of response
  values in request order (vector form)
"""
task_await_input(ctx::RequestContext, request::InputRequest) =
    first(task_await_input(ctx, InputRequest[request]))

# Closed-world freeze of a JSON value: only plain JSON data is accepted, and
# the result is an OWNED value sharing no mutable state with the input —
# containers rebuilt, strings snapshotted, big numbers duplicated, everything
# else rejected. Deliberately a whitelist rather than deepcopy: Base documents
# deepcopy passing some mutable types through by identity (e.g. Regex), and
# custom types can specialize deepcopy_internal the same way — a closed set has
# no such loophole. The scalar branches are equally closed: EXACT concrete
# numeric types only (an accepted abstract Real could serialize differently on
# every poll — a Ptr-backed isbits subtype demonstrates it), floats must be
# finite (JSON3 rejects NaN/Inf, which would otherwise register a request no
# tasks/get can ever serialize), and non-String strings are snapshotted through
# OUR buffer (a custom subtype's String()/string() can return a byte-aliased
# String). Numeric fidelity is exact (a JSON round-trip would reparse an
# integer beyond Int64, e.g. 10^30 in a schema `const`, as a lossy Float64).
function _frozen_json(x)
    if x === nothing || x === missing || x isa Bool
        x
    elseif x isa String
        x  # Julia's concrete String is immutable; identity is safe
    elseif x isa Union{AbstractString,Symbol,AbstractChar}
        sprint(print, x)  # one print into fresh storage fixes the value now
    elseif x isa Union{Int8,Int16,Int32,Int64,Int128,UInt8,UInt16,UInt32,UInt64,UInt128}
        x
    elseif x isa Union{Float16,Float32,Float64,BigInt,BigFloat}
        (x isa AbstractFloat && !isfinite(x)) && throw(ArgumentError(
            "input request params must be finite numbers (JSON has no NaN/Inf); got $x"))
        # BigInt/BigFloat have mutable GMP/MPFR backing; Base owns this deepcopy
        x isa Union{BigInt,BigFloat} ? deepcopy(x) : x
    elseif x isa Union{AbstractDict,NamedTuple}
        out = LittleDict{String,Any}()
        for (k, v) in pairs(x)
            out[_frozen_json_key(k)] = _frozen_json(v)
        end
        out
    elseif x isa Union{AbstractVector,Tuple,AbstractSet}
        Any[_frozen_json(v) for v in x]
    else
        throw(ArgumentError(
            "input request params must be plain JSON data (dicts, vectors, " *
            "strings, numbers, booleans); got $(typeof(x))"))
    end
end

_frozen_json_key(k) = k isa String ? k : sprint(print, k)

# An owned snapshot of an input request: a caller-held reference to mutable
# params must not be able to change what a registered key describes on later
# polls (spec key-stability), nor to escalate a request past the capability
# check after it ran (e.g. adding sampling `tools` post-validation). The
# closed-world freeze IS the validation: its output is plain owned JSON data,
# so it serializes cleanly on every later tasks/get — and a rejected value
# fails here with a clear error instead of a broken poll later.
function _frozen_input_request(r::InputRequest)::InputRequest
    r.params === nothing && return r
    InputRequest(r.method, _frozen_json(r.params))
end

function task_await_input(ctx::RequestContext,
                          requests::AbstractVector{InputRequest})::Vector{Any}
    record = ctx.task
    (record === nothing || record.era !== :ext) && throw(ArgumentError(
        "task_await_input requires a detached extension-era task — call task_detach(ctx) first " *
        "(before detachment, return InputRequired for the MRTR round on the original request)"))
    isempty(requests) && return Any[]
    store = ctx.server.tasks
    # Terminal check BEFORE validation: an already-cancelled task must surface as
    # TaskCancelledException whatever the handler asks for next, so cancellation-
    # specific cleanup paths are never skipped for a validation error
    lock(store.lock) do
        task_is_terminal(record) && throw(TaskCancelledException())
    end
    # Freeze first, then validate THE SNAPSHOT — the checked params and the
    # surfaced params must be the same object
    frozen = InputRequest[_frozen_input_request(r) for r in requests]
    for r in frozen
        capability_satisfied(ctx.client_capabilities, r) || throw(ArgumentError(
            "client did not declare the capability required for $(r.method) input requests"))
    end
    entries = PendingTaskInput[]
    lock(store.lock) do
        # Recheck: cancellation may have landed during freezing/validation
        task_is_terminal(record) && throw(TaskCancelledException())
        for r in frozen
            record.input_key_counter += 1
            pending = PendingTaskInput(r.method, r.params, Channel{Any}(1))
            record.pending_inputs["input-$(record.input_key_counter)"] = pending
            push!(entries, pending)
        end
        if record.status == "working"
            record.status = "input_required"
            record.status_message = "Waiting for client input."
        end
        record.last_updated_at = Dates.now(Dates.UTC)
        # Fired even for a second parallel registration (status already
        # input_required): the observable inputRequests snapshot changed
        _fire_status_change(store, record)
    end
    # Clock-driven ttl deadline: the store sweep only runs on LATER store
    # activity, so without this a parked task whose client vanished would pin
    # its spawned handler, channels, and params forever. The timer fires the
    # same expiry transition the sweep applies (whichever runs first wins; both
    # no-op on a task no longer parked), closing the channels below. It RETRIES
    # on an interval rather than firing once: libuv timers run on the monotonic
    # clock while task_is_expired compares millisecond wall-clock DateTimes with
    # strict `>`, so a single fire can land at-or-before the boundary, no-op,
    # and never come back (observed as a CI-only hang). The timer stops itself
    # once the task is terminal, and the `finally` below covers delivery.
    deadline = nothing
    if record.ttl_ms !== nothing
        remaining_ms = Dates.value(record.created_at + Millisecond(record.ttl_ms) -
                                   Dates.now(Dates.UTC))
        deadline = Timer(max(remaining_ms, 0) / 1000; interval = 0.25) do t
            try
                lock(store.lock) do
                    expire_parked_input!(store, record, Dates.now(Dates.UTC)) ||
                        task_is_terminal(record)
                end && Base.close(t)
            catch
                # Keep the timer alive: a transient failure must not strand the waiter
            end
        end
    end
    # Block OUTSIDE the store lock: delivery (tasks/update) and terminal
    # transitions all need it. A closed channel means the task went terminal
    # (cancel or ttl expiry) without this request ever being answered.
    responses = Any[]
    try
        for pending in entries
            value = try
                take!(pending.channel)
            catch
                throw(TaskCancelledException())
            end
            push!(responses, value)
        end
    finally
        # Base-qualified (the package's close(::Transport) shadows Base.close)
        deadline === nothing || Base.close(deadline)
    end
    responses
end

"""
    install_task_notifications!(server::Server) -> Nothing

Wire the tasks extension's `notifications/tasks` status updates: install the
store's status-change hook so every extension-era transition (parking on input,
resuming, completing, failing, cancelling, expiring) broadcasts the task's
complete DetailedTask — identical to what `tasks/get` would return at that
moment — to the `subscriptions/listen` streams that subscribed to the task's id.
Installed by `mcp_server`; the hook runs under the store lock (which
`ext_task_wire` requires), safe against the subscription registry lock (the
ordering store → registry → transport channels is never reversed).
"""
function install_task_notifications!(server::Server)
    server.tasks.on_status_change[] = record -> begin
        record.era === :ext || return nothing
        wire = ext_task_wire(record; detailed = true)
        broadcast_subscription_notification(server, "notifications/tasks";
                                            params = wire,
                                            task_id = record.task_id)
        nothing
    end
    nothing
end

# End the current request's ModernRequestLogger scope from the worker task (the
# spawned handler inherits the logstate, so current_logger() IS the request scope
# when one was installed). Idempotent; a no-op when no scope is in effect.
function close_request_log_scope!()
    lg = Logging.current_logger()
    lg isa ModernRequestLogger && close_scope!(lg)
    nothing
end

"""
    safe_error_message(prefix::String, e) -> String

Format an exception for an error message WITHOUT trusting its `show`/`showerror`
methods: an exception whose display itself throws must not escape the error
path it is being reported on (it would defeat every catch that interpolates
`\$(e)` and, on the task-worker path, leave a delivered task non-terminal
forever). Falls back to the exception's type name, then to a static string.
"""
function safe_error_message(prefix::String, e)::String
    detail = try
        sprint(showerror, e)
    catch
        try
            string(typeof(e))
        catch
            "unrenderable exception"
        end
    end
    string(prefix, ": ", detail)
end

"""
    spawn_detachable_tool_call!(ctx::RequestContext, tool::MCPTool,
                                args::AbstractDict,
                                tool_scopes::Vector{String}) -> HandlerResult

Run a task-capable modern-era `tools/call` off the serial server loop: capture the
request's response route, spawn the handler on a background Julia task, and defer.
`tool_scopes` is the caller's snapshot of the tool's `required_scopes` — the exact
set this request was authorized against, recorded onto a minted task for
per-request re-authorization. The handler decides the response shape by what it
does first:

- returns without detaching → ordinary synchronous result (the immediate-result
  shortcut), delivered on the captured route
- returns `InputRequired` without detaching → the MRTR round (capability check,
  `input_required` envelope) — this is what lets MRTR exchanges resolve BEFORE
  task creation, per the SEP-2663 composition rule
- calls `task_detach(ctx)` → the `CreateTaskResult` was already delivered; the
  eventual outcome is recorded into the task (a `CallToolResult` completes it,
  a thrown error fails it with the JSON-RPC error inlined)

The worker guarantees exactly one outcome on every path: any throw between the
handler's return and the response delivery — including one raised by a
diagnostic logger — lands in a last-resort catch that answers -32603 (or fails
the already-created task).
"""
function spawn_detachable_tool_call!(ctx::RequestContext, tool::MCPTool,
                                     args::AbstractDict,
                                     tool_scopes::Vector{String})::HandlerResult
    transport = ctx.server.transport
    route = capture_response_route(transport)
    st = TaskDetachState(transport, route, tool_scopes)
    ctx.detach = st
    server = ctx.server
    request_id = ctx.request_id
    client_caps = ctx.client_capabilities
    params_digest = ctx.params_digest
    principal = mrtr_principal(ctx.authenticated_user)
    Threads.@spawn begin
        record = nothing
        create_delivered = false
        delivered = false
        try
            outcome = try
                execute_tool_call(tool, args, ctx)
            catch e
                # execute_tool_call catches handler errors itself; this guards the
                # glue — including an exception whose OWN display throws, which
                # escapes execute_tool_call's catch through its message interpolation
                ErrorInfo(code = ErrorCodes.INTERNAL_ERROR,
                          message = safe_error_message("Tool execution failed", e))
            end
            record, create_delivered = lock(st.lock) do
                st.closed = true
                (st.record, st.create_delivered)
            end
            if record === nothing
                # Never detached: this call's response is the ordinary synchronous
                # one, built exactly as the in-loop modern serve path would. The
                # response MUST reach the client even when building it throws (a
                # non-serializable result, a requestState the state cannot encode):
                # fall back to the same -32603 the in-loop path would produce.
                payload = try
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
                    serialize_message(response)
                catch e
                    try  # the diagnostic is best-effort — a throwing logger must not eat the fallback
                        @debug "Failed to build deferred tools/call response" error=e
                    catch
                    end
                    serialize_message(JSONRPCError(
                        id = request_id,
                        error = ErrorInfo(
                            code = ErrorCodes.INTERNAL_ERROR,
                            message = safe_error_message("Internal error", e)
                        )
                    ))
                end
                # Scope ends before the response goes out (no trailing records)
                close_request_log_scope!()
                delivered = true
                try
                    deliver_response(transport, route, payload)
                catch
                    # Client likely disconnected; the route is gone either way
                end
            else
                # Detached: the outcome is the task's terminal state. InputRequired
                # AFTER detachment has no wire shape (mid-task input is the
                # tasks/update flow) — fail the task rather than store an
                # unrepresentable outcome.
                outcome isa InputRequired && (outcome = ErrorInfo(
                    code = ErrorCodes.INVALID_REQUEST,
                    message = "input_required is not supported after task detachment"))
                finish_task!(server.tasks, record, outcome)
                if !create_delivered
                    # The handoff died between task creation and CreateTaskResult
                    # delivery: the request is still owed a response (the task is
                    # unreachable — the client never learned its id)
                    delivered = true
                    try
                        deliver_response(transport, route, serialize_message(JSONRPCError(
                            id = request_id,
                            error = ErrorInfo(code = ErrorCodes.INTERNAL_ERROR,
                                              message = "Internal error: task handoff failed"))))
                    catch
                    end
                end
            end
        catch e
            # Last resort: the request must never end with neither a response nor
            # a terminal task, whatever threw above. Re-snapshot the detach state
            # under its lock — a throw can reach here BEFORE the main-path
            # snapshot ran (e.g. a display-throwing exception escaping every
            # formatting site), in which case the locals still read "no record"
            # for a task that was in fact created and delivered.
            msg = safe_error_message("Internal error", e)
            rec, cd = lock(st.lock) do
                st.closed = true
                (st.record, st.create_delivered)
            end
            if rec !== nothing
                try
                    finish_task!(server.tasks, rec,
                                 ErrorInfo(code = ErrorCodes.INTERNAL_ERROR, message = msg))
                catch
                end
            end
            if !delivered && (rec === nothing || !cd)
                try
                    deliver_response(transport, route, serialize_message(JSONRPCError(
                        id = request_id,
                        error = ErrorInfo(code = ErrorCodes.INTERNAL_ERROR, message = msg))))
                catch
                end
            end
        finally
            # Covers every remaining exit: a throw above, or a handler that never
            # triggered either boundary close. Idempotent, and must not throw out
            # of the finally.
            try
                close_request_log_scope!()
            catch
            end
        end
    end
    # The request now belongs to the worker: the loop must not close the request's
    # log scope on its way out (the worker does, at its response boundary). Set
    # LAST so no throw between here and the deferred return can leave the flag
    # armed for a request that was actually answered synchronously.
    task_local_storage(:mcp_detached_call, true)
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
    record = get_task(store, params.taskId, ext_task_principal(ctx); era = :ext)
    (record === nothing || !ext_task_authorized(ctx, record)) &&
        return task_not_found_result()
    wire = lock(store.lock) do
        ext_task_wire(record; detailed = true)
    end
    HandlerResult(response = JSONRPCResponse(id = ctx.request_id, result = wire))
end

"""
    handle_ext_update_task(ctx::RequestContext, params::UpdateTaskParams) -> HandlerResult

Handle a modern-era `tasks/update` (tasks extension): deliver the client's
`inputResponses` to the task's outstanding input requests, acknowledging with an
empty result. Responses keyed to requests that are not currently outstanding —
never issued, already answered, or superseded — are ignored per spec, and a
partial set (a strict subset of the outstanding keys) is accepted: answered keys
are removed and the task stays `input_required` until the rest arrive; once
nothing is pending the status returns to `working`. The ack is eventually
consistent — delivery happens before the ack here, but the resumed handler runs
concurrently, so the observable status is whatever `tasks/get` sees next. Gated
on the extension declaration (-32021); an unknown `taskId` is -32602.
"""
function handle_ext_update_task(ctx::RequestContext, params::UpdateTaskParams)::HandlerResult
    tasks_extension_declared(ctx.client_capabilities) ||
        return HandlerResult(error = tasks_extension_required_error())
    store = ctx.server.tasks
    record = get_task(store, params.taskId, ext_task_principal(ctx); era = :ext)
    (record === nothing || !ext_task_authorized(ctx, record)) &&
        return task_not_found_result()
    lock(store.lock) do
        # A terminal task has no outstanding requests (they are drained on the
        # terminal transition), so every key is not-outstanding: acked, ignored
        delivered = false
        for (key, value) in params.inputResponses
            pending = get(record.pending_inputs, key, nothing)
            pending === nothing && continue
            delete!(record.pending_inputs, key)
            # Size-1 buffered channel, exactly one put per key (the delete above is
            # in the same critical section), so this never blocks; the waiter's
            # take! resumes once the lock is released
            put!(pending.channel, value)
            delivered = true
        end
        if delivered
            if isempty(record.pending_inputs) && record.status == "input_required"
                record.status = "working"
                record.status_message = "The operation is now in progress."
            end
            record.last_updated_at = Dates.now(Dates.UTC)
            _fire_status_change(store, record)
        end
    end
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
    record = get_task(store, params.taskId, ext_task_principal(ctx); era = :ext)
    (record === nothing || !ext_task_authorized(ctx, record)) &&
        return task_not_found_result()
    cancel_task!(store, record)  # false = already terminal; the ack is identical
    HandlerResult(response = JSONRPCResponse(
        id = ctx.request_id, result = LittleDict{String,Any}()))
end

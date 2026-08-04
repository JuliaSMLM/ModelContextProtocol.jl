# src/features/tasks.jl
#
# Server-side task store for MCP Tasks (SEP-1686, protocol 2025-11-25, experimental).
# A task-augmented request returns a CreateTaskResult immediately while the underlying
# work runs in a background Julia task; requestors poll tasks/get and fetch the final
# payload via tasks/result. This file holds the task records and store operations;
# the protocol handlers live in protocol/handlers.jl.

using UUIDs
using Random: RandomDevice

# Server-chosen task defaults (milliseconds). The requested ttl is clamped to
# TASK_MAX_TTL_MS; tasks created without a requested ttl get TASK_DEFAULT_TTL_MS.
const TASK_DEFAULT_TTL_MS = 300_000        # 5 minutes
const TASK_MAX_TTL_MS = 3_600_000          # 1 hour
const TASK_POLL_INTERVAL_MS = 1_000        # suggested client polling interval
const TASKS_PAGE_SIZE = 50                 # tasks/list page size

const TASK_TERMINAL_STATUSES = ("completed", "failed", "cancelled")

# _meta key associating messages with their originating task (spec-defined)
const RELATED_TASK_META_KEY = "io.modelcontextprotocol/related-task"

"""
    PendingTaskInput(method::String, params, channel::Channel{Any})

One outstanding mid-task input request on an extension-era task (SEP-2663): the
request the client sees under the task's `inputRequests` (as `{method, params?}`
on `tasks/get`), paired with the channel the blocked `task_await_input` waiter
takes the client's `tasks/update` response from. The channel is buffered (size 1)
and receives exactly one value — the key is removed from the pending map in the
same critical section that delivers, so a key can never be answered twice.

# Fields
- `method::String`: The input request's method (e.g. `elicitation/create`)
- `params::Any`: The input request's params (a Dict, or `nothing` for none)
- `channel::Channel{Any}`: Delivery channel to the blocked handler; closed (never
  fed) when the task is cancelled, unwinding the waiter
"""
struct PendingTaskInput
    method::String
    params::Any
    channel::Channel{Any}
end

"""
    TaskRecord

Mutable record of one server-side task (a task-augmented request execution).

# Fields
- `task_id::String`: Receiver-generated unique identifier (cryptographically random)
- `status::String`: One of "working", "input_required", "completed", "failed", "cancelled"
- `status_message::Union{String,Nothing}`: Optional human-readable status detail
- `created_at::DateTime`: UTC creation timestamp
- `last_updated_at::DateTime`: UTC timestamp of the last status change
- `ttl_ms::Union{Int,Nothing}`: Actual retention duration from creation; `nothing` = unlimited
- `poll_interval_ms::Union{Int,Nothing}`: Suggested client polling interval
- `principal::Union{String,Nothing}`: Authorization binding (authenticated subject), `nothing` when unauthenticated
- `method::String`: The originating request method (e.g. "tools/call")
- `era::Symbol`: `:legacy` for SEP-1686 experimental tasks (2025-11-25 sessions),
  `:ext` for the modern-era `io.modelcontextprotocol/tasks` extension (SEP-2663).
  The eras are wire-incompatible and never serve each other's records
- `required_scopes::Vector{String}`: The originating tool's `required_scopes`,
  re-checked on every extension-era task request (SEP-2663 requires authorization
  on each task-related request — a later token for the same subject but without
  the tool's scopes must not read the result). Empty when the tool declares none
- `result::Union{CallToolResult,Nothing}`: Final result when the underlying call succeeded (or failed via `isError`)
- `error::Union{ErrorInfo,Nothing}`: Final JSON-RPC error when the underlying call errored
- `done::Base.Event`: Set exactly once when the task reaches a terminal status
- `cancel_requested::Threads.Atomic{Bool}`: Set once tasks/cancel is accepted; atomic so
  handlers can poll it lock-free from worker threads via `task_cancelled(ctx)`
- `pending_inputs::LittleDict{String,PendingTaskInput}`: Outstanding mid-task input
  requests keyed by server-minted id (extension era only; insertion-ordered, so
  `inputRequests` serializes in issue order). Non-empty exactly while the task is
  `input_required`
- `input_key_counter::Int`: Monotone counter minting `pending_inputs` keys — a key is
  never reused over the task's lifetime, even after its request is answered (SEP-2663
  key-uniqueness rule)

All mutation goes through the owning `TaskStore` under its lock.
"""
mutable struct TaskRecord
    task_id::String
    status::String
    status_message::Union{String,Nothing}
    created_at::DateTime
    last_updated_at::DateTime
    ttl_ms::Union{Int,Nothing}
    poll_interval_ms::Union{Int,Nothing}
    principal::Union{String,Nothing}
    method::String
    era::Symbol
    required_scopes::Vector{String}
    result::Union{CallToolResult,Nothing}
    error::Union{ErrorInfo,Nothing}
    done::Base.Event
    cancel_requested::Threads.Atomic{Bool}
    pending_inputs::LittleDict{String,PendingTaskInput}
    input_key_counter::Int
end

"""
    TaskStore(; default_ttl_ms=TASK_DEFAULT_TTL_MS, max_ttl_ms=TASK_MAX_TTL_MS,
              poll_interval_ms=TASK_POLL_INTERVAL_MS, page_size=TASKS_PAGE_SIZE)

Thread-safe registry of server-side tasks.

# Fields
- `lock::ReentrantLock`: Guards all record access and mutation
- `tasks::Dict{String,TaskRecord}`: Records by task id
- `default_ttl_ms::Int`: ttl applied when the requestor does not ask for one
- `max_ttl_ms::Int`: Upper bound applied to requested ttls
- `poll_interval_ms::Int`: Suggested polling interval included in task responses
- `page_size::Int`: Page size for tasks/list cursor pagination
- `on_status_change::Base.RefValue{Any}`: Optional hook `record -> Nothing` fired
  after every status transition, while the store lock is held (see
  `_fire_status_change`); installed for the tasks extension's
  `notifications/tasks`. `nothing` disables it
- `notification_seq::Base.RefValue{Int}`: Monotone sequence stamped on every
  enqueued status notification (incremented only under the store lock).
  Subscriptions record the counter at registration and receive only
  later-stamped events, so a queued-but-undrained backlog never replays older
  states to a freshly registered stream
"""
Base.@kwdef struct TaskStore
    lock::ReentrantLock = ReentrantLock()
    tasks::Dict{String,TaskRecord} = Dict{String,TaskRecord}()
    default_ttl_ms::Int = TASK_DEFAULT_TTL_MS
    max_ttl_ms::Int = TASK_MAX_TTL_MS
    poll_interval_ms::Int = TASK_POLL_INTERVAL_MS
    page_size::Int = TASKS_PAGE_SIZE
    on_status_change::Base.RefValue{Any} = Ref{Any}(nothing)
    notification_seq::Base.RefValue{Int} = Ref(0)
end

"""
    _fire_status_change(store::TaskStore, record::TaskRecord) -> Nothing

Fire the store's status-change hook for a record whose status just changed.
Called at every transition site WHILE the store lock is held — the hook builds
the task's wire snapshot (which requires the lock) and ENQUEUES it (no
transport I/O happens under the store lock; a dedicated dispatcher task
broadcasts from the queue, see `install_task_notifications!`). A throwing hook
is swallowed: a notification must never break the transition that triggered it.
"""
function _fire_status_change(store::TaskStore, record::TaskRecord)
    hook = store.on_status_change[]
    hook === nothing && return nothing
    try
        hook(record)
    catch
    end
    nothing
end

"""
    task_is_terminal(record::TaskRecord) -> Bool

Return whether the task is in a terminal status ("completed", "failed", or "cancelled").
"""
task_is_terminal(record::TaskRecord) = record.status in TASK_TERMINAL_STATUSES

"""
    task_is_expired(record::TaskRecord, now_utc::DateTime) -> Bool

Return whether the task's ttl (counted from creation) has elapsed. Unlimited
(`ttl_ms === nothing`) tasks never expire.
"""
function task_is_expired(record::TaskRecord, now_utc::DateTime)
    record.ttl_ms === nothing && return false
    now_utc > record.created_at + Millisecond(record.ttl_ms)
end

"""
    create_task!(store::TaskStore, method::String;
                 requested_ttl_ms=nothing, principal=nothing, era=:legacy,
                 status_message=nothing) -> TaskRecord

Create a new task record in "working" status with a cryptographically random task id.
The requested ttl is clamped to the store's `max_ttl_ms`; when absent the store's
`default_ttl_ms` applies.
"""
function create_task!(store::TaskStore, method::String;
                      requested_ttl_ms::Union{Int,Nothing}=nothing,
                      principal::Union{String,Nothing}=nothing,
                      era::Symbol=:legacy,
                      status_message::Union{String,Nothing}=nothing,
                      required_scopes::Vector{String}=String[])::TaskRecord
    ttl = requested_ttl_ms === nothing ? store.default_ttl_ms :
          clamp(requested_ttl_ms, 0, store.max_ttl_ms)
    now_utc = Dates.now(Dates.UTC)
    record = TaskRecord(
        string(uuid4(RandomDevice())),
        "working",
        something(status_message, "The operation is now in progress."),
        now_utc,
        now_utc,
        ttl,
        store.poll_interval_ms,
        principal,
        method,
        era,
        copy(required_scopes),  # defensive: the record's set must never alias a caller's mutable vector
        nothing,
        nothing,
        Base.Event(),
        Threads.Atomic{Bool}(false),
        LittleDict{String,PendingTaskInput}(),
        0
    )
    lock(store.lock) do
        sweep_expired!(store)
        store.tasks[record.task_id] = record
    end
    record
end

"""
    expire_parked_input!(store::TaskStore, record::TaskRecord, now_utc::DateTime) -> Bool

Fail an extension-era task whose ttl elapsed while parked in `input_required`: a
task past its ttl that is waiting on CLIENT input is abandoned — the client the
server is waiting on can no longer use the result — so it is terminalized
(status `failed`, error inlined) and its pending inputs drained, unwinding the
blocked `task_await_input` waiter. A no-op (returning `false`) for any record
not in exactly that state, so the deadline timer and the store sweep can both
call it and whichever runs first wins. Caller must hold the store lock.
"""
function expire_parked_input!(store::TaskStore, record::TaskRecord,
                              now_utc::DateTime)::Bool
    (record.era === :ext && record.status == "input_required" &&
     task_is_expired(record, now_utc)) || return false
    record.error = ErrorInfo(
        code = ErrorCodes.INTERNAL_ERROR,
        message = "Task expired while awaiting client input")
    record.status = "failed"
    record.status_message = "The task expired while awaiting client input."
    record.last_updated_at = now_utc
    drain_pending_inputs!(record)
    notify(record.done)
    _fire_status_change(store, record)
    true
end

"""
    sweep_expired!(store::TaskStore) -> Nothing

Delete terminal task records whose ttl has elapsed, and fail expired
extension-era tasks still parked in `input_required` (see
[`expire_parked_input!`](@ref) — here as a backstop; the clock-driven per-wait
deadline timer in `task_await_input` is what guarantees the transition without
further store activity). Once failed, such a record is terminal AND expired, so
the next sweep deletes it — a post-expiry poll observes either the failed record
briefly (when its own sweep is the one that just terminalized it) or
task-not-found, timing-dependent; neither is promised. Other non-terminal
records are retained past their ttl
(the spec permits but does not require deleting those, and their background work
may still be running). Caller must hold `store.lock`.
"""
function sweep_expired!(store::TaskStore)
    now_utc = Dates.now(Dates.UTC)
    for (id, record) in store.tasks
        if task_is_terminal(record)
            task_is_expired(record, now_utc) && delete!(store.tasks, id)
        else
            expire_parked_input!(store, record, now_utc)
        end
    end
    nothing
end

"""
    get_task(store::TaskStore, task_id::String,
             principal::Union{String,Nothing}; era=:legacy) -> Union{TaskRecord,Nothing}

Look up a task by id, enforcing authorization-context binding: a record is only
returned when its stored principal matches the requestor's AND it belongs to the
requested era (legacy sessions cannot see extension tasks and vice versa — the wire
shapes are incompatible). A mismatch returns `nothing` (indistinguishable from
"not found", so task existence is not leaked).
"""
function get_task(store::TaskStore, task_id::String,
                  principal::Union{String,Nothing};
                  era::Symbol=:legacy)::Union{TaskRecord,Nothing}
    lock(store.lock) do
        sweep_expired!(store)
        record = get(store.tasks, task_id, nothing)
        record === nothing && return nothing
        record.principal == principal || return nothing
        record.era === era || return nothing
        record
    end
end

"""
    drain_pending_inputs!(record::TaskRecord) -> Nothing

Close and clear every outstanding mid-task input request on a task entering a
terminal status: a blocked `task_await_input` waiter observes its channel closing
and unwinds (there is nothing left that could ever feed it). Caller must hold the
store lock — which is also what makes close-vs-deliver atomic: `tasks/update`
delivers under the same lock, so a channel is either fed exactly once or closed,
never both.
"""
function drain_pending_inputs!(record::TaskRecord)
    for (_, pending) in record.pending_inputs
        # Base-qualified: the package's own close(::Transport) shadows Base.close here
        Base.close(pending.channel)
    end
    empty!(record.pending_inputs)
    nothing
end

"""
    finish_task!(store::TaskStore, record::TaskRecord,
                 outcome::Union{CallToolResult,ErrorInfo}) -> Bool

Transition a task to its terminal status from a completed execution. An `ErrorInfo`
(a JSON-RPC error) is always "failed". For a `CallToolResult` the eras diverge:
legacy (SEP-1686) maps `is_error` to "failed", while the extension era (SEP-2663)
requires "completed" for ANY result — "failed" is reserved for JSON-RPC errors, and
a tool-level `isError:true` result completes with the result inlined. Returns
`false` without mutating when the task is already terminal (e.g. cancelled while the
work was still running — cancelled tasks MUST stay cancelled, so the outcome is
discarded).
"""
function finish_task!(store::TaskStore, record::TaskRecord,
                      outcome::Union{CallToolResult,ErrorInfo})::Bool
    lock(store.lock) do
        task_is_terminal(record) && return false
        if outcome isa ErrorInfo
            record.error = outcome
            record.status = "failed"
            record.status_message = "Tool execution failed: $(outcome.message)"
        elseif record.era === :ext
            record.result = outcome
            record.status = "completed"
            record.status_message = outcome.is_error ?
                "The tool reported an error (isError)." :
                "The operation completed successfully."
        else
            record.result = outcome
            record.status = outcome.is_error ? "failed" : "completed"
            record.status_message = outcome.is_error ?
                "Tool execution failed (tool returned isError)." :
                "The operation completed successfully."
        end
        record.last_updated_at = Dates.now(Dates.UTC)
        # Defensive: a handler that returns while a stray child waiter is still
        # parked must not leave that waiter blocked forever
        drain_pending_inputs!(record)
        notify(record.done)
        _fire_status_change(store, record)
        true
    end
end

"""
    cancel_task!(store::TaskStore, record::TaskRecord) -> Bool

Transition a task to "cancelled". Returns `false` without mutating when the task is
already terminal (the handler maps that to a -32602 error per spec). Sets
`cancel_requested` so cooperative handlers can observe it via `task_cancelled(ctx)`,
and unblocks any `task_await_input` waiter by draining the pending input requests.
"""
function cancel_task!(store::TaskStore, record::TaskRecord)::Bool
    lock(store.lock) do
        task_is_terminal(record) && return false
        record.status = "cancelled"
        record.status_message = "The task was cancelled by request."
        record.cancel_requested[] = true
        record.last_updated_at = Dates.now(Dates.UTC)
        drain_pending_inputs!(record)
        notify(record.done)
        _fire_status_change(store, record)
        true
    end
end

"""
    list_tasks(store::TaskStore, principal::Union{String,Nothing},
               cursor::Union{String,Nothing}; era=:legacy)
        -> Tuple{Vector{TaskRecord},Union{String,Nothing}}

Return one page of the requestor's tasks (oldest first) and the next-page cursor, or
`nothing` for the cursor when no further pages exist. Only tasks bound to the same
principal AND era are visible (`tasks/list` exists only in the legacy era; extension
records must never leak into it — the extension deliberately has no list, so one
caller's task ids cannot be exposed to another). Throws `ArgumentError` for an
invalid cursor (mapped to -32602 by the handler).
"""
function list_tasks(store::TaskStore, principal::Union{String,Nothing},
                    cursor::Union{String,Nothing}; era::Symbol=:legacy)
    offset = cursor === nothing ? 0 : decode_task_cursor(cursor)
    lock(store.lock) do
        sweep_expired!(store)
        visible = sort!(
            [r for r in values(store.tasks) if r.principal == principal && r.era === era];
            by = r -> (r.created_at, r.task_id)
        )
        offset > length(visible) && throw(ArgumentError("Invalid cursor"))
        page = visible[(offset + 1):min(offset + store.page_size, end)]
        next = offset + store.page_size < length(visible) ?
               encode_task_cursor(offset + store.page_size) : nothing
        (page, next)
    end
end

encode_task_cursor(offset::Int) = base64encode("offset:$offset")

function decode_task_cursor(cursor::String)::Int
    decoded = try
        String(base64decode(cursor))
    catch
        throw(ArgumentError("Invalid cursor"))
    end
    m = match(r"^offset:(\d+)$", decoded)
    m === nothing && throw(ArgumentError("Invalid cursor"))
    parse(Int, m.captures[1])
end

"""
    task_wire(record::TaskRecord) -> LittleDict{String,Any}

Serialize a task record to the spec wire shape: `taskId`, `status`, optional
`statusMessage`, `createdAt`/`lastUpdatedAt` (ISO 8601 UTC), `ttl` (always present;
`null` for unlimited), and optional `pollInterval`.
"""
function task_wire(record::TaskRecord)
    d = LittleDict{String,Any}(
        "taskId" => record.task_id,
        "status" => record.status
    )
    record.status_message !== nothing && (d["statusMessage"] = record.status_message)
    d["createdAt"] = iso8601_utc(record.created_at)
    d["lastUpdatedAt"] = iso8601_utc(record.last_updated_at)
    d["ttl"] = record.ttl_ms
    record.poll_interval_ms !== nothing && (d["pollInterval"] = record.poll_interval_ms)
    d
end

"""
    iso8601_utc(dt::DateTime) -> String

Format a UTC `DateTime` as an ISO 8601 / RFC 3339 timestamp with a `Z` suffix.
"""
iso8601_utc(dt::DateTime) = Dates.format(dt, dateformat"yyyy-mm-dd\THH:MM:SS.sss\Z")

"""
    TaskDetachState(transport, route)

Per-call state for a detachable modern-era `tools/call` (tasks extension,
SEP-2663). Created when the call is spawned off-loop with its response route
captured; `task_detach(ctx)` uses it to mint the task and deliver the
`CreateTaskResult`, and the spawn wrapper uses it to learn whether the handler
detached. All access is under `lock`.

# Fields
- `lock::ReentrantLock`: Guards `record`/`closed` against the detach/finish race
- `transport::Any`: The serving transport at spawn time
- `route::Any`: The captured response route (see `capture_response_route`)
- `required_scopes::Vector{String}`: The tool's `required_scopes`, recorded onto the
  minted task for per-request re-authorization of the extension surface
- `record::Union{TaskRecord,Nothing}`: The minted task, published the moment it is
  durably created — BEFORE any fallible wire building or delivery, so a failure in
  between can never orphan a hidden non-terminal record
- `closed::Bool`: Set when the handler has returned — a late `task_detach` (e.g.
  from a stray child task) must fail rather than deliver a second response
- `create_delivered::Bool`: Set once the `CreateTaskResult` delivery was attempted;
  while false, the request is still owed a response (the spawn wrapper answers
  -32603 if the handoff died between task creation and delivery)
"""
mutable struct TaskDetachState
    lock::ReentrantLock
    transport::Any
    route::Any
    required_scopes::Vector{String}
    record::Union{TaskRecord,Nothing}
    closed::Bool
    create_delivered::Bool
end
TaskDetachState(transport, route, required_scopes::Vector{String}=String[]) =
    TaskDetachState(ReentrantLock(), transport, route, required_scopes, nothing, false, false)

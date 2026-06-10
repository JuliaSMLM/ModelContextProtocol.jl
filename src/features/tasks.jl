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
- `result::Union{CallToolResult,Nothing}`: Final result when the underlying call succeeded (or failed via `isError`)
- `error::Union{ErrorInfo,Nothing}`: Final JSON-RPC error when the underlying call errored
- `done::Base.Event`: Set exactly once when the task reaches a terminal status
- `cancel_requested::Bool`: True once tasks/cancel accepted; handlers may poll via `task_cancelled(ctx)`

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
    result::Union{CallToolResult,Nothing}
    error::Union{ErrorInfo,Nothing}
    done::Base.Event
    cancel_requested::Bool
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
"""
Base.@kwdef struct TaskStore
    lock::ReentrantLock = ReentrantLock()
    tasks::Dict{String,TaskRecord} = Dict{String,TaskRecord}()
    default_ttl_ms::Int = TASK_DEFAULT_TTL_MS
    max_ttl_ms::Int = TASK_MAX_TTL_MS
    poll_interval_ms::Int = TASK_POLL_INTERVAL_MS
    page_size::Int = TASKS_PAGE_SIZE
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
                 requested_ttl_ms=nothing, principal=nothing) -> TaskRecord

Create a new task record in "working" status with a cryptographically random task id.
The requested ttl is clamped to the store's `max_ttl_ms`; when absent the store's
`default_ttl_ms` applies.
"""
function create_task!(store::TaskStore, method::String;
                      requested_ttl_ms::Union{Int,Nothing}=nothing,
                      principal::Union{String,Nothing}=nothing)::TaskRecord
    ttl = requested_ttl_ms === nothing ? store.default_ttl_ms :
          clamp(requested_ttl_ms, 0, store.max_ttl_ms)
    now_utc = Dates.now(Dates.UTC)
    record = TaskRecord(
        string(uuid4(RandomDevice())),
        "working",
        "The operation is now in progress.",
        now_utc,
        now_utc,
        ttl,
        store.poll_interval_ms,
        principal,
        method,
        nothing,
        nothing,
        Base.Event(),
        false
    )
    lock(store.lock) do
        sweep_expired!(store)
        store.tasks[record.task_id] = record
    end
    record
end

"""
    sweep_expired!(store::TaskStore) -> Nothing

Delete terminal task records whose ttl has elapsed. Non-terminal records are retained
even past their ttl (the spec permits but does not require deleting those, and their
background work may still be running). Caller must hold `store.lock`.
"""
function sweep_expired!(store::TaskStore)
    now_utc = Dates.now(Dates.UTC)
    for (id, record) in store.tasks
        if task_is_terminal(record) && task_is_expired(record, now_utc)
            delete!(store.tasks, id)
        end
    end
    nothing
end

"""
    get_task(store::TaskStore, task_id::String,
             principal::Union{String,Nothing}) -> Union{TaskRecord,Nothing}

Look up a task by id, enforcing authorization-context binding: a record is only
returned when its stored principal matches the requestor's. A mismatch returns
`nothing` (indistinguishable from "not found", so task existence is not leaked).
"""
function get_task(store::TaskStore, task_id::String,
                  principal::Union{String,Nothing})::Union{TaskRecord,Nothing}
    lock(store.lock) do
        sweep_expired!(store)
        record = get(store.tasks, task_id, nothing)
        record === nothing && return nothing
        record.principal == principal || return nothing
        record
    end
end

"""
    finish_task!(store::TaskStore, record::TaskRecord,
                 outcome::Union{CallToolResult,ErrorInfo}) -> Bool

Transition a task to its terminal status from a completed execution: "failed" for an
`ErrorInfo` or a `CallToolResult` with `is_error`, otherwise "completed". Returns
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
        else
            record.result = outcome
            record.status = outcome.is_error ? "failed" : "completed"
            record.status_message = outcome.is_error ?
                "Tool execution failed (tool returned isError)." :
                "The operation completed successfully."
        end
        record.last_updated_at = Dates.now(Dates.UTC)
        notify(record.done)
        true
    end
end

"""
    cancel_task!(store::TaskStore, record::TaskRecord) -> Bool

Transition a task to "cancelled". Returns `false` without mutating when the task is
already terminal (the handler maps that to a -32602 error per spec). Sets
`cancel_requested` so cooperative handlers can observe it via `task_cancelled(ctx)`.
"""
function cancel_task!(store::TaskStore, record::TaskRecord)::Bool
    lock(store.lock) do
        task_is_terminal(record) && return false
        record.status = "cancelled"
        record.status_message = "The task was cancelled by request."
        record.cancel_requested = true
        record.last_updated_at = Dates.now(Dates.UTC)
        notify(record.done)
        true
    end
end

"""
    list_tasks(store::TaskStore, principal::Union{String,Nothing},
               cursor::Union{String,Nothing}) -> Tuple{Vector{TaskRecord},Union{String,Nothing}}

Return one page of the requestor's tasks (oldest first) and the next-page cursor, or
`nothing` for the cursor when no further pages exist. Only tasks bound to the same
principal are visible. Throws `ArgumentError` for an invalid cursor (mapped to -32602
by the handler).
"""
function list_tasks(store::TaskStore, principal::Union{String,Nothing},
                    cursor::Union{String,Nothing})
    offset = cursor === nothing ? 0 : decode_task_cursor(cursor)
    lock(store.lock) do
        sweep_expired!(store)
        visible = sort!(
            [r for r in values(store.tasks) if r.principal == principal];
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

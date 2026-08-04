# src/features/subscriptions.jl
# Registry types for modern-era (2026-07-28+) `subscriptions/listen` streams.
#
# A `subscriptions/listen` request opens a long-lived response stream carrying only
# the notification types the client opted into. The request never completes normally:
# its response route is captured (see `capture_response_route`) and notifications are
# pushed onto it as they occur, each tagged with the subscription's id. The handler
# and the broadcast API live in `src/protocol/subscriptions.jl` (they need
# `RequestContext`); this file holds the types `Server` embeds.

# A single filter may watch at most this many resource URIs: each URI is checked on
# every resources/updated broadcast and held for the subscription's whole lifetime.
const MAX_RESOURCE_SUBSCRIPTIONS = 256

# Same bound for watched task ids (tasks extension `notifications/tasks`)
const MAX_TASK_SUBSCRIPTIONS = 256

"""
    SubscriptionFilter(; tools_list_changed=false, prompts_list_changed=false,
                       resources_list_changed=false, resource_uris=Set{String}(),
                       task_ids=Set{String}())

The notification types a `subscriptions/listen` stream opted into. A server MUST NOT
send notification types the client did not explicitly request, so every delivery is
checked against this filter.

# Fields
- `tools_list_changed::Bool`: deliver `notifications/tools/list_changed`
- `prompts_list_changed::Bool`: deliver `notifications/prompts/list_changed`
- `resources_list_changed::Bool`: deliver `notifications/resources/list_changed`
- `resource_uris::Set{String}`: deliver `notifications/resources/updated` for these
  URIs (a set: membership is checked on every update broadcast)
- `task_ids::Set{String}`: deliver `notifications/tasks` status updates for these
  task ids (tasks extension, SEP-2663; only ids the requestor could `tasks/get` are
  ever agreed to)
"""
Base.@kwdef struct SubscriptionFilter
    tools_list_changed::Bool = false
    prompts_list_changed::Bool = false
    resources_list_changed::Bool = false
    resource_uris::Set{String} = Set{String}()
    task_ids::Set{String} = Set{String}()
end

"""
    SubscriptionRecord(id, filter, route, transport,
                       task_principal=nothing, task_scopes=Set{String}())

One active `subscriptions/listen` stream.

# Fields
- `id::Union{String,Int}`: the listen request's JSON-RPC id — also the
  `io.modelcontextprotocol/subscriptionId` every message on the stream carries
- `filter::SubscriptionFilter`: the notification types this stream opted into
- `route::Any`: the transport route handle the notifications are delivered on
  (`nothing` for stream transports like stdio, which share one channel)
- `transport::Any`: the transport to deliver over (`Transport`; typed `Any` to avoid
  include-order coupling)
- `task_principal::Union{String,Nothing}`: the listen requestor's extension-task
  principal, re-checked at every `notifications/tasks` delivery
- `task_scopes::Set{String}`: the listen requestor's token scopes, re-checked
  against the task's `required_scopes` at every `notifications/tasks` delivery —
  a task whose authorization requirements changed after the listen must not keep
  leaking status to a stream that could no longer `tasks/get` it
"""
struct SubscriptionRecord
    id::Union{String,Int}
    filter::SubscriptionFilter
    route::Any
    transport::Any
    task_principal::Union{String,Nothing}
    task_scopes::Set{String}
end
SubscriptionRecord(id, filter, route, transport) =
    SubscriptionRecord(id, filter, route, transport, nothing, Set{String}())

"""
    SubscriptionRegistry()

Registry of active `subscriptions/listen` streams. Guarded by a lock: the single
server loop registers streams while HTTP connection tasks and background task
executions can broadcast notifications concurrently. Deliveries happen WHILE
holding this lock (all delivery paths enqueue without blocking), which is what
guarantees the acknowledged-first and nothing-after-the-closing-result orderings.

Lock ordering: `registry.lock` may be held when a delivery takes the HTTP
transport's `channels_lock`, never the reverse — nothing takes `registry.lock`
while holding `channels_lock`.

# Fields
- `subs::Vector{SubscriptionRecord}`: active subscriptions
- `lock::ReentrantLock`: guards `subs`
"""
mutable struct SubscriptionRegistry
    subs::Vector{SubscriptionRecord}
    lock::ReentrantLock

    SubscriptionRegistry() = new(SubscriptionRecord[], ReentrantLock())
end

"""
    parse_subscription_filter(notifications) -> Union{SubscriptionFilter,String}

Validate and parse the `notifications` filter object of a `subscriptions/listen`
request. Returns the parsed filter, or a violation message the caller must reject
with -32602: the filter must be an object, the `*ListChanged` flags booleans,
`resourceSubscriptions` an array of at most `MAX_RESOURCE_SUBSCRIPTIONS` strings, and
at least one notification type must be requested — a malformed filter must not
silently establish a long-lived stream that can never deliver anything.

Unknown keys are ignored (forward compatibility), and requesting types this server
cannot deliver is NOT a violation: the honored subset in the acknowledgment is how
the server communicates what it will actually send (see `handle_subscriptions_listen`).

# Arguments
- `notifications`: The request's `params.notifications` value (any JSON value)

# Returns
- `Union{SubscriptionFilter,String}`: The parsed filter, or the violation
"""
function parse_subscription_filter(notifications)::Union{SubscriptionFilter,String}
    notifications isa AbstractDict || return "notifications must be an object"
    for key in ("toolsListChanged", "promptsListChanged", "resourcesListChanged")
        haskey(notifications, key) && !(notifications[key] isa Bool) &&
            return "$key must be a boolean"
    end
    uris = Set{String}()
    if haskey(notifications, "resourceSubscriptions")
        subs = notifications["resourceSubscriptions"]
        subs isa AbstractVector || return "resourceSubscriptions must be an array of strings"
        length(subs) > MAX_RESOURCE_SUBSCRIPTIONS &&
            return "resourceSubscriptions exceeds the limit of $(MAX_RESOURCE_SUBSCRIPTIONS) URIs"
        for u in subs
            u isa AbstractString || return "resourceSubscriptions must be an array of strings"
            push!(uris, String(u))
        end
    end
    tids = Set{String}()
    if haskey(notifications, "taskIds")
        ids = notifications["taskIds"]
        ids isa AbstractVector || return "taskIds must be an array of strings"
        length(ids) > MAX_TASK_SUBSCRIPTIONS &&
            return "taskIds exceeds the limit of $(MAX_TASK_SUBSCRIPTIONS) ids"
        for t in ids
            t isa AbstractString || return "taskIds must be an array of strings"
            push!(tids, String(t))
        end
    end
    f = SubscriptionFilter(
        tools_list_changed = get(notifications, "toolsListChanged", false) === true,
        prompts_list_changed = get(notifications, "promptsListChanged", false) === true,
        resources_list_changed = get(notifications, "resourcesListChanged", false) === true,
        resource_uris = uris,
        task_ids = tids
    )
    if !(f.tools_list_changed || f.prompts_list_changed || f.resources_list_changed) &&
       isempty(uris) && isempty(tids)
        return "at least one notification type must be requested"
    end
    f
end

"""
    filter_to_wire(f::SubscriptionFilter) -> LittleDict{String,Any}

Serialize a filter to the wire shape used in the acknowledgment's `notifications`
field, which reflects the subset the server agreed to honor. Types not subscribed
are omitted, and the resource URIs are emitted sorted (the in-memory set has no
stable order).

# Arguments
- `f::SubscriptionFilter`: The filter

# Returns
- `LittleDict{String,Any}`: The honored subset
"""
function filter_to_wire(f::SubscriptionFilter)::LittleDict{String,Any}
    d = LittleDict{String,Any}()
    f.tools_list_changed && (d["toolsListChanged"] = true)
    f.prompts_list_changed && (d["promptsListChanged"] = true)
    f.resources_list_changed && (d["resourcesListChanged"] = true)
    isempty(f.resource_uris) || (d["resourceSubscriptions"] = sort!(collect(f.resource_uris)))
    isempty(f.task_ids) || (d["taskIds"] = sort!(collect(f.task_ids)))
    d
end

"""
    filter_wants(f::SubscriptionFilter, method::String,
                 uri::Union{String,Nothing}=nothing,
                 task_id::Union{String,Nothing}=nothing) -> Bool

Whether a notification of `method` (for resource updates, of `uri`; for task status
updates, of `task_id`) was opted into.

# Arguments
- `f::SubscriptionFilter`: The subscription's filter
- `method::String`: The notification method
- `uri::Union{String,Nothing}`: The resource URI for `notifications/resources/updated`
- `task_id::Union{String,Nothing}`: The task id for `notifications/tasks`

# Returns
- `Bool`: true when the notification may be delivered on this stream
"""
function filter_wants(f::SubscriptionFilter, method::String,
                      uri::Union{String,Nothing} = nothing,
                      task_id::Union{String,Nothing} = nothing)::Bool
    if method == "notifications/tools/list_changed"
        return f.tools_list_changed
    elseif method == "notifications/prompts/list_changed"
        return f.prompts_list_changed
    elseif method == "notifications/resources/list_changed"
        return f.resources_list_changed
    elseif method == "notifications/resources/updated"
        return uri !== nothing && uri in f.resource_uris
    elseif method == "notifications/tasks"
        return task_id !== nothing && task_id in f.task_ids
    end
    return false
end

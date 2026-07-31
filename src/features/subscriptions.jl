# src/features/subscriptions.jl
# Registry types for modern-era (2026-07-28+) `subscriptions/listen` streams.
#
# A `subscriptions/listen` request opens a long-lived response stream carrying only
# the notification types the client opted into. The request never completes normally:
# its response route is captured (see `capture_response_route`) and notifications are
# pushed onto it as they occur, each tagged with the subscription's id. The handler
# and the broadcast API live in `src/protocol/subscriptions.jl` (they need
# `RequestContext`); this file holds the types `Server` embeds.

"""
    SubscriptionFilter(; tools_list_changed=false, prompts_list_changed=false,
                       resources_list_changed=false, resource_uris=String[])

The notification types a `subscriptions/listen` stream opted into. A server MUST NOT
send notification types the client did not explicitly request, so every delivery is
checked against this filter.

# Fields
- `tools_list_changed::Bool`: deliver `notifications/tools/list_changed`
- `prompts_list_changed::Bool`: deliver `notifications/prompts/list_changed`
- `resources_list_changed::Bool`: deliver `notifications/resources/list_changed`
- `resource_uris::Vector{String}`: deliver `notifications/resources/updated` for these URIs
"""
Base.@kwdef struct SubscriptionFilter
    tools_list_changed::Bool = false
    prompts_list_changed::Bool = false
    resources_list_changed::Bool = false
    resource_uris::Vector{String} = String[]
end

"""
    SubscriptionRecord(id, filter, route, transport)

One active `subscriptions/listen` stream.

# Fields
- `id::Union{String,Int}`: the listen request's JSON-RPC id — also the
  `io.modelcontextprotocol/subscriptionId` every message on the stream carries
- `filter::SubscriptionFilter`: the notification types this stream opted into
- `route::Any`: the transport route handle the notifications are delivered on
  (`nothing` for stream transports like stdio, which share one channel)
- `transport::Any`: the transport to deliver over (`Transport`; typed `Any` to avoid
  include-order coupling)
"""
struct SubscriptionRecord
    id::Union{String,Int}
    filter::SubscriptionFilter
    route::Any
    transport::Any
end

"""
    SubscriptionRegistry()

Registry of active `subscriptions/listen` streams. Guarded by a lock: the single
server loop registers streams while HTTP connection tasks and background task
executions can broadcast notifications concurrently.

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
    parse_subscription_filter(notifications) -> SubscriptionFilter

Parse the `notifications` filter object of a `subscriptions/listen` request. Absent
or non-boolean flags mean "not subscribed"; `resourceSubscriptions` collects the
resource URIs to watch. Unknown keys are ignored (a filter naming only unsupported
types simply yields an empty subscription).

# Arguments
- `notifications`: The request's `params.notifications` value (any JSON value)

# Returns
- `SubscriptionFilter`: The parsed filter
"""
function parse_subscription_filter(notifications)::SubscriptionFilter
    notifications isa AbstractDict || return SubscriptionFilter()
    flag(key) = get(notifications, key, false) === true
    uris = String[]
    subs = get(notifications, "resourceSubscriptions", nothing)
    if subs isa AbstractVector
        for u in subs
            u isa AbstractString && push!(uris, String(u))
        end
    end
    SubscriptionFilter(
        tools_list_changed = flag("toolsListChanged"),
        prompts_list_changed = flag("promptsListChanged"),
        resources_list_changed = flag("resourcesListChanged"),
        resource_uris = uris
    )
end

"""
    filter_to_wire(f::SubscriptionFilter) -> LittleDict{String,Any}

Serialize a filter to the wire shape used in the acknowledgment's `notifications`
field, which reflects the subset the server agreed to honor. Types not subscribed
are omitted.

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
    isempty(f.resource_uris) || (d["resourceSubscriptions"] = f.resource_uris)
    d
end

"""
    filter_wants(f::SubscriptionFilter, method::String, uri::Union{String,Nothing}) -> Bool

Whether a notification of `method` (for resource updates, of `uri`) was opted into.

# Arguments
- `f::SubscriptionFilter`: The subscription's filter
- `method::String`: The notification method
- `uri::Union{String,Nothing}`: The resource URI for `notifications/resources/updated`

# Returns
- `Bool`: true when the notification may be delivered on this stream
"""
function filter_wants(f::SubscriptionFilter, method::String,
                      uri::Union{String,Nothing} = nothing)::Bool
    if method == "notifications/tools/list_changed"
        return f.tools_list_changed
    elseif method == "notifications/prompts/list_changed"
        return f.prompts_list_changed
    elseif method == "notifications/resources/list_changed"
        return f.resources_list_changed
    elseif method == "notifications/resources/updated"
        return uri !== nothing && uri in f.resource_uris
    end
    return false
end

# src/protocol/subscriptions.jl
# Modern-era (2026-07-28+) `subscriptions/listen`: the long-lived POST response stream
# that replaces the legacy GET SSE endpoint and `resources/subscribe`/`unsubscribe`.
#
# The listen request never completes normally. Its response route is captured and the
# handler returns `deferred`, so the server loop moves on while notifications are
# pushed onto that route as changes occur. Every message on the stream — the opening
# acknowledgment, each notification, and the closing result — carries the
# subscription's id in `_meta` under `io.modelcontextprotocol/subscriptionId`, which
# is how clients demultiplex streams on stdio (one shared channel) and how they
# correlate them on HTTP.

"""
    subscription_notification(method::String, params::AbstractDict, sub_id) -> String

Serialize a notification for delivery on a `subscriptions/listen` stream, tagging it
with the subscription id the spec requires on every stream message.

# Arguments
- `method::String`: The notification method
- `params::AbstractDict`: The notification's params (the `_meta` tag is added here)
- `sub_id`: The subscription id (the listen request's JSON-RPC id)

# Returns
- `String`: The serialized JSON-RPC notification
"""
function subscription_notification(method::String, params::AbstractDict, sub_id)::String
    p = Dict{String,Any}(String(k) => v for (k, v) in params)
    p["_meta"] = Dict{String,Any}(META_SUBSCRIPTION_ID => sub_id)
    JSON3.write(Dict{String,Any}(
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => p
    ))
end

# Limits: each subscription pins a record, a response route, and (on HTTP) an open
# connection with its channel, for an unbounded lifetime — so both the number of
# active subscriptions and the size of the id used to tag every message are bounded.
const MAX_SUBSCRIPTIONS = 64
const MAX_SUBSCRIPTION_ID_LENGTH = 128

"""
    handle_subscriptions_listen(ctx::RequestContext, params::SubscriptionsListenParams) -> HandlerResult

Open a `subscriptions/listen` stream: validate the filter (a malformed one is
rejected with -32602, not silently emptied), send
`notifications/subscriptions/acknowledged` as the stream's FIRST message (carrying the
honored subset of the requested filter), register the subscription, and defer the
request's response — the stream stays open until the client closes it, cancels it
(`notifications/cancelled` on stdio), or the server shuts down (`close_subscriptions!`).

Ack-then-register happens under the registry lock, so a concurrent broadcast can
neither enqueue a change notification ahead of the acknowledgment nor observe a
half-registered stream — and a stream whose ack cannot be delivered is never
registered at all.

Notification types the server cannot deliver are omitted from the acknowledged
filter rather than silently accepted, so a client can tell what it will actually
receive.

# Arguments
- `ctx::RequestContext`: The current request context
- `params::SubscriptionsListenParams`: The request's notification filter

# Returns
- `HandlerResult`: A deferred result (the response, if any, arrives at closure)
"""
function handle_subscriptions_listen(ctx::RequestContext,
                                     params::SubscriptionsListenParams)::HandlerResult
    # Task status subscriptions belong to the tasks extension, and its
    # missing-capability error is a spec MUST that takes precedence over shape
    # validation: the PRESENCE of a taskIds entry from a non-declaring client is
    # -32021 whatever the entry looks like (a malformed or over-limit array must
    # not demote the error to -32602)
    if params.notifications isa AbstractDict && haskey(params.notifications, "taskIds") &&
       !tasks_extension_declared(ctx.client_capabilities)
        return HandlerResult(error = tasks_extension_required_error())
    end

    requested = parse_subscription_filter(params.notifications)
    requested isa SubscriptionFilter || return HandlerResult(
        error = ErrorInfo(
            code = ErrorCodes.INVALID_PARAMS,
            message = "Invalid subscriptions/listen filter: $requested"
        )
    )

    registry = ctx.server.listen_subscriptions

    # Cheap capacity precheck BEFORE the (potentially 256-id) task resolution
    # below — the race-safe check at registration remains authoritative
    at_capacity = lock(registry.lock) do
        length(registry.subs) >= MAX_SUBSCRIPTIONS
    end
    if at_capacity
        return HandlerResult(
            error = ErrorInfo(
                code = ErrorCodes.INTERNAL_ERROR,
                message = "subscriptions/listen: active subscription limit reached ($(MAX_SUBSCRIPTIONS))"
            )
        )
    end

    # Honor only what this server can actually deliver: list-changed types require
    # the corresponding capability, resource subscriptions require resources.subscribe
    caps = ctx.server.config.capabilities
    tool_lc = any(c -> c isa ToolCapability && c.list_changed, caps)
    prompt_lc = any(c -> c isa PromptCapability && c.list_changed, caps)
    res_lc = any(c -> c isa ResourceCapability && c.list_changed, caps)
    res_sub = any(c -> c isa ResourceCapability && c.subscribe, caps)
    # Agree only to task ids this requestor could tasks/get RIGHT NOW: same
    # principal, extension era, and per-request scope re-authorization — an
    # unknown or foreign id is silently omitted from the acknowledged set, so
    # subscription probing leaks nothing a tasks/get poll would not. Batch
    # resolution under ONE store lock and ONE sweep (a per-id get_task would
    # sweep the whole store up to 256 times).
    task_principal = ext_task_principal(ctx)
    honored_task_ids = Set{String}()
    if !isempty(requested.task_ids)
        store = ctx.server.tasks
        lock(store.lock) do
            sweep_expired!(store)
            for tid in requested.task_ids
                record = get(store.tasks, tid, nothing)
                record === nothing && continue
                (record.principal == task_principal && record.era === :ext) || continue
                ext_task_authorized(ctx, record) || continue
                push!(honored_task_ids, tid)
            end
        end
    end
    honored = SubscriptionFilter(
        tools_list_changed = requested.tools_list_changed && tool_lc,
        prompts_list_changed = requested.prompts_list_changed && prompt_lc,
        resources_list_changed = requested.resources_list_changed && res_lc,
        resource_uris = res_sub ? requested.resource_uris : Set{String}(),
        task_ids = honored_task_ids
    )

    sub_id = ctx.request_id
    if !(sub_id isa Union{String,Int})
        return HandlerResult(
            error = ErrorInfo(
                code = ErrorCodes.INVALID_REQUEST,
                message = "subscriptions/listen requires a string or integer request id"
            )
        )
    end
    if sub_id isa String && ncodeunits(sub_id) > MAX_SUBSCRIPTION_ID_LENGTH
        return HandlerResult(
            error = ErrorInfo(
                code = ErrorCodes.INVALID_REQUEST,
                message = "subscriptions/listen id exceeds $(MAX_SUBSCRIPTION_ID_LENGTH) bytes"
            )
        )
    end

    transport = ctx.server.transport
    if transport === nothing
        return HandlerResult(
            error = ErrorInfo(
                code = ErrorCodes.INTERNAL_ERROR,
                message = "No transport available for subscriptions/listen"
            )
        )
    end

    ack = subscription_notification(
        "notifications/subscriptions/acknowledged",
        LittleDict{String,Any}("notifications" => filter_to_wire(honored)),
        sub_id
    )

    # The rejection checks run BEFORE the route is captured (a rejected request's
    # error response still goes out on the normal path), and the ack-then-register
    # pair runs under the registry lock (see docstring). The id-uniqueness check is
    # load-bearing on stdio, where the id is the only way to tell streams apart.
    task_scopes = ctx.authenticated_user === nothing ?
        Set{String}() : Set{String}(ctx.authenticated_user.scopes)
    status = lock(registry.lock) do
        # Sweep dead routes FIRST: a record whose connection handler already died
        # (client vanished) must not consume the capacity cap or pin its id
        # against a reconnect — without this, pruning would only happen on the
        # next broadcast, which on a quiet server never comes.
        filter!(s -> route_alive(s.transport, s.route), registry.subs)
        length(registry.subs) >= MAX_SUBSCRIPTIONS && return :capacity
        any(s -> s.id == sub_id, registry.subs) && return :duplicate
        route = capture_response_route(transport)
        deliver_notification(transport, route, ack) || return :unreachable
        push!(registry.subs, SubscriptionRecord(sub_id, honored, route, transport,
                                                task_principal, task_scopes))
        :ok
    end

    if status === :capacity
        return HandlerResult(
            error = ErrorInfo(
                code = ErrorCodes.INTERNAL_ERROR,
                message = "subscriptions/listen: active subscription limit reached ($(MAX_SUBSCRIPTIONS))"
            )
        )
    elseif status === :duplicate
        return HandlerResult(
            error = ErrorInfo(
                code = ErrorCodes.INVALID_REQUEST,
                message = "subscriptions/listen id duplicates an active subscription"
            )
        )
    elseif status === :unreachable
        @debug "subscriptions/listen: client route unavailable; subscription dropped" sub_id
    end

    # Initial per-task snapshot: a transition landing between the authorization
    # above and the registration would otherwise never be pushed — the ack names
    # the id but no notification follows, and a notification-only client waits
    # forever. Fired through the normal status-change path (complete-state
    # semantics make the extra push benign for other streams watching the id).
    if status === :ok && !isempty(honored_task_ids)
        store = ctx.server.tasks
        lock(store.lock) do
            for tid in honored_task_ids
                record = get(store.tasks, tid, nothing)
                record === nothing || _fire_status_change(store, record)
            end
        end
    end

    HandlerResult(deferred = true)
end

"""
    broadcast_subscription_notification(server::Server, method::String;
                                        params::AbstractDict=LittleDict{String,Any}(),
                                        uri::Union{String,Nothing}=nothing,
                                        task_id::Union{String,Nothing}=nothing) -> Int

Deliver a notification to every `subscriptions/listen` stream that opted into it,
tagged with each stream's own subscription id. Every record — not just the filter
matches — is swept for liveness (`route_alive`), so a disconnected client whose
filter never matches anything still gets pruned. Returns the number of streams the
notification reached.

Delivery happens while holding the registry lock (every delivery path enqueues
without blocking), so a broadcast cannot interleave with a stream's registration or
graceful closure; see the `SubscriptionRegistry` docstring for the lock ordering.

# Arguments
- `server::Server`: The server whose subscriptions to notify
- `method::String`: The notification method
- `params::AbstractDict`: Additional notification params
- `uri::Union{String,Nothing}`: For `notifications/resources/updated`, the resource URI
- `task_id::Union{String,Nothing}`: For `notifications/tasks`, the task id
- `authorize`: Optional per-stream predicate `record::SubscriptionRecord -> Bool`
  checked after the filter match — used by `notifications/tasks` to re-authorize
  each delivery against the stream's stored principal/scopes WITHOUT taking the
  task-store lock here (the ordering store → registry must never reverse)

# Returns
- `Int`: How many streams received the notification
"""
function broadcast_subscription_notification(server::Server, method::String;
                                             params::AbstractDict = LittleDict{String,Any}(),
                                             uri::Union{String,Nothing} = nothing,
                                             task_id::Union{String,Nothing} = nothing,
                                             authorize::Union{Nothing,Function} = nothing)::Int
    registry = server.listen_subscriptions
    lock(registry.lock) do
        delivered = 0
        kept = SubscriptionRecord[]
        for s in registry.subs
            alive = route_alive(s.transport, s.route)
            if alive && filter_wants(s.filter, method, uri, task_id) &&
               (authorize === nothing || authorize(s) === true)
                payload = subscription_notification(method, params, s.id)
                alive = deliver_notification(s.transport, s.route, payload)
                alive && (delivered += 1)
            end
            alive && push!(kept, s)
        end
        if length(kept) != length(registry.subs)
            @debug "Pruned dead subscriptions/listen streams" count=(length(registry.subs) - length(kept))
            registry.subs = kept
        end
        delivered
    end
end

"""
    notify_list_changed(server::Server, kind::Symbol) -> Int

Announce that a list of server components changed, delivering
`notifications/{kind}/list_changed` to every `subscriptions/listen` stream that
subscribed to it. Call this after mutating `server.tools`, `server.prompts`, or
`server.resources` at runtime.

Only streams open at the time of the change are notified (there is no backlog), and
only when the corresponding `listChanged` capability is declared.

# Arguments
- `server::Server`: The server whose lists changed
- `kind::Symbol`: One of `:tools`, `:prompts`, `:resources`

# Returns
- `Int`: How many subscription streams were notified
"""
function notify_list_changed(server::Server, kind::Symbol)::Int
    kind in (:tools, :prompts, :resources) ||
        throw(ArgumentError("notify_list_changed: kind must be :tools, :prompts, or :resources"))
    broadcast_subscription_notification(server, "notifications/$(kind)/list_changed")
end

"""
    notify_resource_updated(server::Server, uri::AbstractString) -> Int

Announce that a resource's contents changed, delivering
`notifications/resources/updated` to every `subscriptions/listen` stream that
subscribed to that URI.

# Arguments
- `server::Server`: The server holding the resource
- `uri::AbstractString`: The resource URI that changed

# Returns
- `Int`: How many subscription streams were notified
"""
function notify_resource_updated(server::Server, uri::AbstractString)::Int
    u = String(uri)
    broadcast_subscription_notification(server, "notifications/resources/updated";
                                        params = LittleDict{String,Any}("uri" => u),
                                        uri = u)
end

"""
    cancel_subscription!(server::Server, request_id) -> Bool

Cancel an active `subscriptions/listen` stream by its originating request id — the
`notifications/cancelled` path, which is how a stdio client (which cannot close a
response stream) ends a subscription. The record is removed so no further messages
carry its id; per JSON-RPC cancellation semantics no response is sent.

Only ROUTELESS records (stream transports like stdio, where the single shared
channel means the cancellation can only come from the stream's own client) are
cancellable this way. A route-bound (HTTP) stream is cancelled by closing the
response stream itself — an in-band cancellation message must never be honored
for it, because on HTTP the notification can arrive on ANY connection: honoring
it would let one client end another client's stream by guessing its id.

# Arguments
- `server::Server`: The server holding the subscription
- `request_id`: The listen request's JSON-RPC id (from the notification's `requestId`)

# Returns
- `Bool`: true when an active subscription was cancelled
"""
function cancel_subscription!(server::Server, request_id)::Bool
    request_id isa Union{String,Int} || return false
    registry = server.listen_subscriptions
    lock(registry.lock) do
        idx = findfirst(s -> s.id == request_id && s.route === nothing, registry.subs)
        idx === nothing && return false
        deleteat!(registry.subs, idx)
        true
    end
end

"""
    close_subscriptions!(server::Server) -> Nothing

End all `subscriptions/listen` streams gracefully: each open stream receives the
JSON-RPC response to its originating listen request (an empty complete result tagged
with its subscription id and carrying `serverInfo` like every other modern result),
which is how a client distinguishes an orderly server shutdown from an abrupt
transport drop. Called during server shutdown.

The closing results are delivered while holding the registry lock, so a concurrent
broadcast can never write on a stream AFTER its graceful result: the broadcast
either completes first or finds an empty registry.

# Arguments
- `server::Server`: The server whose subscriptions to close

# Returns
- `Nothing`
"""
function close_subscriptions!(server::Server)::Nothing
    registry = server.listen_subscriptions
    lock(registry.lock) do
        for s in registry.subs
            payload = JSON3.write(Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => s.id,
                "result" => Dict{String,Any}(
                    "resultType" => "complete",
                    "_meta" => Dict{String,Any}(
                        META_SUBSCRIPTION_ID => s.id,
                        META_SERVER_INFO => Dict{String,Any}(
                            "name" => server.config.name,
                            "version" => server.config.version,
                        )
                    )
                )
            ))
            try
                deliver_response(s.transport, s.route, payload)
            catch e
                @debug "Failed to close subscription stream gracefully" sub_id=s.id error=e
            end
        end
        empty!(registry.subs)
    end
    nothing
end

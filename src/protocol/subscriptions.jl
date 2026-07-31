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

"""
    handle_subscriptions_listen(ctx::RequestContext, params::SubscriptionsListenParams) -> HandlerResult

Open a `subscriptions/listen` stream: register the subscription, send
`notifications/subscriptions/acknowledged` as the stream's FIRST message (carrying the
honored subset of the requested filter), and defer the request's response — the
stream stays open until the client closes it or the server shuts down
(`close_subscriptions!`).

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
    requested = parse_subscription_filter(params.notifications)

    # Honor only what this server can actually deliver: list-changed types require
    # the corresponding capability, resource subscriptions require resources.subscribe
    caps = ctx.server.config.capabilities
    tool_lc = any(c -> c isa ToolCapability && c.list_changed, caps)
    prompt_lc = any(c -> c isa PromptCapability && c.list_changed, caps)
    res_lc = any(c -> c isa ResourceCapability && c.list_changed, caps)
    res_sub = any(c -> c isa ResourceCapability && c.subscribe, caps)
    honored = SubscriptionFilter(
        tools_list_changed = requested.tools_list_changed && tool_lc,
        prompts_list_changed = requested.prompts_list_changed && prompt_lc,
        resources_list_changed = requested.resources_list_changed && res_lc,
        resource_uris = res_sub ? requested.resource_uris : String[]
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

    transport = ctx.server.transport
    if transport === nothing
        return HandlerResult(
            error = ErrorInfo(
                code = ErrorCodes.INTERNAL_ERROR,
                message = "No transport available for subscriptions/listen"
            )
        )
    end

    # Detach this request's response route so the loop can move on; notifications
    # (and the eventual closing result) are delivered on it from now on.
    route = capture_response_route(transport)
    record = SubscriptionRecord(sub_id, honored, route, transport)
    registry = ctx.server.listen_subscriptions
    lock(registry.lock) do
        push!(registry.subs, record)
    end

    # The acknowledgment MUST be the first message on the stream
    ack = subscription_notification(
        "notifications/subscriptions/acknowledged",
        LittleDict{String,Any}("notifications" => filter_to_wire(honored)),
        sub_id
    )
    if !deliver_notification(transport, route, ack)
        lock(registry.lock) do
            filter!(s -> !(s.id == sub_id && s.route === route), registry.subs)
        end
        @debug "subscriptions/listen: client route unavailable; subscription dropped" sub_id
    end

    HandlerResult(deferred = true)
end

"""
    broadcast_subscription_notification(server::Server, method::String;
                                        params::AbstractDict=LittleDict{String,Any}(),
                                        uri::Union{String,Nothing}=nothing) -> Int

Deliver a notification to every `subscriptions/listen` stream that opted into it,
tagged with each stream's own subscription id. Streams whose client has gone away are
pruned. Returns the number of streams the notification reached.

# Arguments
- `server::Server`: The server whose subscriptions to notify
- `method::String`: The notification method
- `params::AbstractDict`: Additional notification params
- `uri::Union{String,Nothing}`: For `notifications/resources/updated`, the resource URI

# Returns
- `Int`: How many streams received the notification
"""
function broadcast_subscription_notification(server::Server, method::String;
                                             params::AbstractDict = LittleDict{String,Any}(),
                                             uri::Union{String,Nothing} = nothing)::Int
    registry = server.listen_subscriptions
    targets = lock(registry.lock) do
        filter(s -> filter_wants(s.filter, method, uri), registry.subs)
    end
    isempty(targets) && return 0

    dead = SubscriptionRecord[]
    delivered = 0
    for s in targets
        payload = subscription_notification(method, params, s.id)
        if deliver_notification(s.transport, s.route, payload)
            delivered += 1
        else
            push!(dead, s)
        end
    end
    if !isempty(dead)
        lock(registry.lock) do
            filter!(s -> !any(d -> d.id == s.id && d.route === s.route, dead), registry.subs)
        end
        @debug "Pruned closed subscriptions/listen streams" count=length(dead)
    end
    delivered
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
    close_subscriptions!(server::Server) -> Nothing

End all `subscriptions/listen` streams gracefully: each open stream receives the
JSON-RPC response to its originating listen request (an empty complete result tagged
with its subscription id), which is how a client distinguishes an orderly server
shutdown from an abrupt transport drop. Called during server shutdown.

# Arguments
- `server::Server`: The server whose subscriptions to close

# Returns
- `Nothing`
"""
function close_subscriptions!(server::Server)::Nothing
    registry = server.listen_subscriptions
    subs = lock(registry.lock) do
        s = copy(registry.subs)
        empty!(registry.subs)
        s
    end
    for s in subs
        payload = JSON3.write(Dict{String,Any}(
            "jsonrpc" => "2.0",
            "id" => s.id,
            "result" => Dict{String,Any}(
                "resultType" => "complete",
                "_meta" => Dict{String,Any}(META_SUBSCRIPTION_ID => s.id)
            )
        ))
        try
            deliver_response(s.transport, s.route, payload)
        catch e
            @debug "Failed to close subscription stream gracefully" sub_id=s.id error=e
        end
    end
    nothing
end

@testset "subscriptions/listen (modern era)" begin
    @testset "filter validation (strict)" begin
        pf = ModelContextProtocol.parse_subscription_filter
        f = pf(Dict("toolsListChanged" => true, "resourceSubscriptions" => ["test://a", "test://b"]))
        @test f isa ModelContextProtocol.SubscriptionFilter
        @test f.tools_list_changed
        @test !f.prompts_list_changed
        @test f.resource_uris == Set(["test://a", "test://b"])

        # Malformed filters are violations (the handler answers -32602), not
        # silently-empty subscriptions that deliver nothing forever
        @test pf(nothing) isa String                                          # missing
        @test pf("junk") isa String                                           # scalar
        @test pf(Dict("toolsListChanged" => "yes")) isa String                # non-boolean flag
        @test pf(Dict("promptsListChanged" => 1)) isa String
        @test pf(Dict("resourceSubscriptions" => "not-an-array")) isa String
        @test pf(Dict("resourceSubscriptions" => Any["test://ok", 42])) isa String  # mixed types
        # A filter requesting nothing at all is a violation, not a useless stream
        @test pf(Dict{String,Any}()) isa String
        @test pf(Dict("toolsListChanged" => false)) isa String
        # ...but unknown keys are ignored when a known type IS requested
        @test pf(Dict("toolsListChanged" => true, "futureKey" => 1)) isa ModelContextProtocol.SubscriptionFilter

        # resourceSubscriptions is capped
        cap = ModelContextProtocol.MAX_RESOURCE_SUBSCRIPTIONS
        @test pf(Dict("resourceSubscriptions" => ["test://u$i" for i in 1:cap])) isa ModelContextProtocol.SubscriptionFilter
        @test pf(Dict("resourceSubscriptions" => ["test://u$i" for i in 1:(cap + 1)])) isa String
    end

    @testset "honored subset serialization" begin
        wire = ModelContextProtocol.filter_to_wire(ModelContextProtocol.SubscriptionFilter(
            tools_list_changed = true, resource_uris = Set(["test://b", "test://a"])))
        @test wire["toolsListChanged"] == true
        @test wire["resourceSubscriptions"] == ["test://a", "test://b"]  # sorted: deterministic wire order
        # Unsubscribed types are omitted, not sent as false
        @test !haskey(wire, "promptsListChanged")
        @test isempty(ModelContextProtocol.filter_to_wire(ModelContextProtocol.SubscriptionFilter()))
    end

    @testset "delivery predicate" begin
        wants = ModelContextProtocol.filter_wants
        f = ModelContextProtocol.SubscriptionFilter(tools_list_changed = true,
                                                    resource_uris = Set(["test://watched"]))
        @test wants(f, "notifications/tools/list_changed")
        @test !wants(f, "notifications/prompts/list_changed")
        @test !wants(f, "notifications/resources/list_changed")
        @test wants(f, "notifications/resources/updated", "test://watched")
        @test !wants(f, "notifications/resources/updated", "test://other")
        @test !wants(f, "notifications/resources/updated", nothing)
        @test !wants(f, "notifications/something/else")
    end

    @testset "notification tagging" begin
        raw = ModelContextProtocol.subscription_notification(
            "notifications/resources/updated",
            ModelContextProtocol.LittleDict{String,Any}("uri" => "test://x"), 7)
        msg = JSON3.read(raw)
        @test msg["method"] == "notifications/resources/updated"
        @test msg["params"]["uri"] == "test://x"
        @test msg["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == 7
    end

    @testset "broadcast with no subscribers is a no-op" begin
        server = mcp_server(name = "no-subs", version = "1.0.0")
        @test notify_list_changed(server, :tools) == 0
        @test notify_resource_updated(server, "test://nothing") == 0
        @test_throws ArgumentError notify_list_changed(server, :bogus)
    end

    @testset "honored subset is gated on declared capabilities" begin
        # A server that declares no listChanged/subscribe capability acknowledges an
        # EMPTY filter: the request asked validly, the server just cannot deliver —
        # it must not promise notifications it will never send.
        server = mcp_server(name = "no-caps", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability(list_changed = false)])
        server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = IOBuffer())
        ctx = RequestContext(server = server, request_id = "s1", protocol_version = "2026-07-28")
        result = ModelContextProtocol.handle_subscriptions_listen(ctx,
            ModelContextProtocol.SubscriptionsListenParams(
                notifications = Dict{String,Any}("toolsListChanged" => true)))
        @test result.deferred
        sub = only(server.listen_subscriptions.subs)
        @test !sub.filter.tools_list_changed
        # ...and the acknowledgment reflects that empty subset on the wire
        ack = JSON3.read(split(String(take!(server.transport.output)), '\n')[1])
        @test ack["method"] == "notifications/subscriptions/acknowledged"
        @test isempty(ack["params"]["notifications"])
        @test ack["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == "s1"
    end

    @testset "modern wire: malformed filters are rejected with -32602" begin
        server = mcp_server(name = "strict-subs", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability(list_changed = true)])
        server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = IOBuffer())
        state = ServerState()
        mmeta = Dict("io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                     "io.modelcontextprotocol/clientCapabilities" => Dict())
        listen_req(id, params) = JSON3.read(process_message(server, state, JSON3.write(Dict(
            "jsonrpc" => "2.0", "id" => id, "method" => "subscriptions/listen",
            "params" => params))))
        base = Dict{String,Any}("_meta" => mmeta)
        withn(n) = merge(base, Dict{String,Any}("notifications" => n))

        @test listen_req("m1", base)["error"]["code"] == -32602                     # notifications missing
        @test listen_req("m2", withn("junk"))["error"]["code"] == -32602            # scalar filter
        @test listen_req("m3", withn(Dict("toolsListChanged" => "yes")))["error"]["code"] == -32602
        @test listen_req("m4", withn(Dict("resourceSubscriptions" => Any["test://ok", 42])))["error"]["code"] == -32602
        @test listen_req("m5", withn(Dict{String,Any}()))["error"]["code"] == -32602  # nothing requested
        # None of them established a stream
        @test isempty(server.listen_subscriptions.subs)
        task_local_storage(:mcp_suppress_log_notifications, false)
    end

    @testset "subscription limits and id rules" begin
        server = mcp_server(name = "limits", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability(list_changed = true)])
        server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = IOBuffer())
        p = ModelContextProtocol.SubscriptionsListenParams(
            notifications = Dict{String,Any}("toolsListChanged" => true))
        ctx(id) = RequestContext(server = server, request_id = id, protocol_version = "2026-07-28")
        hl = ModelContextProtocol.handle_subscriptions_listen

        @test hl(ctx("dup"), p).deferred
        # An id duplicating an ACTIVE subscription is rejected — on stdio the id is
        # the only way to tell streams apart
        r = hl(ctx("dup"), p)
        @test r.error !== nothing && r.error.code == -32600
        @test length(server.listen_subscriptions.subs) == 1
        # ...but a cancelled id can be reused
        @test ModelContextProtocol.cancel_subscription!(server, "dup")
        @test hl(ctx("dup"), p).deferred

        # Oversized string ids are rejected
        r = hl(ctx("x"^(ModelContextProtocol.MAX_SUBSCRIPTION_ID_LENGTH + 1)), p)
        @test r.error !== nothing && r.error.code == -32600

        # Global active-subscription cap
        for i in 2:ModelContextProtocol.MAX_SUBSCRIPTIONS
            @test hl(ctx(i), p).deferred
        end
        @test length(server.listen_subscriptions.subs) == ModelContextProtocol.MAX_SUBSCRIPTIONS
        r = hl(ctx("overflow"), p)
        @test r.error !== nothing
        @test length(server.listen_subscriptions.subs) == ModelContextProtocol.MAX_SUBSCRIPTIONS
    end

    @testset "stdio cancellation via notifications/cancelled" begin
        out = IOBuffer()
        server = mcp_server(name = "cancel-subs", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability(list_changed = true)])
        server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = out)
        ModelContextProtocol.handle_subscriptions_listen(
            RequestContext(server = server, request_id = 42, protocol_version = "2026-07-28"),
            ModelContextProtocol.SubscriptionsListenParams(
                notifications = Dict{String,Any}("toolsListChanged" => true)))
        take!(out)  # discard the acknowledgment

        # Cancelling an unknown id is a no-op
        @test !ModelContextProtocol.cancel_subscription!(server, 999)
        @test length(server.listen_subscriptions.subs) == 1

        # The wire path: notifications/cancelled with the listen request's id
        process_message(server, ServerState(), JSON3.write(Dict(
            "jsonrpc" => "2.0", "method" => "notifications/cancelled",
            "params" => Dict("requestId" => 42))))
        @test isempty(server.listen_subscriptions.subs)
        # No response was sent for the cancelled request, and nothing is delivered anymore
        @test notify_list_changed(server, :tools) == 0
        @test isempty(String(take!(out)))
        task_local_storage(:mcp_suppress_log_notifications, false)

        # A route-bound (HTTP) stream is NOT cancellable by message: on HTTP the
        # notification can arrive on any connection, so honoring it would let one
        # client end another client's stream by guessing its id — HTTP cancels by
        # closing the response stream instead
        ht = HttpTransport(port = 18997)
        ch = Channel{Tuple{Symbol,String}}(Inf)
        lock(ht.channels_lock) do
            ht.response_channels["r-live"] = ch
        end
        push!(server.listen_subscriptions.subs, ModelContextProtocol.SubscriptionRecord(
            "http-sub", ModelContextProtocol.SubscriptionFilter(tools_list_changed = true),
            "r-live", ht))
        @test !ModelContextProtocol.cancel_subscription!(server, "http-sub")
        @test length(server.listen_subscriptions.subs) == 1
    end

    @testset "dead records are swept at registration, not just on broadcast" begin
        server = mcp_server(name = "reg-sweep", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability(list_changed = true)])
        server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = IOBuffer())
        # A record whose connection handler already died: HTTP route with no channel
        dead_transport = HttpTransport(port = 18996)
        push!(server.listen_subscriptions.subs, ModelContextProtocol.SubscriptionRecord(
            "dup", ModelContextProtocol.SubscriptionFilter(tools_list_changed = true),
            "r-gone", dead_transport))
        # Reconnecting with the SAME id must succeed — the dead record must not
        # pin its id (or the capacity cap) until some broadcast happens to sweep it
        r = ModelContextProtocol.handle_subscriptions_listen(
            RequestContext(server = server, request_id = "dup", protocol_version = "2026-07-28"),
            ModelContextProtocol.SubscriptionsListenParams(
                notifications = Dict{String,Any}("toolsListChanged" => true)))
        @test r.deferred
        sub = only(server.listen_subscriptions.subs)
        @test sub.id == "dup" && sub.route === nothing  # the NEW (stdio) record
    end

    @testset "stop! cannot be undone by notifications/initialized" begin
        server = mcp_server(name = "lifecycle", version = "1.0.0")
        server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = IOBuffer())
        state = ServerState()
        server.active = false  # as after stop!
        process_message(server, state, JSON3.write(Dict(
            "jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => Dict())))
        @test !server.active            # the loop-run flag belongs to start!/stop!
        @test state.initialized         # the session-lifecycle flag still records it
        task_local_storage(:mcp_suppress_log_notifications, false)
    end

    @testset "the acknowledgment precedes any broadcast on a new stream" begin
        out = IOBuffer()
        server = mcp_server(name = "ordered", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability(list_changed = true)])
        server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = out)
        p = ModelContextProtocol.SubscriptionsListenParams(
            notifications = Dict{String,Any}("toolsListChanged" => true))

        stop = Ref(false)
        hammer = @async while !stop[]
            notify_list_changed(server, :tools)
            yield()
        end
        for i in 1:20
            ModelContextProtocol.handle_subscriptions_listen(
                RequestContext(server = server, request_id = "ord-$i", protocol_version = "2026-07-28"), p)
            yield()
        end
        stop[] = true
        wait(hammer)

        # Registration happens under the same lock that delivers broadcasts, so the
        # FIRST message tagged with a new stream's id is always its acknowledgment
        lines = filter(!isempty, split(String(take!(out)), '\n'))
        for i in 1:20
            mine = filter(l -> occursin("\"ord-$i\"", l), lines)
            @test !isempty(mine)
            @test occursin("subscriptions/acknowledged", first(mine))
        end
    end

    @testset "stdio: tagged delivery, filtering, and graceful closure" begin
        out = IOBuffer()
        server = mcp_server(name = "stdio-subs", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[
                ModelContextProtocol.ToolCapability(list_changed = true),
                ModelContextProtocol.PromptCapability(list_changed = true),
                ModelContextProtocol.ResourceCapability(list_changed = true, subscribe = true)])
        server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = out)

        ctx = RequestContext(server = server, request_id = 1, protocol_version = "2026-07-28")
        ModelContextProtocol.handle_subscriptions_listen(ctx,
            ModelContextProtocol.SubscriptionsListenParams(notifications = Dict{String,Any}(
                "toolsListChanged" => true,
                "resourceSubscriptions" => ["test://watched"])))
        take!(out)  # discard the acknowledgment

        # Subscribed type is delivered and tagged
        @test notify_list_changed(server, :tools) == 1
        msg = JSON3.read(split(String(take!(out)), '\n')[1])
        @test msg["method"] == "notifications/tools/list_changed"
        @test msg["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == 1

        # Unsubscribed type is NOT delivered (server MUST NOT send unrequested types)
        @test notify_list_changed(server, :prompts) == 0
        @test isempty(String(take!(out)))

        # Resource updates only for subscribed URIs
        @test notify_resource_updated(server, "test://watched") == 1
        @test occursin("test://watched", String(take!(out)))
        @test notify_resource_updated(server, "test://other") == 0
        @test isempty(String(take!(out)))

        # Graceful closure answers the listen request with an empty complete result
        # that identifies the server like every other modern result
        ModelContextProtocol.close_subscriptions!(server)
        closing = JSON3.read(split(String(take!(out)), '\n')[1])
        @test closing["id"] == 1
        @test closing["result"]["resultType"] == "complete"
        @test closing["result"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == 1
        @test closing["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "stdio-subs"
        @test isempty(server.listen_subscriptions.subs)

        # After closure nothing is delivered — close-vs-broadcast is lock-ordered
        @test notify_list_changed(server, :tools) == 0
        @test isempty(String(take!(out)))
    end

    @testset "HTTP: dead routes are swept even when the filter never matches" begin
        transport = HttpTransport(port = 18999)
        server = mcp_server(name = "sweep", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability(list_changed = true)])
        server.transport = transport
        ch = Channel{Tuple{Symbol,String}}(Inf)
        lock(transport.channels_lock) do
            transport.response_channels["r-dead"] = ch
        end
        push!(server.listen_subscriptions.subs, ModelContextProtocol.SubscriptionRecord(
            "dead-sub", ModelContextProtocol.SubscriptionFilter(prompts_list_changed = true),
            "r-dead", transport))
        # The client vanishes: its connection handler closes and unregisters the channel
        Base.close(ch)
        lock(transport.channels_lock) do
            delete!(transport.response_channels, "r-dead")
        end
        # A broadcast of a type the filter does NOT even match still prunes the record
        @test notify_list_changed(server, :tools) == 0
        @test isempty(server.listen_subscriptions.subs)
    end

    @testset "HTTP: a listen stream that stops draining is load-shed at the backlog cap" begin
        transport = HttpTransport(port = 18998)
        server = mcp_server(name = "shed", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability(list_changed = true)])
        server.transport = transport
        ch = Channel{Tuple{Symbol,String}}(Inf)
        lock(transport.channels_lock) do
            transport.response_channels["r-slow"] = ch
        end
        push!(server.listen_subscriptions.subs, ModelContextProtocol.SubscriptionRecord(
            "slow-sub", ModelContextProtocol.SubscriptionFilter(tools_list_changed = true),
            "r-slow", transport))
        cap = ModelContextProtocol.LISTEN_BACKLOG_CAP
        @test all(notify_list_changed(server, :tools) == 1 for _ in 1:cap)
        # At the cap the stream is terminated and pruned instead of buffering forever
        @test notify_list_changed(server, :tools) == 0
        @test !isopen(ch)
        @test Base.n_avail(ch) == cap  # already-buffered items stay drainable
        @test isempty(server.listen_subscriptions.subs)
    end

    @testset "modern discover advertises what subscriptions can deliver" begin
        server = mcp_server(name = "caps", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[
                ModelContextProtocol.ToolCapability(list_changed = true),
                ModelContextProtocol.ResourceCapability(list_changed = false, subscribe = true)])
        state = ServerState()
        resp = JSON3.read(process_message(server, state, JSON3.write(Dict(
            "jsonrpc" => "2.0", "id" => 1, "method" => "server/discover",
            "params" => Dict("_meta" => Dict(
                "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities" => Dict()))))))
        caps = resp["result"]["capabilities"]
        @test caps["tools"]["listChanged"] == true
        @test caps["resources"]["subscribe"] == true
        @test !haskey(caps["resources"], "listChanged")
        task_local_storage(:mcp_suppress_log_notifications, false)
    end
end

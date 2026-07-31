@testset "subscriptions/listen (modern era)" begin
    @testset "filter parsing" begin
        pf = ModelContextProtocol.parse_subscription_filter
        f = pf(Dict("toolsListChanged" => true, "resourceSubscriptions" => ["test://a", "test://b"]))
        @test f.tools_list_changed
        @test !f.prompts_list_changed
        @test f.resource_uris == ["test://a", "test://b"]

        # Absent / non-boolean flags mean "not subscribed"; junk shapes don't throw
        f = pf(Dict("toolsListChanged" => "yes", "promptsListChanged" => 1))
        @test !f.tools_list_changed && !f.prompts_list_changed
        @test pf(nothing).resource_uris == String[]
        @test !pf("junk").tools_list_changed
        @test pf(Dict("resourceSubscriptions" => "not-an-array")).resource_uris == String[]
        # Non-string URIs are dropped, strings kept
        @test pf(Dict("resourceSubscriptions" => Any["test://ok", 42])).resource_uris == ["test://ok"]
    end

    @testset "honored subset serialization" begin
        wire = ModelContextProtocol.filter_to_wire(ModelContextProtocol.SubscriptionFilter(
            tools_list_changed = true, resource_uris = ["test://x"]))
        @test wire["toolsListChanged"] == true
        @test wire["resourceSubscriptions"] == ["test://x"]
        # Unsubscribed types are omitted, not sent as false
        @test !haskey(wire, "promptsListChanged")
        @test isempty(ModelContextProtocol.filter_to_wire(ModelContextProtocol.SubscriptionFilter()))
    end

    @testset "delivery predicate" begin
        wants = ModelContextProtocol.filter_wants
        f = ModelContextProtocol.SubscriptionFilter(tools_list_changed = true,
                                                    resource_uris = ["test://watched"])
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
        # EMPTY filter: it must not promise notifications it will never send.
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
        ModelContextProtocol.close_subscriptions!(server)
        closing = JSON3.read(split(String(take!(out)), '\n')[1])
        @test closing["id"] == 1
        @test closing["result"]["resultType"] == "complete"
        @test closing["result"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == 1
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

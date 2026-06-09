@testset "Resource Tests" begin
    @testset "resources/read returns provider data" begin
        resource = MCPResource(
            uri = "test://config",
            name = "config",
            description = "Test configuration",
            data_provider = () -> Dict("threshold" => 42),
        )
        server = mcp_server(name = "test", version = "1.0.0", resources = [resource])
        ctx = RequestContext(server = server, request_id = 1)

        result = handle_read_resource(ctx, ReadResourceParams(uri = "test://config"))
        @test isnothing(result.error)
        contents = result.response.result.contents[1]
        @test contents["uri"] == "test://config"
        @test contents["mimeType"] == "application/json"  # MCPResource default
        @test JSON3.read(contents["text"])["threshold"] == 42
    end

    @testset "resources/read unknown URI is a resource error" begin
        server = mcp_server(name = "test", version = "1.0.0")
        ctx = RequestContext(server = server, request_id = 1)
        result = handle_read_resource(ctx, ReadResourceParams(uri = "test://missing"))
        @test isnothing(result.response)
        @test result.error.code == Int(ModelContextProtocol.ErrorCodes.RESOURCE_NOT_FOUND)
    end

    @testset "resources/read with a throwing data_provider returns an error result" begin
        bad = MCPResource(
            uri = "test://broken",
            name = "broken",
            data_provider = () -> error("backend down"),
        )
        server = mcp_server(name = "test", version = "1.0.0", resources = [bad])
        ctx = RequestContext(server = server, request_id = 1)
        result = handle_read_resource(ctx, ReadResourceParams(uri = "test://broken"))
        @test isnothing(result.response)  # errors surface as JSON-RPC errors, not throws
        @test !isnothing(result.error)
    end
end

@testset "Resource Subscriptions" begin
    server = mcp_server(name = "test", version = "1.0.0")
    uri = "test://watched"
    cb1 = _ -> nothing
    cb2 = _ -> nothing

    # subscribe! registers callbacks per URI (and returns the server for chaining)
    @test subscribe!(server, uri, cb1) === server
    subscribe!(server, uri, cb2)
    @test length(server.subscriptions[uri]) == 2
    @test server.subscriptions[uri][1].uri == uri
    @test server.subscriptions[uri][1].callback === cb1

    # unsubscribe! removes exactly the matching callback
    @test unsubscribe!(server, uri, cb1) === server
    @test length(server.subscriptions[uri]) == 1
    @test server.subscriptions[uri][1].callback === cb2

    # unsubscribing an unknown callback is a no-op, not an error
    unsubscribe!(server, uri, _ -> nothing)
    @test length(server.subscriptions[uri]) == 1

    # unseen URIs read as empty (DefaultDict), no KeyError
    @test isempty(server.subscriptions["test://never-subscribed"])
end

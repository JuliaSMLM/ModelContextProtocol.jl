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

    @testset "resources/read serves ResourceContents returns directly" begin
        png = UInt8[0x89, 0x50, 0x4E, 0x47]
        text_res = MCPResource(
            uri = "test://report",
            name = "report",
            mime_type = "text/markdown",
            data_provider = () -> TextResourceContents(
                uri = "test://report",
                mime_type = "text/markdown",
                text = "# Report\nplain text, not JSON",
            ),
        )
        blob_res = MCPResource(
            uri = "test://logo",
            name = "logo",
            mime_type = "image/png",
            data_provider = () -> BlobResourceContents(
                uri = "test://logo",
                mime_type = "image/png",
                blob = png,
            ),
        )
        multi_res = MCPResource(
            uri = "test://bundle",
            name = "bundle",
            data_provider = () -> [
                TextResourceContents(uri = "test://bundle/readme", text = "readme"),
                BlobResourceContents(uri = "test://bundle/raw", mime_type = "image/png", blob = png),
            ],
        )
        server = mcp_server(name = "test", version = "1.0.0",
                            resources = [text_res, blob_res, multi_res])
        ctx = RequestContext(server = server, request_id = 1)

        # TextResourceContents: text verbatim (NOT JSON-quoted), struct's uri/mimeType
        c = handle_read_resource(ctx, ReadResourceParams(uri = "test://report")).response.result.contents[1]
        @test c["text"] == "# Report\nplain text, not JSON"
        @test c["mimeType"] == "text/markdown"
        @test c["uri"] == "test://report"
        @test !haskey(c, "blob")

        # BlobResourceContents: base64 blob, no text key — binary resources now servable
        c = handle_read_resource(ctx, ReadResourceParams(uri = "test://logo")).response.result.contents[1]
        @test c["blob"] == base64encode(png)
        @test c["mimeType"] == "image/png"
        @test !haskey(c, "text")

        # Vector of contents: one entry each, order preserved, per-entry uri
        cs = handle_read_resource(ctx, ReadResourceParams(uri = "test://bundle")).response.result.contents
        @test length(cs) == 2
        @test cs[1]["text"] == "readme" && cs[1]["uri"] == "test://bundle/readme"
        @test cs[2]["blob"] == base64encode(png) && cs[2]["uri"] == "test://bundle/raw"
    end

    @testset "resources/read String returns are verbatim text" begin
        plain = MCPResource(
            uri = "test://motd",
            name = "motd",
            mime_type = "text/plain",
            data_provider = () -> "hello, world",
        )
        server = mcp_server(name = "test", version = "1.0.0", resources = [plain])
        ctx = RequestContext(server = server, request_id = 1)
        c = handle_read_resource(ctx, ReadResourceParams(uri = "test://motd")).response.result.contents[1]
        @test c["text"] == "hello, world"        # not "\"hello, world\""
        @test c["mimeType"] == "text/plain"
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

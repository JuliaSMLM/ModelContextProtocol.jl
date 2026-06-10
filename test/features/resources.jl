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

    @testset "resources/read edge returns keep the JSON fallback" begin
        # custom ResourceContents subtypes are not wire types: JSON fallback, not an error
        struct _FakeContents <: ModelContextProtocol.ResourceContents end
        custom = MCPResource(uri = "test://custom", name = "custom",
                             data_provider = () -> _FakeContents())
        # empty vectors carry no usable contents: JSON fallback ("[]")
        empty_v = MCPResource(uri = "test://empty", name = "empty",
                              data_provider = () -> TextResourceContents[])
        server = mcp_server(name = "test", version = "1.0.0", resources = [custom, empty_v])
        ctx = RequestContext(server = server, request_id = 1)

        r1 = handle_read_resource(ctx, ReadResourceParams(uri = "test://custom"))
        @test isnothing(r1.error)
        @test haskey(r1.response.result.contents[1], "text")

        r2 = handle_read_resource(ctx, ReadResourceParams(uri = "test://empty"))
        @test r2.response.result.contents[1]["text"] == "[]"
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

    @testset "resource templates: matching, listing, read routing" begin
        # match_uri_template semantics
        @test match_uri_template("a://r/{id}", "a://r/x1") == Dict("id" => "x1")
        @test match_uri_template("a://{p}/{q}.png", "a://u/v.png") == Dict("p" => "u", "q" => "v")
        @test match_uri_template("a://r/{id}", "a://r/x/y") === nothing   # {var} won't cross '/'
        @test match_uri_template("a://r/{id}", "b://r/x") === nothing
        @test match_uri_template("a://r.x/{id}", "a://rqx/1") === nothing # literal '.' escaped
        @test match_uri_template("a://{a}{b}", "a://xy") === nothing      # adjacent vars: ambiguous, never match
        @test match_uri_template("a://{id}/{id}", "a://x/x") == Dict("id" => "x")  # repeats must agree
        @test match_uri_template("a://{id}/{id}", "a://x/y") === nothing

        png = UInt8[0x89, 0x50, 0x4E, 0x47]
        tmpl = ResourceTemplate(
            name = "artifact",
            uri_template = "test://artifact/{id}",
            description = "Content-addressed artifacts",
            mime_type = "image/png",
            data_provider = (uri, vars) -> BlobResourceContents(
                uri = uri, mime_type = "image/png",
                blob = vcat(png, Vector{UInt8}(vars["id"]))),
        )
        one_arg = ResourceTemplate(
            name = "echo",
            uri_template = "test://echo/{word}",
            mime_type = "text/plain",
            data_provider = uri -> "got: $uri",
        )
        bare = ResourceTemplate(name = "no-provider", uri_template = "test://bare/{x}")
        exact = MCPResource(uri = "test://artifact/special", name = "special",
                            mime_type = "text/plain", data_provider = () -> "exact wins")

        server = mcp_server(name = "test", version = "1.0.0",
                            resources = [exact],
                            resource_templates = [tmpl, one_arg, bare])
        ctx = RequestContext(server = server, request_id = 1)

        # templates/list wire shape
        lst = handle_list_resource_templates(ctx, ListResourceTemplatesParams())
        entries = lst.response.result["resourceTemplates"]
        @test length(entries) == 3
        e1 = only(filter(e -> e["name"] == "artifact", entries))
        @test e1["uriTemplate"] == "test://artifact/{id}"
        @test e1["mimeType"] == "image/png"
        @test e1["description"] == "Content-addressed artifacts"

        # two-arg provider receives extracted vars; blob through template
        c = handle_read_resource(ctx, ReadResourceParams(uri = "test://artifact/ab12")).response.result.contents[1]
        @test c["blob"] == base64encode(vcat(png, Vector{UInt8}("ab12")))
        @test c["uri"] == "test://artifact/ab12"
        @test c["mimeType"] == "image/png"

        # one-arg provider receives the requested uri; String verbatim
        c = handle_read_resource(ctx, ReadResourceParams(uri = "test://echo/hi")).response.result.contents[1]
        @test c["text"] == "got: test://echo/hi"
        @test c["mimeType"] == "text/plain"

        # exact-URI resources take precedence over matching templates
        c = handle_read_resource(ctx, ReadResourceParams(uri = "test://artifact/special")).response.result.contents[1]
        @test c["text"] == "exact wins"

        # provider-less templates are advertised but not readable
        r = handle_read_resource(ctx, ReadResourceParams(uri = "test://bare/zzz"))
        @test r.error.code == Int(ModelContextProtocol.ErrorCodes.RESOURCE_NOT_FOUND)

        # non-matching URIs still 404
        r = handle_read_resource(ctx, ReadResourceParams(uri = "test://nope/1"))
        @test r.error.code == Int(ModelContextProtocol.ErrorCodes.RESOURCE_NOT_FOUND)

        # provider errors surface as internal errors, not throws
        boom = ResourceTemplate(name = "boom", uri_template = "test://boom/{x}",
                                data_provider = uri -> error("nope"))
        register!(server, boom)
        r = handle_read_resource(ctx, ReadResourceParams(uri = "test://boom/1"))
        @test r.error.code == Int(ModelContextProtocol.ErrorCodes.INTERNAL_ERROR)

        # pre-0.5.4 six-field positional construction still works
        legacy = ResourceTemplate("legacy", "test://l/{x}", "text/plain", "d", nothing, nothing)
        @test legacy.data_provider === nothing && legacy._meta === nothing
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

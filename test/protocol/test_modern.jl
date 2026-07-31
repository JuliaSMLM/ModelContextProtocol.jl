@testset "Modern era (2026-07-28)" begin
    modern_meta(v = "2026-07-28") = Dict(
        "io.modelcontextprotocol/protocolVersion" => v,
        "io.modelcontextprotocol/clientCapabilities" => Dict(),
        "io.modelcontextprotocol/clientInfo" => Dict("name" => "modern-test-client", "version" => "1.0")
    )

    function modern_server()
        mcp_server(
            name = "modern-test",
            version = "1.0.0",
            description = "modern era tests",
            instructions = "Test instructions.",
            tools = [MCPTool(
                name = "echo",
                description = "Echo a message",
                parameters = [ToolParameter(name = "message", type = "string",
                                            description = "The message", required = true)],
                handler = args -> TextContent(text = args["message"]))],
            resources = [MCPResource(
                uri = "test://doc",
                name = "doc",
                description = "A text resource",
                mime_type = "text/plain",
                data_provider = () -> "resource body")]
        )
    end

    roundtrip(server, state, msg) = JSON3.read(process_message(server, state, JSON3.write(msg)))

    @testset "server/discover" begin
        server = modern_server()
        state = ServerState()
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 1, "method" => "server/discover",
            "params" => Dict("_meta" => modern_meta())))
        result = resp["result"]
        @test result["resultType"] == "complete"
        @test "2026-07-28" in result["supportedVersions"]
        @test "2025-11-25" in result["supportedVersions"]  # dual-era: legacy versions advertised too
        @test result["ttlMs"] isa Integer && result["ttlMs"] >= 0
        @test result["cacheScope"] in ("public", "private")
        @test result["instructions"] == "Test instructions."
        @test result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "modern-test"
        @test haskey(result["capabilities"], "tools")
        # Legacy-only capabilities are withheld from the modern era
        @test !haskey(result["capabilities"], "tasks")
        @test !haskey(result["capabilities"], "logging")
    end

    @testset "modern envelope on shared handlers" begin
        server = modern_server()
        state = ServerState()

        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 2, "method" => "tools/call",
            "params" => Dict("name" => "echo", "arguments" => Dict("message" => "hi"),
                             "_meta" => modern_meta())))
        @test resp["result"]["resultType"] == "complete"
        @test resp["result"]["content"][1]["text"] == "hi"
        @test haskey(resp["result"]["_meta"], "io.modelcontextprotocol/serverInfo")

        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 3, "method" => "resources/read",
            "params" => Dict("uri" => "test://doc", "_meta" => modern_meta())))
        @test resp["result"]["resultType"] == "complete"
        @test resp["result"]["contents"][1]["text"] == "resource body"

        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 4, "method" => "tools/list",
            "params" => Dict("_meta" => modern_meta())))
        @test resp["result"]["resultType"] == "complete"
        @test any(t -> t["name"] == "echo", resp["result"]["tools"])
    end

    @testset "validation errors" begin
        server = modern_server()
        state = ServerState()

        # Unsupported version -> -32022 with supported/requested data
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 5, "method" => "tools/list",
            "params" => Dict("_meta" => modern_meta("2099-01-01"))))
        @test resp["error"]["code"] == -32022
        @test resp["error"]["data"]["requested"] == "2099-01-01"
        @test "2026-07-28" in resp["error"]["data"]["supported"]
        @test "2024-11-05" in resp["error"]["data"]["supported"]

        # A legacy version in modern _meta is also unsupported for stateless use
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 6, "method" => "tools/list",
            "params" => Dict("_meta" => modern_meta("2025-11-25"))))
        @test resp["error"]["code"] == -32022

        # Missing clientCapabilities -> -32602 (required _meta field)
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 7, "method" => "tools/list",
            "params" => Dict("_meta" => Dict(
                "io.modelcontextprotocol/protocolVersion" => "2026-07-28"))))
        @test resp["error"]["code"] == -32602
    end

    @testset "methods removed from the modern era" begin
        server = modern_server()
        state = ServerState()
        # Well-formed requests (typed params parse) for methods the modern era does
        # not serve: each must answer METHOD_NOT_FOUND despite existing in legacy.
        removed = [
            ("ping", Dict{String,Any}()),
            ("logging/setLevel", Dict{String,Any}("level" => "debug")),
            ("resources/subscribe", Dict{String,Any}("uri" => "test://doc")),
            ("resources/unsubscribe", Dict{String,Any}("uri" => "test://doc")),
            ("tasks/list", Dict{String,Any}()),
            ("initialize", Dict{String,Any}(
                "protocolVersion" => "2025-11-25",
                "capabilities" => Dict{String,Any}(),
                "clientInfo" => Dict{String,Any}("name" => "x", "version" => "1"))),
        ]
        for (method, params) in removed
            params["_meta"] = modern_meta()
            resp = roundtrip(server, state, Dict(
                "jsonrpc" => "2.0", "id" => 8, "method" => method, "params" => params))
            @test resp["error"]["code"] == -32601
        end
    end

    @testset "dual-era isolation" begin
        server = modern_server()
        state = ServerState()

        # Legacy initialize negotiates and persists the session version
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 9, "method" => "initialize",
            "params" => Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(),
                             "clientInfo" => Dict("name" => "legacy", "version" => "1"))))
        @test resp["result"]["protocolVersion"] == "2025-06-18"
        @test !haskey(resp["result"], "resultType")  # legacy results carry no modern envelope
        @test state.protocol_version == "2025-06-18"

        # An interleaved modern request must not clobber the legacy session version
        roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 10, "method" => "tools/list",
            "params" => Dict("_meta" => modern_meta())))
        @test state.protocol_version == "2025-06-18"

        # Legacy requests still get legacy responses afterwards
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 11, "method" => "tools/list", "params" => Dict()))
        @test !haskey(resp["result"], "resultType")
    end

    @testset "modern task metadata is ignored (extension not advertised)" begin
        server = modern_server()
        ctx_modern = RequestContext(server = server, protocol_version = "2026-07-28")
        @test !ModelContextProtocol.tasks_supported(ctx_modern)

        # error-code remap: the reserved legacy -32002 must never appear on modern responses
        @test ModelContextProtocol.modernize_error_code(-32002) == -32602
        @test ModelContextProtocol.modernize_error_code(-32001) == -32001
    end

    @testset "log notifications suppressed for modern requests" begin
        server = modern_server()
        state = ServerState()
        out = IOBuffer()
        transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = out)
        server.transport = transport
        logger = MCPLogger(IOBuffer(), Logging.Info)
        logger.transport = transport
        logger.transport_active[] = true
        log_tool = MCPTool(name = "log_tool", description = "logs", parameters = [],
            handler = args -> begin
                @info "modern-suppression-probe"
                TextContent(text = "ok")
            end)
        push!(server.tools, log_tool)

        with_logger(logger) do
            # Modern request: the record must NOT be delivered over the transport
            process_message(server, state, JSON3.write(Dict(
                "jsonrpc" => "2.0", "id" => 12, "method" => "tools/call",
                "params" => Dict("name" => "log_tool", "arguments" => Dict(),
                                 "_meta" => modern_meta()))))
        end
        @test !occursin("modern-suppression-probe", String(take!(out)))

        with_logger(logger) do
            # Legacy request: delivery proceeds as usual
            process_message(server, state, JSON3.write(Dict(
                "jsonrpc" => "2.0", "id" => 13, "method" => "tools/call",
                "params" => Dict("name" => "log_tool", "arguments" => Dict()))))
        end
        legacy_out = String(take!(out))
        @test occursin("notifications/message", legacy_out)
        @test occursin("modern-suppression-probe", legacy_out)
    end
end

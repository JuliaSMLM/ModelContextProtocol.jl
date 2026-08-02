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

    # process_message leaves the log-suppression task-local armed after a modern
    # request (the real server loop re-arms it per message); reset it here so it
    # cannot leak into later testsets running in this same task
    roundtrip(server, state, msg) = begin
        r = JSON3.read(process_message(server, state, JSON3.write(msg)))
        task_local_storage(:mcp_suppress_log_notifications, false)
        r
    end

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
        # logging IS modern-era (per-request logLevel opt-in) and default servers
        # declare it — a MUST for servers that emit notifications/message
        @test haskey(result["capabilities"], "logging")
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

        # server/discover is modern-only, so it routes modern even without _meta:
        # a missing protocolVersion is a missing required field (-32602), not the
        # legacy era's -32601 Unknown method
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 71, "method" => "server/discover",
            "params" => Dict()))
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

        # error-code remap: legacy-range not-found codes become -32602 on modern
        # responses (-32002 is spec-reserved and MUST NOT be emitted at all)
        for legacy in (-32000, -32001, -32002, -32003)
            @test ModelContextProtocol.modernize_error_code(legacy) == -32602
        end
        @test ModelContextProtocol.modernize_error_code(-32603) == -32603

        # wire path: unknown tool on a modern request surfaces -32602, not -32001
        state = ServerState()
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 20, "method" => "tools/call",
            "params" => Dict("name" => "no_such_tool", "arguments" => Dict(),
                             "_meta" => modern_meta())))
        @test resp["error"]["code"] == -32602
    end

    @testset "CacheableResult fields on list/read results" begin
        server = modern_server()
        state = ServerState()
        for (method, params) in (
            ("tools/list", Dict{String,Any}()),
            ("prompts/list", Dict{String,Any}()),
            ("resources/list", Dict{String,Any}()),
            ("resources/templates/list", Dict{String,Any}()),
            ("resources/read", Dict{String,Any}("uri" => "test://doc")),
        )
            params["_meta"] = modern_meta()
            resp = roundtrip(server, state, Dict(
                "jsonrpc" => "2.0", "id" => 21, "method" => method, "params" => params))
            @test resp["result"]["ttlMs"] isa Integer && resp["result"]["ttlMs"] >= 0
            @test resp["result"]["cacheScope"] in ("public", "private")
        end

        # tools/call is NOT cacheable: no caching hints attached
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 22, "method" => "tools/call",
            "params" => Dict("name" => "echo", "arguments" => Dict("message" => "x"),
                             "_meta" => modern_meta())))
        @test !haskey(resp["result"], "ttlMs")
    end

    @testset "envelope preserves data fidelity (no lossy round-trip)" begin
        big = 9007199254740993  # 2^53 + 1: dies in a Float64 coercion
        server = mcp_server(name = "fidelity", version = "1.0.0",
            tools = [MCPTool(name = "bignum", description = "big int", parameters = [],
                handler = args -> CallToolResult(
                    content = [TextContent(text = "big")],
                    structured_content = Dict("value" => big),
                    _meta = Dict{String,Any}("trace" => "keep-me")))])
        state = ServerState()
        out = process_message(server, state, JSON3.write(Dict(
            "jsonrpc" => "2.0", "id" => 23, "method" => "tools/call",
            "params" => Dict("name" => "bignum", "arguments" => Dict(),
                             "_meta" => modern_meta()))))
        task_local_storage(:mcp_suppress_log_notifications, false)
        # Assert on the raw wire text: the exact integer must appear undamaged
        @test occursin(string(big), out)
        resp = JSON3.read(out)
        @test resp["result"]["structuredContent"]["value"] == big
        # handler _meta merged, not replaced
        @test resp["result"]["_meta"]["trace"] == "keep-me"
        @test haskey(resp["result"]["_meta"], "io.modelcontextprotocol/serverInfo")
        @test resp["result"]["isError"] == false
    end

    @testset "capability gating of the modern surface" begin
        # A server declaring only tools must answer -32601 for resources/prompts
        # methods: the advertised capability set and callable surface must agree.
        server = mcp_server(name = "tools-only", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[ModelContextProtocol.ToolCapability()],
            tools = [MCPTool(name = "t", description = "t", parameters = [],
                handler = args -> TextContent(text = "t"))])
        state = ServerState()
        for method in ("resources/list", "prompts/list")
            resp = roundtrip(server, state, Dict(
                "jsonrpc" => "2.0", "id" => 24, "method" => method,
                "params" => Dict("_meta" => modern_meta())))
            @test resp["error"]["code"] == -32601
        end
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 25, "method" => "tools/list",
            "params" => Dict("_meta" => modern_meta())))
        @test haskey(resp, "result")
        # discover reflects the same reduced surface, presence-only objects
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 26, "method" => "server/discover",
            "params" => Dict("_meta" => modern_meta())))
        caps = resp["result"]["capabilities"]
        @test haskey(caps, "tools") && isempty(caps["tools"])
        @test !haskey(caps, "resources") && !haskey(caps, "prompts")
    end

    @testset "malformed _meta robustness" begin
        server = modern_server()
        state = ServerState()

        # _meta: null / non-object -> not modern, no crash: served as legacy
        for weird in (nothing, [1, 2], "junk")
            resp = roundtrip(server, state, Dict(
                "jsonrpc" => "2.0", "id" => 27, "method" => "tools/list",
                "params" => Dict("_meta" => weird)))
            @test haskey(resp, "result")  # legacy tools/list, no -32603
        end

        # Non-string protocolVersion -> treated as absent -> legacy
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 28, "method" => "tools/list",
            "params" => Dict("_meta" => Dict(
                "io.modelcontextprotocol/protocolVersion" => 2026,
                "io.modelcontextprotocol/clientCapabilities" => Dict()))))
        @test haskey(resp, "result")
        @test !haskey(resp["result"], "resultType")

        # Non-object clientCapabilities -> missing required field -> -32602
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 29, "method" => "tools/list",
            "params" => Dict("_meta" => Dict(
                "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities" => [1, 2]))))
        @test resp["error"]["code"] == -32602

        # Malformed typed params on a modern request -> -32602, not -32603
        resp = roundtrip(server, state, Dict(
            "jsonrpc" => "2.0", "id" => 30, "method" => "tools/call",
            "params" => Dict("_meta" => modern_meta())))  # no tool name
        @test resp["error"]["code"] == -32602
    end

    @testset "log notifications suppressed for modern requests" begin
        server = modern_server()
        state = ServerState()
        out = IOBuffer()
        transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = out)
        server.transport = transport
        # Debug-level logger: the worst case — a legacy client enabled debug
        # delivery, so even the request-lifecycle @debug records are live and
        # must still not reach an interleaved modern request's client.
        logger = MCPLogger(IOBuffer(), Logging.Debug)
        logger.transport = transport
        logger.transport_active[] = true
        log_tool = MCPTool(name = "log_tool", description = "logs", parameters = [],
            handler = args -> begin
                @info "modern-suppression-probe"
                TextContent(text = "ok")
            end)
        push!(server.tools, log_tool)

        # Mimic the server loop's per-message re-arm: suppression defaults ON and
        # process_message flips it off only once the message resolves as legacy
        run_msg(msg) = begin
            task_local_storage(:mcp_suppress_log_notifications, true)
            with_logger(logger) do
                process_message(server, state, JSON3.write(msg))
            end
            task_local_storage(:mcp_suppress_log_notifications, false)
        end

        # Modern request: nothing — not the handler @info, not lifecycle @debug —
        # may be delivered over the transport
        run_msg(Dict(
            "jsonrpc" => "2.0", "id" => 12, "method" => "tools/call",
            "params" => Dict("name" => "log_tool", "arguments" => Dict(),
                             "_meta" => modern_meta())))
        modern_out = String(take!(out))
        @test !occursin("modern-suppression-probe", modern_out)
        @test !occursin("notifications/message", modern_out)

        # Legacy request: delivery proceeds as usual (incl. debug lifecycle lines)
        run_msg(Dict(
            "jsonrpc" => "2.0", "id" => 13, "method" => "tools/call",
            "params" => Dict("name" => "log_tool", "arguments" => Dict())))
        legacy_out = String(take!(out))
        @test occursin("notifications/message", legacy_out)
        @test occursin("modern-suppression-probe", legacy_out)
    end

    @testset "per-request logLevel (modern logging opt-in)" begin
        meta_with_level(level) = begin
            m = modern_meta()
            m["io.modelcontextprotocol/logLevel"] = level
            m
        end

        function loglevel_server()
            server = modern_server()
            log_tool = MCPTool(name = "log_tool", description = "logs", parameters = [],
                handler = args -> begin
                    @info "loglevel-info-probe"
                    @warn "loglevel-warn-probe"
                    TextContent(text = "ok")
                end)
            push!(server.tools, log_tool)
            server
        end

        # Wire an in-memory stdio transport + live MCPLogger, mimic the server
        # loop's per-message arm/clear of the log task-locals, and return
        # (transport output, fallback-stream output, parsed response-or-nothing)
        function run_logged(server, msg; min_level = Logging.Info)
            out = IOBuffer()
            fallback = IOBuffer()
            transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = out)
            server.transport = transport
            logger = MCPLogger(fallback, min_level)
            logger.transport = transport
            logger.transport_active[] = true
            state = ServerState()
            task_local_storage(:mcp_suppress_log_notifications, true)
            task_local_storage(:mcp_request_log_level, nothing)
            raw = try
                with_logger(logger) do
                    process_message(server, state, JSON3.write(msg))
                end
            finally
                task_local_storage(:mcp_request_log_level, nothing)
                task_local_storage(:mcp_suppress_log_notifications, false)
            end
            (String(take!(out)), String(take!(fallback)),
             raw === nothing ? nothing : JSON3.read(raw))
        end

        call_log_tool(level; id = 20) = Dict(
            "jsonrpc" => "2.0", "id" => id, "method" => "tools/call",
            "params" => Dict("name" => "log_tool", "arguments" => Dict(),
                             "_meta" => level === nothing ? modern_meta() : meta_with_level(level)))

        # Invalid level values -> -32602 (present-but-invalid is rejected, never
        # treated as absent)
        server = loglevel_server()
        state = ServerState()
        for bad in ("verbose", 3, true)
            m = modern_meta()
            m["io.modelcontextprotocol/logLevel"] = bad
            resp = roundtrip(server, state, Dict(
                "jsonrpc" => "2.0", "id" => 21, "method" => "tools/call",
                "params" => Dict("name" => "log_tool", "arguments" => Dict(), "_meta" => m)))
            @test resp["error"]["code"] == -32602
            @test occursin("logLevel", resp["error"]["message"])
        end

        # Opt-in at "info": both probes delivered as notifications/message on the
        # request's stream, and the response still completes
        transport_out, fallback_out, resp = run_logged(loglevel_server(), call_log_tool("info"))
        @test resp["result"]["resultType"] == "complete"
        @test occursin("notifications/message", transport_out)
        @test occursin("loglevel-info-probe", transport_out)
        @test occursin("loglevel-warn-probe", transport_out)

        # Severity filter: "error" excludes both info and warning records
        transport_out, _, resp = run_logged(loglevel_server(), call_log_tool("error"))
        @test resp["result"]["resultType"] == "complete"
        @test !occursin("notifications/message", transport_out)

        # "notice" excludes info but admits warning (RFC-5424 ordering)
        transport_out, _, _ = run_logged(loglevel_server(), call_log_tool("notice"))
        @test !occursin("loglevel-info-probe", transport_out)
        @test occursin("loglevel-warn-probe", transport_out)

        # "debug" lowers the effective enablement below the operator's min_level:
        # lifecycle @debug records reach the client but stay OFF the operator's
        # fallback stream
        transport_out, fallback_out, _ = run_logged(loglevel_server(), call_log_tool("debug");
                                                    min_level = Logging.Info)
        @test occursin("request completed", transport_out)
        @test !occursin("request completed", fallback_out)

        # No opt-in -> no delivery (the pre-existing suppression), same server
        transport_out, _, _ = run_logged(loglevel_server(), call_log_tool(nothing))
        @test !occursin("notifications/message", transport_out)

        # A server without the logging capability accepts the level but emits
        # nothing (capability declaration is a MUST for emitters)
        quiet = loglevel_server()
        filter!(c -> !(c isa ModelContextProtocol.LoggingCapability), quiet.config.capabilities)
        transport_out, _, resp = run_logged(quiet, call_log_tool("debug"))
        @test resp["result"]["resultType"] == "complete"
        @test !occursin("notifications/message", transport_out)

        # discover withholds logging when the capability is not declared
        resp = roundtrip(quiet, ServerState(), Dict(
            "jsonrpc" => "2.0", "id" => 22, "method" => "server/discover",
            "params" => Dict("_meta" => modern_meta())))
        @test !haskey(resp["result"]["capabilities"], "logging")

        # subscriptions/listen never honors the opt-in: its response stream IS the
        # subscription stream. The request defers (no immediate response) and the
        # per-request level must NOT have been applied.
        listen_server = loglevel_server()
        listen_server.transport = ModelContextProtocol.StdioTransport(
            input = IOBuffer(), output = IOBuffer())
        listen_state = ServerState()
        task_local_storage(:mcp_suppress_log_notifications, true)
        task_local_storage(:mcp_request_log_level, nothing)
        listen_msg = Dict(
            "jsonrpc" => "2.0", "id" => 23, "method" => "subscriptions/listen",
            "params" => Dict("notifications" => Dict("toolsListChanged" => true),
                             "_meta" => meta_with_level("debug")))
        raw = process_message(listen_server, listen_state, JSON3.write(listen_msg))
        @test raw === nothing  # deferred: the stream is served out-of-loop
        @test task_local_storage(:mcp_request_log_level) === nothing
        @test task_local_storage(:mcp_suppress_log_notifications) === true
        task_local_storage(:mcp_suppress_log_notifications, false)
    end
end

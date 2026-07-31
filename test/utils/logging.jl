@testset "Logging" begin
    # Test MCP logger
    buf = IOBuffer()
    logger = MCPLogger(buf)

    with_logger(logger) do
        @info "Test message"
    end

    log_output = String(take!(buf))
    @test occursin("notifications/message", log_output)
    @test occursin("test message", lowercase(log_output))
end

@testset "logging/setLevel" begin
    @testset "level mapping" begin
        m = ModelContextProtocol.mcp_level_to_julia
        @test m("debug") == Logging.Debug
        @test m("info") == Logging.Info
        @test m("notice") == Logging.Info
        @test m("warning") == Logging.Warn
        for lvl in ("error", "critical", "alert", "emergency")
            @test m(lvl) == Logging.Error
        end
    end

    @testset "setLevel adjusts the installed MCPLogger" begin
        server = mcp_server(name = "test", version = "1.0.0")
        ctx = RequestContext(server = server, request_id = 1)
        mcp_logger = MCPLogger(IOBuffer(), Logging.Info)
        old_logger = Logging.global_logger(mcp_logger)
        try
            result = ModelContextProtocol.handle_set_level(
                ctx, ModelContextProtocol.SetLevelParams(level = "debug"))
            @test isnothing(result.error)
            @test isempty(result.response.result)
            @test mcp_logger.min_level == Logging.Debug

            # The change must actually take effect for log macros: global_logger caches
            # min_enabled_level at install time, so the handler has to re-install the
            # logger (a field mutation alone is silently ignored by @debug's early-out)
            @debug "post-setlevel probe"
            @test occursin("post-setlevel probe", String(take!(mcp_logger.stream)))

            ModelContextProtocol.handle_set_level(
                ctx, ModelContextProtocol.SetLevelParams(level = "emergency"))
            @test mcp_logger.min_level == Logging.Error
            @info "suppressed probe"  # below emergency->Error threshold
            @test !occursin("suppressed probe", String(take!(mcp_logger.stream)))
        finally
            Logging.global_logger(old_logger)
        end
    end

    @testset "invalid level is INVALID_PARAMS" begin
        server = mcp_server(name = "test", version = "1.0.0")
        ctx = RequestContext(server = server, request_id = 1)
        result = ModelContextProtocol.handle_set_level(
            ctx, ModelContextProtocol.SetLevelParams(level = "verbose"))
        @test isnothing(result.response)
        @test result.error.code == Int(ModelContextProtocol.ErrorCodes.INVALID_PARAMS)
    end

    @testset "routed end-to-end through process_message" begin
        server = mcp_server(name = "test", version = "1.0.0")
        state = ServerState()
        raw = """{"jsonrpc":"2.0","method":"logging/setLevel","params":{"level":"warning"},"id":9}"""
        response = JSON3.read(process_message(server, state, raw))
        @test response["id"] == 9
        @test haskey(response, "result")
    end

    @testset "logging capability advertised by default" begin
        server = mcp_server(name = "test", version = "1.0.0")
        ctx = RequestContext(server = server, request_id = 1)
        init = handle_initialize(ctx, InitializeParams(
            capabilities = ClientCapabilities(),
            clientInfo = Implementation(),
            protocolVersion = "2025-11-25"))
        @test haskey(init.response.result.capabilities, "logging")
    end

    @testset "request-lifecycle debug log" begin
        server = mcp_server(name = "test", version = "1.0.0")
        state = ServerState()
        raw = """{"jsonrpc":"2.0","method":"ping","id":3}"""
        @test_logs (:debug, "request completed") match_mode=:any min_level=Logging.Debug begin
            process_message(server, state, raw)
        end
    end
end

@testset "log notifications route through the transport" begin
    # Once the client initializes (transport_active), log records must reach it as
    # notifications/message via send_notification — for stdio that means stdout, the
    # stream responses share — rather than being printed to the fallback stream.
    out = IOBuffer()
    fallback = IOBuffer()
    transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = out)
    logger = MCPLogger(fallback, Logging.Info)
    logger.transport = transport

    # Before initialization: fallback stream only, nothing on the transport
    with_logger(logger) do
        @info "pre-init probe"
    end
    @test occursin("pre-init probe", String(take!(fallback)))
    @test isempty(String(take!(out)))

    # After initialization: the notification goes over the transport, not the fallback
    logger.transport_active[] = true
    with_logger(logger) do
        @info "routed probe"
    end
    routed = String(take!(out))
    @test occursin("notifications/message", routed)
    @test occursin("routed probe", routed)
    @test isempty(String(take!(fallback)))

    # Below-Info records map to the MCP "debug" level on the wire
    logger.min_level = Logging.Debug
    with_logger(logger) do
        @debug "debug probe"
    end
    debug_out = String(take!(out))
    @test occursin("\"level\":\"debug\"", debug_out)

    # Disconnected transport falls back to the stream
    transport.connected = false
    with_logger(logger) do
        @info "fallback probe"
    end
    @test occursin("fallback probe", String(take!(fallback)))
    @test isempty(String(take!(out)))
end

@testset "logger recursion and cross-server activation" begin
    # A log record emitted while another record is being handled (e.g. a user show()
    # method that logs, or the transport send path logging) must not recurse: the
    # entry guard replaces the inner record with a minimal fixed fallback line.
    fallback = IOBuffer()
    logger = MCPLogger(fallback, Logging.Info)
    task_local_storage(:mcp_logger_reentry, true)  # simulate being inside handle_message
    try
        with_logger(logger) do
            @info "inner record"
        end
    finally
        task_local_storage(:mcp_logger_reentry, false)
    end
    text = String(take!(fallback))
    @test occursin("recursive log record suppressed", text)
    @test !occursin("inner record", text)  # not formatted, not delivered

    # ...and with the guard clear, the same record goes through normally.
    with_logger(logger) do
        @info "normal record"
    end
    @test occursin("normal record", String(take!(fallback)))

    # Initializing server A must not activate a logger wired to server B's transport.
    server = mcp_server(name = "activation-test", version = "1.0.0")
    server.transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = IOBuffer())
    other_transport = ModelContextProtocol.StdioTransport(input = IOBuffer(), output = IOBuffer())
    foreign_logger = MCPLogger(IOBuffer(), Logging.Info)
    foreign_logger.transport = other_transport
    old_logger = Logging.global_logger(foreign_logger)
    try
        ctx = RequestContext(server = server, request_id = 1)
        ModelContextProtocol.handle_initialize(ctx, InitializeParams(
            capabilities = ClientCapabilities(),
            clientInfo = Implementation(),
            protocolVersion = "2025-11-25"))
        @test foreign_logger.transport_active[] == false  # foreign logger untouched

        # Same logger wired to THIS server's transport does activate
        own_logger = MCPLogger(IOBuffer(), Logging.Info)
        own_logger.transport = server.transport
        Logging.global_logger(own_logger)
        ModelContextProtocol.handle_initialize(ctx, InitializeParams(
            capabilities = ClientCapabilities(),
            clientInfo = Implementation(),
            protocolVersion = "2025-11-25"))
        @test own_logger.transport_active[] == true
    finally
        Logging.global_logger(old_logger)
    end
end
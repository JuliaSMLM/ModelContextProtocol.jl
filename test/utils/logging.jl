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

            ModelContextProtocol.handle_set_level(
                ctx, ModelContextProtocol.SetLevelParams(level = "emergency"))
            @test mcp_logger.min_level == Logging.Error
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
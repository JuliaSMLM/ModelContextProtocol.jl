@testset "Request Handling" begin
    server = Server(ServerConfig(name="test"))
    state = ServerState()
    ctx = RequestContext(server=server, state=state)

    # Test initialize request handling
    init_params = InitializeParams(
        capabilities=ClientCapabilities(),
        clientInfo=Implementation(),
        protocolVersion="1.0"
    )
    ctx = RequestContext(server=server, state=state, request_id=1)  # Set a valid request ID
    result = handle_initialize(ctx, init_params)
    @test result isa HandlerResult
    @test !isnothing(result.response)
    @test result.response.id == 1

    # Test list resources handling
    list_params = ListResourcesParams()
    result = handle_list_resources(ctx, list_params)
    @test result isa HandlerResult
    @test !isnothing(result.response)

    # Ping requests
    ctx = RequestContext(server=server, state=state, request_id=2)
    result = handle_ping(ctx, nothing)
    @test result isa HandlerResult
    @test !isnothing(result.response)
    @test result.response.id == 2
    @test isempty(result.response.result)
end

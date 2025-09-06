@testset "Error Handling" begin
    # Test resource not found error
    server = Server(ServerConfig(name="test"))
    ctx = RequestContext(server=server)
    result = handle_read_resource(ctx, ReadResourceParams(uri="invalid://uri"))
    @test result.error.code == -32000  # RESOURCE_NOT_FOUND

    # Test invalid params error
    result = handle_get_prompt(ctx, GetPromptParams(name="non-existent"))
    @test result.error.code == -32003  # PROMPT_NOT_FOUND
end

@testset "Integration Tests" begin
    # Create a server with all components
    config = ServerConfig(
        name="test-server",
        version="1.0.0",
        capabilities=[
            ResourceCapability(list_changed=true, subscribe=true),
            ToolCapability(list_changed=true),
            PromptCapability(list_changed=true)
        ]
    )

    test_resource = MCPResource(
        uri=URI("test://example"),
        name="test-resource",
        description="Test resource",
        mime_type="text/plain",
        data_provider=() -> "test data"
    )

    test_tool = MCPTool(
        name="test-tool",
        description="Test tool",
        parameters=[ToolParameter(name="param1", description="Test param", type="string", required=true)],
        handler=args -> "Test response: $(args["param1"])",
        return_type=TextContent  # Explicitly specify return type
    )

    test_prompt = MCPPrompt(
        name="test-prompt",
        description="A test prompt",
        arguments=[PromptArgument(name="arg1", description="Test arg", required=true)],
        messages=[PromptMessage(
            content=TextContent(type="text", text="Test prompt with {arg1}"),
            role=ModelContextProtocol.user
        )]
    )

    server = Server(config)
    register!(server, test_resource)
    register!(server, test_tool)
    register!(server, test_prompt)

    # Test full initialization sequence
    init_req = JSONRPCRequest(
        id=1,
        method="initialize",
        params=InitializeParams(
            capabilities=ClientCapabilities(),
            clientInfo=Implementation(name="test-client"),
            protocolVersion="2025-06-18"
        )
    )

    ctx = RequestContext(server=server, request_id=init_req.id)
    result = handle_initialize(ctx, init_req.params)

    @test result isa HandlerResult
    @test !isnothing(result.response)
    @test result.response.result isa InitializeResult
    @test haskey(result.response.result.capabilities, "resources")

    # Test resource reading
    read_req = JSONRPCRequest(
        id=2,
        method="resources/read",
        params=ReadResourceParams(uri="test://example")
    )

    ctx = RequestContext(server=server, request_id=read_req.id)
    result = handle_read_resource(ctx, read_req.params)

    @test result isa HandlerResult
    @test !isnothing(result.response)
    @test result.response.result isa ReadResourceResult
end
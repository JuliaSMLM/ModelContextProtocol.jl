@testset "Template Processing" begin
    # Create and configure server first
    test_prompt = MCPPrompt(
        name="test-prompt",
        description="A test prompt",
        arguments=[PromptArgument(name="arg1", description="Test arg", required=true)],
        messages=[PromptMessage(
            content=TextContent(type="text", text="Test prompt with {arg1}"),
            role=ModelContextProtocol.user
        )]
    )

    server = Server(ServerConfig(name="test"))
    state = ServerState()
    register!(server, test_prompt)  # Register the test prompt

    @test test_prompt.messages[1].content.text == "Test prompt with {arg1}"

    # Test prompt template with arguments
    args = Dict("arg1" => "World")
    ctx = RequestContext(server=server, state=state, request_id=1)
    result = handle_get_prompt(ctx, GetPromptParams(name="test-prompt", arguments=args))
    
    @test result isa HandlerResult
    @test !isnothing(result.response)
    @test result.response isa JSONRPCResponse
    @test result.response.result isa GetPromptResult
    @test result.response.result.messages[1].content.text == "Test prompt with World"
end
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
    register!(server, test_prompt)  # Register the test prompt
    
    @test test_prompt.messages[1].content.text == "Test prompt with {arg1}"
    
    # Test prompt template with arguments
    args = Dict("arg1" => "World")
    ctx = RequestContext(server=server, request_id=1)
    result = handle_get_prompt(ctx, GetPromptParams(name="test-prompt", arguments=args))
    
    @test result isa HandlerResult
    @test !isnothing(result.response)
    @test result.response isa JSONRPCResponse
    @test result.response.result["messages"][1]["role"] == "user"
    @test result.response.result["messages"][1]["content"]["text"] == "Test prompt with World"
end

@testset "prompts/get media content uses spec wire format" begin
    audio = AudioContent(data = [0x52, 0x49, 0x46, 0x46], mime_type = "audio/wav")
    image = ImageContent(data = [0x89, 0x50], mime_type = "image/png")
    link = ResourceLink(uri = "file:///data/run42.tif", name = "run42.tif", size = 1024)
    prompt = MCPPrompt(
        name = "media-prompt",
        description = "Prompt with media content",
        messages = [
            PromptMessage(content = audio),
            PromptMessage(content = image, role = ModelContextProtocol.assistant),
            PromptMessage(content = link),
        ]
    )
    server = Server(ServerConfig(name = "test"))
    register!(server, prompt)
    ctx = RequestContext(server = server, request_id = 1)
    result = handle_get_prompt(ctx, GetPromptParams(name = "media-prompt"))
    messages = result.response.result["messages"]

    # Audio: base64 data + mimeType (not raw bytes / mime_type)
    @test messages[1]["content"]["type"] == "audio"
    @test messages[1]["content"]["data"] == base64encode([0x52, 0x49, 0x46, 0x46])
    @test messages[1]["content"]["mimeType"] == "audio/wav"
    @test !haskey(messages[1]["content"], "mime_type")

    # Image: same spec shape, assistant role serialized as string
    @test messages[2]["role"] == "assistant"
    @test messages[2]["content"]["data"] == base64encode([0x89, 0x50])
    @test messages[2]["content"]["mimeType"] == "image/png"

    # ResourceLink is valid prompt content and carries size
    @test messages[3]["content"]["type"] == "resource_link"
    @test messages[3]["content"]["uri"] == "file:///data/run42.tif"
    @test messages[3]["content"]["size"] == 1024
end
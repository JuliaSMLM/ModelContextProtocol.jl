@testset "Null Parameters Handling" begin
    # Create a simple server with a tool
    test_tool = MCPTool(
        name = "test_tool",
        description = "Test tool",
        parameters = [],
        handler = (args) -> TextContent(text = "Test response"),
        return_type = TextContent
    )
    
    server = mcp_server(
        name = "null-params-test",
        version = "1.0.0",
        description = "Test null parameters",
        tools = [test_tool]
    )
    state = ServerState()

    # Create a request context
    ctx = ModelContextProtocol.RequestContext(
        server = server,
        state = state,
        request_id = 1
    )
    
    # Test tools/list with null params (like Cursor sends)
    @testset "tools/list with null params" begin
        # Simulate what happens when params is nothing
        params = nothing
        actual_params = isnothing(params) ? ModelContextProtocol.ListToolsParams() : params::ModelContextProtocol.ListToolsParams
        
        result = ModelContextProtocol.handle_list_tools(ctx, actual_params)
        @test !isnothing(result.response)
        @test isnothing(result.error)
        
        # Check the response contains our tool
        tools = result.response.result["tools"]
        @test length(tools) == 1
        @test tools[1]["name"] == "test_tool"
    end
    
    # Test resources/list with null params
    @testset "resources/list with null params" begin
        params = nothing
        actual_params = isnothing(params) ? ModelContextProtocol.ListResourcesParams() : params::ModelContextProtocol.ListResourcesParams
        
        result = ModelContextProtocol.handle_list_resources(ctx, actual_params)
        @test !isnothing(result.response)
        @test isnothing(result.error)
    end
    
    # Test prompts/list with null params
    @testset "prompts/list with null params" begin
        params = nothing
        actual_params = isnothing(params) ? ModelContextProtocol.ListPromptsParams() : params::ModelContextProtocol.ListPromptsParams
        
        result = ModelContextProtocol.handle_list_prompts(ctx, actual_params)
        @test !isnothing(result.response)
        @test isnothing(result.error)
    end
end
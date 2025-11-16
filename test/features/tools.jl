@testset "Multi-Content Tool Tests" begin
    # Test tool that returns a single content item but expects it wrapped in a vector
    single_tool = MCPTool(
        name = "single_content",
        description = "Returns single content",
        parameters = [],
        handler = (args) -> TextContent(text = "Single response"),
        return_type = Vector{Content}  # Explicitly expect vector
    )
    
    # Test tool that returns multiple content items
    multi_tool = MCPTool(
        name = "multi_content", 
        description = "Returns multiple content items",
        parameters = [],
        handler = (args) -> [
            TextContent(text = "First item"),
            ImageContent(data = Vector{UInt8}([0x00]), mime_type = "image/png"),
            TextContent(text = "Third item")
        ],
        return_type = Vector{Content}  # Explicitly expect vector
    )
    
    # Test tool with mixed return types
    mixed_tool = MCPTool(
        name = "mixed_content",
        description = "Can return single or multiple items",
        parameters = [
            ToolParameter(name = "count", description = "Number of items to return", type = "number", required = true)
        ],
        handler = function(params)
            count = params["count"]
            if count == 1
                return TextContent(text = "Single item")
            else
                return [TextContent(text = "Item $i") for i in 1:count]
            end
        end,
        return_type = Union{TextContent, Vector{Content}}  # Explicitly handle both types
    )
    
    # Create a test server
    server = mcp_server(
        name = "test-server",
        version = "1.0.0",
        description = "Test server for multi-content tools",
        tools = [single_tool, multi_tool, mixed_tool]
    )
    
    # Create request context
    ctx = ModelContextProtocol.RequestContext(
        server = server,
        request_id = "test-1"
    )
    
    @testset "Single content return" begin
        params = ModelContextProtocol.CallToolParams(
            name = "single_content",
            arguments = nothing
        )
        
        result = ModelContextProtocol.handle_call_tool(ctx, params)
        @test !isnothing(result.response)
        @test isnothing(result.error)
        
        content = result.response.result.content
        @test length(content) == 1
        @test content[1]["type"] == "text"
        @test content[1]["text"] == "Single response"
    end
    
    @testset "Multiple content return" begin
        params = ModelContextProtocol.CallToolParams(
            name = "multi_content",
            arguments = nothing
        )
        
        result = ModelContextProtocol.handle_call_tool(ctx, params)
        @test !isnothing(result.response)
        @test isnothing(result.error)
        
        content = result.response.result.content
        @test length(content) == 3
        @test content[1]["type"] == "text"
        @test content[1]["text"] == "First item"
        @test content[2]["type"] == "image"
        @test content[2]["mimeType"] == "image/png"
        @test content[3]["type"] == "text"
        @test content[3]["text"] == "Third item"

        @test contains(JSON3.write(result.response.result), "Third item")
        @test contains(JSON3.write(result.response.result), "image/png")
    end
    
    @testset "Mixed return types" begin
        # Test single return
        params = ModelContextProtocol.CallToolParams(
            name = "mixed_content",
            arguments = Dict("count" => 1)
        )
        
        result = ModelContextProtocol.handle_call_tool(ctx, params)
        @test !isnothing(result.response)
        content = result.response.result.content
        @test length(content) == 1
        @test content[1]["text"] == "Single item"
        
        # Test multiple return
        params = ModelContextProtocol.CallToolParams(
            name = "mixed_content",
            arguments = Dict("count" => 3)
        )
        
        result = ModelContextProtocol.handle_call_tool(ctx, params)
        @test !isnothing(result.response)
        content = result.response.result.content
        @test length(content) == 3
        @test all(c["type"] == "text" for c in content)
        @test content[2]["text"] == "Item 2"
    end
    
    @testset "Content with embedded resources" begin
        resource_tool = MCPTool(
            name = "resource_content",
            description = "Returns content with embedded resource",
            parameters = [],
            handler = (args) -> [
                TextContent(text = "Here's a resource:"),
                EmbeddedResource(
                    resource = Dict{String,Any}(
                        "uri" => "test://resource",
                        "text" => "Resource data",
                        "mime_type" => "text/plain"
                    ),
                    annotations = Dict{String,Any}("priority" => "high")
                )
            ],
            return_type = Vector{Content}
        )
        
        server.tools = push!(server.tools, resource_tool)
        
        params = ModelContextProtocol.CallToolParams(
            name = "resource_content",
            arguments = nothing
        )
        
        result = ModelContextProtocol.handle_call_tool(ctx, params)
        @test !isnothing(result.response)
        
        content = result.response.result.content
        @test length(content) == 2
        @test content[1]["type"] == "text"
        @test content[2]["type"] == "resource"
        @test content[2]["resource"]["uri"] == "test://resource"
        @test content[2]["resource"]["text"] == "Resource data"
        @test content[2]["annotations"]["priority"] == "high"
    end
end

@testset "CallToolResult return type" begin
    # Create a server with tools that return CallToolResult directly
    config = ServerConfig(
        name = "test-server",
        version = "1.0.0"
    )
    server = Server(config)
    
    # Register tools
    tools = [
            # Tool that returns success CallToolResult
            MCPTool(
                name = "success_tool",
                description = "Returns a successful CallToolResult",
                parameters = [
                    ToolParameter(
                        name = "message",
                        description = "Message to return",
                        type = "string"
                    )
                ],
                handler = function(params)
                    msg = get(params, "message", "Success!")
                    CallToolResult(
                        content = [LittleDict{String,Any}(
                            "type" => "text",
                            "text" => msg
                        )],
                        is_error = false
                    )
                end
            ),
            
            # Tool that returns error CallToolResult
            MCPTool(
                name = "error_tool",
                description = "Returns an error CallToolResult",
                parameters = [],
                handler = function(params)
                    CallToolResult(
                        content = [LittleDict{String,Any}(
                            "type" => "text",
                            "text" => "An error occurred"
                        )],
                        is_error = true
                    )
                end
            ),
            
            # Tool that returns CallToolResult with multiple content items
            MCPTool(
                name = "multi_content_tool",
                description = "Returns CallToolResult with multiple content items",
                parameters = [],
                handler = function(params)
                    CallToolResult(
                        content = [
                            LittleDict{String,Any}(
                                "type" => "text",
                                "text" => "First item"
                            ),
                            LittleDict{String,Any}(
                                "type" => "text",
                                "text" => "Second item"
                            ),
                            LittleDict{String,Any}(
                                "type" => "image",
                                "data" => base64encode([0x89, 0x50, 0x4E, 0x47]),
                                "mimeType" => "image/png"
                            )
                        ],
                        is_error = false
                    )
                end
            )
        ]
    
    # Register all tools
    for tool in tools
        register!(server, tool)
    end
    
    @testset "Success CallToolResult" begin
        ctx = RequestContext(
            server = server,
            request_id = 1
        )
        
        params = CallToolParams(
            name = "success_tool",
            arguments = LittleDict{String,Any}("message" => "Hello from test!")
        )
        
        result = handle_call_tool(ctx, params)
        
        @test !isnothing(result.response)
        @test isnothing(result.error)
        @test result.response.result isa CallToolResult
        @test result.response.result.is_error == false
        @test length(result.response.result.content) == 1
        @test result.response.result.content[1]["type"] == "text"
        @test result.response.result.content[1]["text"] == "Hello from test!"
    end
    
    @testset "Error CallToolResult" begin
        ctx = RequestContext(
            server = server,
            request_id = 2
        )
        
        params = CallToolParams(
            name = "error_tool",
            arguments = nothing
        )
        
        result = handle_call_tool(ctx, params)
        
        @test !isnothing(result.response)
        @test isnothing(result.error)
        @test result.response.result isa CallToolResult
        @test result.response.result.is_error == true
        @test length(result.response.result.content) == 1
        @test result.response.result.content[1]["type"] == "text"
        @test result.response.result.content[1]["text"] == "An error occurred"
    end
    
    @testset "Multi-content CallToolResult" begin
        ctx = RequestContext(
            server = server,
            request_id = 3
        )
        
        params = CallToolParams(
            name = "multi_content_tool",
            arguments = nothing
        )
        
        result = handle_call_tool(ctx, params)
        
        @test !isnothing(result.response)
        @test isnothing(result.error)
        @test result.response.result isa CallToolResult
        @test result.response.result.is_error == false
        @test length(result.response.result.content) == 3
        @test result.response.result.content[1]["type"] == "text"
        @test result.response.result.content[1]["text"] == "First item"
        @test result.response.result.content[2]["type"] == "text"
        @test result.response.result.content[2]["text"] == "Second item"
        @test result.response.result.content[3]["type"] == "image"
        @test result.response.result.content[3]["mimeType"] == "image/png"
    end
end

@testset "Tools with No Parameters" begin
    # Create a tool with no parameters
    no_params_tool = MCPTool(
        name = "get_time",
        description = "Get the current time",
        parameters = [],  # No parameters
        handler = (args) -> TextContent(text = "Current time: $(now())"),
        return_type = TextContent
    )

    # Create server
    server = mcp_server(
        name = "test-no-params",
        version = "1.0.0",
        description = "Test server with no-params tool",
        tools = [no_params_tool]
    )

    # Test tool list response
    ctx = ModelContextProtocol.RequestContext(
        server = server,
        request_id = 1
    )

    result = ModelContextProtocol.handle_list_tools(ctx, ModelContextProtocol.ListToolsParams())

    @test !isnothing(result.response)
    @test isnothing(result.error)

    # Check the tool schema
    tools = result.response.result["tools"]
    @test length(tools) == 1
    @test tools[1]["name"] == "get_time"
    
    tool_schema = tools[1]["inputSchema"]
    @test tool_schema["properties"] isa Dict
    @test tool_schema["required"] isa Vector
    @test isempty(tool_schema["properties"])
    @test isempty(tool_schema["required"])
end
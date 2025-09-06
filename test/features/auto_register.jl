@testset "Auto Registration" begin
    @testset "Directory-based registration" begin
        # Create a temporary directory structure
        mktempdir() do tmpdir
            # Create subdirectories
            tools_dir = joinpath(tmpdir, "tools")
            resources_dir = joinpath(tmpdir, "resources")
            prompts_dir = joinpath(tmpdir, "prompts")
            
            mkpath(tools_dir)
            mkpath(resources_dir)
            mkpath(prompts_dir)
            
            # Create a test tool file
            tool_content = """
            using ModelContextProtocol
            
            test_auto_tool = MCPTool(
                name = "test_auto_tool",
                description = "Auto-registered test tool",
                handler = function(params)
                    return TextContent(text = "Auto tool response")
                end,
                parameters = []
            )
            """
            write(joinpath(tools_dir, "test_tool.jl"), tool_content)
            
            # Create a test resource file
            resource_content = """
            using ModelContextProtocol
            
            test_auto_resource = MCPResource(
                uri = "auto://test-resource",
                name = "test_auto_resource",
                description = "Auto-registered test resource",
                mime_type = "text/plain",
                data_provider = () -> "Auto resource data"
            )
            """
            write(joinpath(resources_dir, "test_resource.jl"), resource_content)
            
            # Create a test prompt file
            prompt_content = """
            using ModelContextProtocol
            
            test_auto_prompt = MCPPrompt(
                name = "test_auto_prompt",
                description = "Auto-registered test prompt",
                arguments = [
                    PromptArgument(
                        name = "input",
                        description = "Test input",
                        required = false
                    )
                ],
                messages = [
                    PromptMessage(
                        content = TextContent(text = "Auto prompt: {input}"),
                        role = ModelContextProtocol.user
                    )
                ]
            )
            """
            write(joinpath(prompts_dir, "test_prompt.jl"), prompt_content)
            
            # Create server and auto-register using the auto_register_dir parameter
            server = mcp_server(
                name = "auto-test",
                auto_register_dir = tmpdir
            )
            
            # Verify registration
            @test length(server.tools) == 1
            @test server.tools[1].name == "test_auto_tool"
            
            @test length(server.resources) == 1
            @test server.resources[1].name == "test_auto_resource"
            
            @test length(server.prompts) == 1
            @test server.prompts[1].name == "test_auto_prompt"
            
            # Test tool execution (use invokelatest due to world age from dynamic loading)
            tool_result = Base.invokelatest(server.tools[1].handler, Dict())
            @test tool_result isa TextContent
            @test tool_result.text == "Auto tool response"
            
            # Test resource data provider (use invokelatest due to world age from dynamic loading)
            resource_data = Base.invokelatest(server.resources[1].data_provider)
            @test resource_data == "Auto resource data"
        end
    end
    
    @testset "Invalid component handling" begin
        mktempdir() do tmpdir
            tools_dir = joinpath(tmpdir, "tools")
            mkpath(tools_dir)
            
            # Create an invalid tool file (missing return)
            invalid_content = """
            using ModelContextProtocol
            
            # This is invalid - not returning an MCPTool
            println("This file doesn't return a tool")
            """
            write(joinpath(tools_dir, "invalid_tool.jl"), invalid_content)
            
            server = mcp_server(name = "test")
            
            # Should not error, just skip invalid files
            ModelContextProtocol.auto_register!(server, tmpdir)
            @test length(server.tools) == 0
        end
    end
    
    @testset "Nested directory structure" begin
        mktempdir() do tmpdir
            # Create nested structure
            nested_dir = joinpath(tmpdir, "components", "v1")
            tools_dir = joinpath(nested_dir, "tools")
            mkpath(tools_dir)
            
            tool_content = """
            using ModelContextProtocol
            
            nested_tool = MCPTool(
                name = "nested_tool",
                description = "Tool in nested directory",
                handler = params -> TextContent(text = "Nested response"),
                parameters = []
            )
            """
            write(joinpath(tools_dir, "nested.jl"), tool_content)
            
            server = mcp_server(
                name = "test",
                auto_register_dir = nested_dir
            )
            
            @test length(server.tools) == 1
            @test server.tools[1].name == "nested_tool"
        end
    end
    
    @testset "Empty directory handling" begin
        mktempdir() do tmpdir
            # Create empty subdirectories
            mkpath(joinpath(tmpdir, "tools"))
            mkpath(joinpath(tmpdir, "resources"))
            mkpath(joinpath(tmpdir, "prompts"))
            
            server = mcp_server(
                name = "test",
                auto_register_dir = tmpdir
            )
            
            # Should handle empty directories gracefully
            @test length(server.tools) == 0
            @test length(server.resources) == 0
            @test length(server.prompts) == 0
        end
    end
    
    @testset "Non-existent directory" begin
        non_existent = "/tmp/definitely_does_not_exist_$(rand(1:10000))"
        
        # Should handle gracefully without error
        server = mcp_server(
            name = "test",
            auto_register_dir = non_existent
        )
        @test length(server.tools) == 0
    end
end
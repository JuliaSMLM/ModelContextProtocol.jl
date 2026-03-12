@testset "Request Handling" begin
    server = Server(ServerConfig(name="test"))
    ctx = RequestContext(server=server)

    # Test initialize request handling
    init_params = InitializeParams(
        capabilities=ClientCapabilities(),
        clientInfo=Implementation(),
        protocolVersion="1.0"
    )
    ctx = RequestContext(server=server, request_id=1)  # Set a valid request ID
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
    ctx = RequestContext(server=server, request_id=2)
    result = handle_ping(ctx, nothing)
    @test result isa HandlerResult
    @test !isnothing(result.response)
    @test result.response.id == 2
    @test isempty(result.response.result)
end

@testset "Title and Icons Metadata" begin
    @testset "ServerInfo includes title and icons" begin
        icon = MCPIcon(src="https://example.com/icon.png", mimeType="image/png")
        server = mcp_server(
            name="title-test",
            version="1.0.0",
            title="My Awesome Server",
            icons=[icon]
        )
        ctx = RequestContext(server=server, request_id=1)
        init_params = InitializeParams(
            capabilities=ClientCapabilities(),
            clientInfo=Implementation(),
            protocolVersion="2025-06-18"
        )
        result = handle_initialize(ctx, init_params)
        server_info = result.response.result.serverInfo
        @test server_info["title"] == "My Awesome Server"
        @test length(server_info["icons"]) == 1
        @test server_info["icons"][1]["src"] == "https://example.com/icon.png"
        @test server_info["icons"][1]["mimeType"] == "image/png"
    end

    @testset "ServerInfo omits title/icons when nothing" begin
        server = mcp_server(name="no-title", version="1.0.0")
        ctx = RequestContext(server=server, request_id=1)
        init_params = InitializeParams(
            capabilities=ClientCapabilities(),
            clientInfo=Implementation(),
            protocolVersion="2025-06-18"
        )
        result = handle_initialize(ctx, init_params)
        server_info = result.response.result.serverInfo
        @test !haskey(server_info, "title")
        @test !haskey(server_info, "icons")
    end

    @testset "Tools list includes title and icons" begin
        icon = MCPIcon(src="https://example.com/tool.svg", theme="dark")
        tool = MCPTool(
            name="titled_tool",
            description="A tool with title",
            parameters=[],
            handler=(args) -> TextContent(text="ok"),
            title="My Tool",
            icons=[icon]
        )
        server = mcp_server(name="test", version="1.0.0", tools=[tool])
        ctx = RequestContext(server=server, request_id=1)
        result = ModelContextProtocol.handle_list_tools(ctx, ModelContextProtocol.ListToolsParams())
        tool_dict = result.response.result["tools"][1]
        @test tool_dict["title"] == "My Tool"
        @test length(tool_dict["icons"]) == 1
        @test tool_dict["icons"][1]["src"] == "https://example.com/tool.svg"
        @test tool_dict["icons"][1]["theme"] == "dark"
        @test !haskey(tool_dict["icons"][1], "mimeType")
    end

    @testset "Prompts list includes title and icons" begin
        icon = MCPIcon(src="data:image/png;base64,abc", sizes=["48x48"])
        prompt = MCPPrompt(
            name="titled_prompt",
            description="A prompt with title",
            arguments=[PromptArgument(name="arg1", description="An arg", title="Argument One")],
            messages=[PromptMessage(content=TextContent(text="Hello {arg1}"))],
            title="My Prompt",
            icons=[icon]
        )
        server = mcp_server(name="test", version="1.0.0", prompts=[prompt])
        ctx = RequestContext(server=server, request_id=1)
        result = ModelContextProtocol.handle_list_prompts(ctx, ModelContextProtocol.ListPromptsParams())
        prompt_dict = result.response.result["prompts"][1]
        @test prompt_dict["title"] == "My Prompt"
        @test length(prompt_dict["icons"]) == 1
        @test prompt_dict["icons"][1]["sizes"] == ["48x48"]
        # Check argument title
        @test prompt_dict["arguments"][1]["title"] == "Argument One"
    end

    @testset "Resources list includes title and icons" begin
        icon = MCPIcon(src="https://example.com/res.png")
        resource = MCPResource(
            uri="test://res",
            name="titled_resource",
            description="A resource with title",
            data_provider=() -> Dict("data" => "test"),
            title="My Resource",
            icons=[icon]
        )
        server = mcp_server(name="test", version="1.0.0", resources=[resource])
        ctx = RequestContext(server=server, request_id=1)
        result = handle_list_resources(ctx, ListResourcesParams())
        res_dict = result.response.result["resources"][1]
        @test res_dict["title"] == "My Resource"
        @test length(res_dict["icons"]) == 1
        @test res_dict["icons"][1]["src"] == "https://example.com/res.png"
    end

    @testset "Tools without title/icons omit fields" begin
        tool = MCPTool(
            name="plain_tool",
            description="No title or icons",
            parameters=[],
            handler=(args) -> TextContent(text="ok")
        )
        server = mcp_server(name="test", version="1.0.0", tools=[tool])
        ctx = RequestContext(server=server, request_id=1)
        result = ModelContextProtocol.handle_list_tools(ctx, ModelContextProtocol.ListToolsParams())
        tool_dict = result.response.result["tools"][1]
        @test !haskey(tool_dict, "title")
        @test !haskey(tool_dict, "icons")
    end

    @testset "MCPIcon serialization" begin
        # Full icon
        icon = MCPIcon(src="https://example.com/icon.png", mimeType="image/png", sizes=["48x48", "any"], theme="light")
        d = ModelContextProtocol.icon_to_dict(icon)
        @test d["src"] == "https://example.com/icon.png"
        @test d["mimeType"] == "image/png"
        @test d["sizes"] == ["48x48", "any"]
        @test d["theme"] == "light"

        # Minimal icon
        icon_min = MCPIcon(src="https://example.com/icon.svg")
        d_min = ModelContextProtocol.icon_to_dict(icon_min)
        @test d_min["src"] == "https://example.com/icon.svg"
        @test !haskey(d_min, "mimeType")
        @test !haskey(d_min, "sizes")
        @test !haskey(d_min, "theme")
    end

    @testset "Multiple icons on a single component" begin
        light_icon = MCPIcon(src="https://example.com/light.png", theme="light")
        dark_icon = MCPIcon(src="https://example.com/dark.png", theme="dark")
        tool = MCPTool(
            name="multi_icon_tool",
            description="Tool with light and dark icons",
            parameters=[],
            handler=(args) -> TextContent(text="ok"),
            title="Multi-Icon Tool",
            icons=[light_icon, dark_icon]
        )
        server = mcp_server(name="test", version="1.0.0", tools=[tool])
        ctx = RequestContext(server=server, request_id=1)
        result = ModelContextProtocol.handle_list_tools(ctx, ModelContextProtocol.ListToolsParams())
        tool_dict = result.response.result["tools"][1]
        @test length(tool_dict["icons"]) == 2
        @test tool_dict["icons"][1]["theme"] == "light"
        @test tool_dict["icons"][2]["theme"] == "dark"
    end

    @testset "Prompts without title/icons omit fields" begin
        prompt = MCPPrompt(
            name="plain_prompt",
            description="No title or icons",
            arguments=[PromptArgument(name="x", description="param")],
            messages=[PromptMessage(content=TextContent(text="Hello {x}"))]
        )
        server = mcp_server(name="test", version="1.0.0", prompts=[prompt])
        ctx = RequestContext(server=server, request_id=1)
        result = ModelContextProtocol.handle_list_prompts(ctx, ModelContextProtocol.ListPromptsParams())
        prompt_dict = result.response.result["prompts"][1]
        @test !haskey(prompt_dict, "title")
        @test !haskey(prompt_dict, "icons")
        @test !haskey(prompt_dict["arguments"][1], "title")
    end

    @testset "Resources without title/icons omit fields" begin
        resource = MCPResource(
            uri="test://plain",
            name="plain_resource",
            description="No title or icons",
            data_provider=() -> Dict("x" => 1)
        )
        server = mcp_server(name="test", version="1.0.0", resources=[resource])
        ctx = RequestContext(server=server, request_id=1)
        result = handle_list_resources(ctx, ListResourcesParams())
        res_dict = result.response.result["resources"][1]
        @test !haskey(res_dict, "title")
        @test !haskey(res_dict, "icons")
    end

    @testset "ResourceTemplate title and icons fields" begin
        icon = MCPIcon(src="https://example.com/tpl.png", mimeType="image/png")
        tpl = ResourceTemplate(
            name="titled_template",
            uri_template="test://items/{id}",
            description="A template with title",
            title="My Template",
            icons=[icon]
        )
        @test tpl.title == "My Template"
        @test length(tpl.icons) == 1
        @test tpl.icons[1].src == "https://example.com/tpl.png"

        # Without title/icons
        tpl_plain = ResourceTemplate(
            name="plain_template",
            uri_template="test://items/{id}"
        )
        @test isnothing(tpl_plain.title)
        @test isnothing(tpl_plain.icons)
    end

    @testset "Server with multiple icons in server info" begin
        icons = [
            MCPIcon(src="https://example.com/sm.png", sizes=["16x16"]),
            MCPIcon(src="https://example.com/lg.png", sizes=["128x128"]),
            MCPIcon(src="https://example.com/any.svg", sizes=["any"], mimeType="image/svg+xml")
        ]
        server = mcp_server(name="multi-icon-server", version="1.0.0", title="Multi Icon", icons=icons)
        ctx = RequestContext(server=server, request_id=1)
        init_params = InitializeParams(
            capabilities=ClientCapabilities(),
            clientInfo=Implementation(),
            protocolVersion="2025-06-18"
        )
        result = handle_initialize(ctx, init_params)
        server_info = result.response.result.serverInfo
        @test server_info["title"] == "Multi Icon"
        @test length(server_info["icons"]) == 3
        @test server_info["icons"][3]["mimeType"] == "image/svg+xml"
        @test server_info["icons"][3]["sizes"] == ["any"]
    end
end
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
        @test !haskey(server_info, "description")  # default description is ""
    end

    @testset "ServerInfo includes description" begin
        server = mcp_server(name="desc-test", version="1.0.0", description="A demo MCP server")
        ctx = RequestContext(server=server, request_id=1)
        init_params = InitializeParams(
            capabilities=ClientCapabilities(),
            clientInfo=Implementation(),
            protocolVersion="2025-06-18"
        )
        result = handle_initialize(ctx, init_params)
        @test result.response.result.serverInfo["description"] == "A demo MCP server"
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

    @testset "Tools list includes annotations" begin
        tool = MCPTool(
            name="annotated_tool",
            description="A tool with annotations",
            parameters=[],
            handler=(args) -> TextContent(text="ok"),
            annotations=Dict{String,Any}(
                "readOnlyHint" => true,
                "destructiveHint" => false,
                "idempotentHint" => true,
                "openWorldHint" => false,
            )
        )
        server = mcp_server(name="test", version="1.0.0", tools=[tool])
        ctx = RequestContext(server=server, request_id=1)
        result = ModelContextProtocol.handle_list_tools(ctx, ModelContextProtocol.ListToolsParams())
        tool_dict = result.response.result["tools"][1]
        @test tool_dict["annotations"]["readOnlyHint"] == true
        @test tool_dict["annotations"]["destructiveHint"] == false
        @test tool_dict["annotations"]["idempotentHint"] == true
        @test tool_dict["annotations"]["openWorldHint"] == false
    end

    @testset "Tools list includes outputSchema" begin
        schema = Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}("answer" => Dict{String,Any}("type" => "integer")),
        )
        tool = MCPTool(
            name="schema_tool",
            description="A tool with an output schema",
            parameters=[],
            handler=(args) -> TextContent(text="ok"),
            output_schema=schema,
        )
        server = mcp_server(name="test", version="1.0.0", tools=[tool])
        ctx = RequestContext(server=server, request_id=1)
        result = ModelContextProtocol.handle_list_tools(ctx, ModelContextProtocol.ListToolsParams())
        tool_dict = result.response.result["tools"][1]
        @test tool_dict["outputSchema"]["type"] == "object"
        @test haskey(tool_dict["outputSchema"]["properties"], "answer")
    end

    @testset "Generated input schema declares the 2020-12 dialect" begin
        param_tool = MCPTool(
            name="param_tool",
            description="Schema built from parameters",
            parameters=[ToolParameter(name="x", description="X", type="string", required=true)],
            handler=(args) -> TextContent(text="ok")
        )
        raw_schema = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}())
        raw_tool = MCPTool(
            name="raw_tool",
            description="User-provided raw schema",
            parameters=[],
            input_schema=raw_schema,
            handler=(args) -> TextContent(text="ok")
        )
        server = mcp_server(name="test", version="1.0.0", tools=[param_tool, raw_tool])
        ctx = RequestContext(server=server, request_id=1)
        result = ModelContextProtocol.handle_list_tools(ctx, ModelContextProtocol.ListToolsParams())
        tools = result.response.result["tools"]
        generated = only(filter(t -> t["name"] == "param_tool", tools))["inputSchema"]
        raw = only(filter(t -> t["name"] == "raw_tool", tools))["inputSchema"]
        @test generated["\$schema"] == "https://json-schema.org/draft/2020-12/schema"
        @test haskey(generated["properties"], "x")
        @test !haskey(raw, "\$schema")  # raw input_schema passes through verbatim
    end

    @testset "List entries include _meta when set" begin
        meta = Dict{String,Any}("vendor/key" => "v")
        tool = MCPTool(name="meta_tool", description="t", parameters=[],
                       handler=(args) -> TextContent(text="ok"), _meta=meta)
        prompt = MCPPrompt(name="meta_prompt", description="p", _meta=meta)
        resource = MCPResource(uri="test://meta", name="meta_res",
                               data_provider=() -> Dict(), _meta=meta)
        server = mcp_server(name="test", version="1.0.0",
                            tools=[tool], prompts=[prompt], resources=[resource])
        ctx = RequestContext(server=server, request_id=1)

        tool_dict = ModelContextProtocol.handle_list_tools(ctx, ModelContextProtocol.ListToolsParams()).response.result["tools"][1]
        prompt_dict = ModelContextProtocol.handle_list_prompts(ctx, ModelContextProtocol.ListPromptsParams()).response.result["prompts"][1]
        res_dict = handle_list_resources(ctx, ListResourcesParams()).response.result["resources"][1]
        @test tool_dict["_meta"]["vendor/key"] == "v"
        @test prompt_dict["_meta"]["vendor/key"] == "v"
        @test res_dict["_meta"]["vendor/key"] == "v"
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
        @test !haskey(tool_dict, "annotations")
        @test !haskey(tool_dict, "outputSchema")
        @test !haskey(tool_dict, "_meta")
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

@testset "Progress notifications" begin
    @testset "send_progress is a no-op without a token" begin
        server = mcp_server(name="test", version="1.0.0")
        ctx = RequestContext(server=server)  # no progress_token, no transport
        @test send_progress(ctx, 1) == false
    end

    @testset "send_progress is a no-op without a transport" begin
        server = mcp_server(name="test", version="1.0.0")  # transport defaults to nothing
        ctx = RequestContext(server=server, progress_token="tok")
        @test send_progress(ctx, 1) == false
    end

    @testset "send_progress writes a notifications/progress message" begin
        server = mcp_server(name="test", version="1.0.0")
        buf = IOBuffer()
        server.transport = StdioTransport(output=buf)
        ctx = RequestContext(server=server, progress_token="tok-1")

        @test send_progress(ctx, 3; total=10, message="working") == true

        notif = JSON3.read(String(take!(buf)))
        @test notif["jsonrpc"] == "2.0"
        @test notif["method"] == "notifications/progress"
        @test notif["params"]["progressToken"] == "tok-1"
        @test notif["params"]["progress"] == 3.0
        @test notif["params"]["total"] == 10.0
        @test notif["params"]["message"] == "working"
    end

    @testset "send_progress omits total/message when not given" begin
        server = mcp_server(name="test", version="1.0.0")
        buf = IOBuffer()
        server.transport = StdioTransport(output=buf)
        ctx = RequestContext(server=server, progress_token=7)  # integer token

        @test send_progress(ctx, 1.5) == true

        notif = JSON3.read(String(take!(buf)))
        @test notif["params"]["progressToken"] == 7
        @test notif["params"]["progress"] == 1.5
        @test !haskey(notif["params"], "total")
        @test !haskey(notif["params"], "message")
    end

    @testset "handle_call_tool passes the context to a two-argument handler" begin
        tool = MCPTool(
            name="ctx_tool",
            description="Echoes the progress token from its context",
            parameters=[],
            handler=(args, ctx) -> TextContent(text=string(ctx.progress_token))
        )
        server = mcp_server(name="test", version="1.0.0", tools=[tool])
        ctx = RequestContext(server=server, request_id=1, progress_token="abc")
        result = handle_call_tool(ctx, CallToolParams(name="ctx_tool"))
        @test result.response.result.content[1]["text"] == "abc"
    end

    @testset "handle_call_tool still calls one-argument handlers" begin
        tool = MCPTool(
            name="plain_handler",
            description="Ignores any context",
            parameters=[],
            handler=(args) -> TextContent(text="one-arg")
        )
        server = mcp_server(name="test", version="1.0.0", tools=[tool])
        ctx = RequestContext(server=server, request_id=1, progress_token="ignored")
        result = handle_call_tool(ctx, CallToolParams(name="plain_handler"))
        @test result.response.result.content[1]["text"] == "one-arg"
    end

    @testset "parse_request extracts params._meta.progressToken" begin
        raw = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call",
         "params":{"name":"x","arguments":{},"_meta":{"progressToken":"pt-9"}}}
        """
        req = ModelContextProtocol.parse_message(raw)
        @test req isa JSONRPCRequest
        @test req.meta.progress_token == "pt-9"
    end

    @testset "parse_request leaves progress token nothing when absent" begin
        raw = """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"x","arguments":{}}}"""
        req = ModelContextProtocol.parse_message(raw)
        @test req isa JSONRPCRequest
        @test req.meta.progress_token === nothing
    end

    @testset "send_progress routes to the HTTP notification queue, not the response" begin
        # On HTTP, write_message delivers to the calling request's response channel, so
        # routing progress there would be returned as (and corrupt) the response. The
        # transport-polymorphic send_notification sends it over the SSE queue instead.
        transport = HttpTransport(port=8099)
        transport.connected = true  # mark connected without binding a port
        server = mcp_server(name="test", version="1.0.0")
        server.transport = transport
        ctx = RequestContext(server=server, progress_token="http-tok")

        @test send_progress(ctx, 2; total=5) == true
        @test isready(transport.notification_queue)   # delivered out-of-band (SSE)
        @test isempty(transport.response_channels)     # response path untouched
        notif = JSON3.read(take!(transport.notification_queue))
        @test notif["method"] == "notifications/progress"
        @test notif["params"]["progressToken"] == "http-tok"
        @test notif["params"]["progress"] == 2.0
        @test notif["params"]["total"] == 5.0
    end
end
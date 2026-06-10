# test/e2e/fixtures/wire_demo_server.jl
#
# Demo server exercising every wire-visible feature in one place: server
# description, generated input schema ($schema dialect), _meta on components
# and results, multi-content tool returns (text + audio + resource_link),
# structured output, and media prompt messages. Driven as a real subprocess
# by test/e2e/test_wire_conformance.jl over stdio (default) and Streamable
# HTTP (`http` argument; port from DEMO_PORT, default 8772).

using ModelContextProtocol

audio_bytes = UInt8[0x52, 0x49, 0x46, 0x46]  # "RIFF"
png_bytes = UInt8[0x89, 0x50, 0x4E, 0x47]    # PNG header

analyze = MCPTool(
    name = "analyze_image",
    description = "Fake analysis returning text + audio + resource_link",
    parameters = [
        ToolParameter(name = "dataset", description = "Dataset name", type = "string", required = true),
    ],
    handler = args -> [
        TextContent(text = "analyzed $(args["dataset"])"),
        AudioContent(data = audio_bytes, mime_type = "audio/wav"),
        ResourceLink(
            uri = "file:///results/$(args["dataset"])/overlay.png",
            name = "overlay.png",
            description = "Segmentation overlay",
            mime_type = "image/png",
            size = 123456,
        ),
    ],
    _meta = Dict{String,Any}("lab/origin" => "wire-demo"),
)

structured = MCPTool(
    name = "get_stats",
    description = "Structured output demo",
    parameters = [],
    output_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}("count" => Dict{String,Any}("type" => "integer")),
    ),
    handler = args -> CallToolResult(
        content = [Dict{String,Any}("type" => "text", "text" => "{\"count\":42}")],
        structured_content = Dict("count" => 42),
        _meta = Dict("trace" => "abc123"),
    ),
)

count_slow = MCPTool(
    name = "count_slow",
    description = "Task-augmented execution demo (MCP Tasks)",
    parameters = [],
    handler = args -> (sleep(0.3); TextContent(text = "counted")),
    task_support = :optional,
)

media_prompt = MCPPrompt(
    name = "media_demo",
    description = "Prompt with all media content types",
    messages = [
        PromptMessage(content = TextContent(text = "Look at this:")),
        PromptMessage(content = ImageContent(data = png_bytes, mime_type = "image/png")),
        PromptMessage(content = AudioContent(data = audio_bytes, mime_type = "audio/wav")),
        PromptMessage(content = ResourceLink(uri = "file:///d/raw.tif", name = "raw.tif")),
    ],
    _meta = Dict{String,Any}("lab/prompt" => true),
)

res = MCPResource(
    uri = "demo://stats",
    name = "stats",
    description = "Demo resource",
    data_provider = () -> Dict("ok" => true),
    _meta = Dict{String,Any}("lab/resource" => 1),
)

res_blob = MCPResource(
    uri = "demo://logo",
    name = "logo",
    description = "Binary resource (BlobResourceContents demo)",
    mime_type = "image/png",
    data_provider = () -> BlobResourceContents(
        uri = "demo://logo", mime_type = "image/png", blob = png_bytes),
)

res_text = MCPResource(
    uri = "demo://readme",
    name = "readme",
    description = "Verbatim String resource demo",
    mime_type = "text/plain",
    data_provider = () -> "plain, not JSON-quoted",
)

tmpl_artifact = ResourceTemplate(
    name = "artifact",
    uri_template = "demo://artifact/{id}",
    description = "Content-addressed artifact family (URI template demo)",
    mime_type = "image/png",
    data_provider = (uri, vars) -> BlobResourceContents(
        uri = uri, mime_type = "image/png",
        blob = vcat(png_bytes, Vector{UInt8}(vars["id"]))),
)

server = mcp_server(
    name = "wire-demo",
    version = "0.1.0",
    description = "Wire conformance demo server",
    tools = [analyze, structured, count_slow],
    prompts = [media_prompt],
    resources = [res, res_blob, res_text],
    resource_templates = [tmpl_artifact],
)

if "http" in ARGS
    port = parse(Int, get(ENV, "DEMO_PORT", "8772"))
    server.transport = HttpTransport(host = "127.0.0.1", port = port)
    ModelContextProtocol.connect(server.transport)
end
start!(server)

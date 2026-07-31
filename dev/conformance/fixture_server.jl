# Conformance fixture server for the official MCP conformance suite
# (github.com/modelcontextprotocol/conformance). Implements the exact fixture
# contract the server scenarios expect (test_* tools, test:// resources,
# test_* prompts). Run from the repo root:
#
#     julia --project dev/conformance/fixture_server.jl [port]
#
# then:  npx @modelcontextprotocol/conformance server --url http://127.0.0.1:<port>/

using ModelContextProtocol
using ModelContextProtocol: HttpTransport
using URIs
using JSON3
using Base64

const PORT = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8791

# 1x1 red pixel PNG
const PNG_1PX = base64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

# Minimal valid WAV: 44-byte RIFF header + 8 bytes of silence (PCM 8kHz mono 16-bit)
function make_wav()
    data = zeros(UInt8, 8)
    io = IOBuffer()
    write(io, "RIFF"); write(io, UInt32(36 + length(data))); write(io, "WAVE")
    write(io, "fmt "); write(io, UInt32(16)); write(io, UInt16(1)); write(io, UInt16(1))
    write(io, UInt32(8000)); write(io, UInt32(16000)); write(io, UInt16(2)); write(io, UInt16(16))
    write(io, "data"); write(io, UInt32(length(data))); write(io, data)
    take!(io)
end

tools = [
    MCPTool(
        name = "test_simple_text",
        description = "Returns a simple text response",
        parameters = ToolParameter[],
        handler = args -> TextContent(text = "This is a simple text response for testing.")),
    MCPTool(
        name = "test_image_content",
        description = "Returns image content (1x1 PNG)",
        parameters = ToolParameter[],
        handler = args -> ImageContent(data = PNG_1PX, mime_type = "image/png")),
    MCPTool(
        name = "test_audio_content",
        description = "Returns audio content (minimal WAV)",
        parameters = ToolParameter[],
        handler = args -> AudioContent(data = make_wav(), mime_type = "audio/wav")),
    MCPTool(
        name = "test_embedded_resource",
        description = "Returns an embedded resource",
        parameters = ToolParameter[],
        handler = args -> EmbeddedResource(resource = Dict{String,Any}(
            "uri" => "test://embedded",
            "mimeType" => "text/plain",
            "text" => "Embedded resource content for testing."))),
    MCPTool(
        name = "test_multiple_content_types",
        description = "Returns mixed text and image content",
        parameters = ToolParameter[],
        handler = args -> [
            TextContent(text = "Multiple content types test:"),
            ImageContent(data = PNG_1PX, mime_type = "image/png"),
            EmbeddedResource(resource = Dict{String,Any}(
                "uri" => "test://mixed-content-resource",
                "mimeType" => "application/json",
                "text" => "{\"test\":\"data\",\"value\":123}")),
        ]),
    MCPTool(
        name = "test_error_handling",
        description = "Intentionally returns a tool execution error",
        parameters = ToolParameter[],
        handler = args -> CallToolResult(
            content = [TextContent(text = "This tool intentionally returns an error for testing.")],
            is_error = true)),
    MCPTool(
        name = "test_tool_with_progress",
        description = "Emits progress notifications 0/50/100 when a progressToken is provided",
        parameters = ToolParameter[],
        handler = (args, ctx) -> begin
            for p in (0, 50, 100)
                send_progress(ctx, p; total = 100, message = "Progress: $p/100")
                sleep(0.2)
            end
            TextContent(text = "Progress test complete")
        end),
    MCPTool(
        name = "test_logging_tool",
        description = "Emits a log record (stateless suite: must NOT reach a modern client without logLevel)",
        parameters = ToolParameter[],
        handler = args -> begin
            @info "test_logging_tool fired"
            TextContent(text = "logged")
        end),
    MCPTool(
        name = "test_tool_with_logging",
        description = "Emits log notifications during execution",
        parameters = ToolParameter[],
        handler = args -> begin
            @info "test_tool_with_logging: starting"
            sleep(0.3)
            @info "test_tool_with_logging: halfway"
            sleep(0.3)
            @warn "test_tool_with_logging: finishing"
            TextContent(text = "Logging test complete")
        end),
]

resources = [
    MCPResource(
        uri = "test://static-text",
        name = "static-text",
        description = "Static text resource",
        mime_type = "text/plain",
        data_provider = () -> "This is the content of the static text resource."),
    MCPResource(
        uri = "test://static-binary",
        name = "static-binary",
        description = "Static binary resource (1x1 PNG)",
        mime_type = "image/png",
        data_provider = () -> BlobResourceContents(
            uri = URI("test://static-binary"), mime_type = "image/png", blob = PNG_1PX)),
    MCPResource(
        uri = "test://watched-resource",
        name = "watched-resource",
        description = "Resource used by subscribe/unsubscribe scenarios",
        mime_type = "text/plain",
        data_provider = () -> "watched resource content"),
]

templates = [
    ResourceTemplate(
        name = "template-data",
        uri_template = "test://template/{id}/data",
        mime_type = "application/json",
        description = "Parameterized data resource",
        data_provider = (uri, vars) -> TextResourceContents(
            uri = URI(uri),
            mime_type = "application/json",
            text = JSON3.write(Dict(
                "id" => vars["id"],
                "templateTest" => true,
                "data" => "Data for ID: $(vars["id"])")))),
]

prompts = [
    MCPPrompt(
        name = "test_simple_prompt",
        description = "A simple prompt with no arguments",
        arguments = PromptArgument[],
        messages = [PromptMessage(content = TextContent(text = "This is a simple prompt for testing."))]),
    MCPPrompt(
        name = "test_prompt_with_arguments",
        description = "Prompt requiring two arguments",
        arguments = [
            PromptArgument(name = "arg1", description = "First test argument", required = true),
            PromptArgument(name = "arg2", description = "Second test argument", required = true),
        ],
        messages = [PromptMessage(content = TextContent(
            text = "Prompt with arguments: arg1='{arg1}', arg2='{arg2}'"))]),
    MCPPrompt(
        name = "test_prompt_with_embedded_resource",
        description = "Prompt containing an embedded resource",
        arguments = [PromptArgument(name = "resourceUri", description = "URI of the resource to embed", required = true)],
        messages = [PromptMessage(content = EmbeddedResource(resource = Dict{String,Any}(
            "uri" => "test://example-resource",
            "mimeType" => "text/plain",
            "text" => "Embedded resource content for testing.")))]),
    MCPPrompt(
        name = "test_prompt_with_image",
        description = "Prompt containing an image and a text message",
        arguments = PromptArgument[],
        messages = [
            PromptMessage(content = ImageContent(data = PNG_1PX, mime_type = "image/png")),
            PromptMessage(content = TextContent(text = "What do you see in this image?")),
        ]),
]

server = mcp_server(
    name = "conformance-fixture-server",
    version = "0.1.0",
    description = "Fixture server for the official MCP conformance suite",
    tools = tools,
    resources = resources,
    resource_templates = templates,
    prompts = prompts,
)

transport = HttpTransport(host = "127.0.0.1", port = PORT)
server.transport = transport
ModelContextProtocol.connect(transport)

println("Conformance fixture server listening on http://127.0.0.1:$PORT/")
start!(server)

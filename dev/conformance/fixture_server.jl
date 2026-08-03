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

# The trigger tools mutate the server they belong to, so they need a handle to it;
# filled in immediately after construction below.
const SERVER_REF = Ref{Any}(nothing)

# Tolerant accessor for parsed-JSON response values (String or Symbol keys,
# depending on which layer parsed them).
_val(d, k) = d isa AbstractDict ?
    (haskey(d, k) ? d[k] : (haskey(d, Symbol(k)) ? d[Symbol(k)] : nothing)) : nothing

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
    MCPTool(
        name = "test_trigger_tool_change",
        description = "Mutate the tool list and notify subscriptions/listen streams",
        parameters = ToolParameter[],
        handler = args -> begin
            push!(SERVER_REF[].tools, MCPTool(
                name = "test_added_tool_$(length(SERVER_REF[].tools))",
                description = "Dynamically added",
                parameters = ToolParameter[],
                handler = a -> TextContent(text = "added")))
            n = notify_list_changed(SERVER_REF[], :tools)
            TextContent(text = "tools changed; notified $n stream(s)")
        end),
    MCPTool(
        name = "test_trigger_prompt_change",
        description = "Mutate the prompt list and notify subscriptions/listen streams",
        parameters = ToolParameter[],
        handler = args -> begin
            push!(SERVER_REF[].prompts, MCPPrompt(
                name = "test_added_prompt_$(length(SERVER_REF[].prompts))",
                description = "Dynamically added",
                arguments = PromptArgument[],
                messages = [PromptMessage(content = TextContent(text = "added"))]))
            n = notify_list_changed(SERVER_REF[], :prompts)
            TextContent(text = "prompts changed; notified $n stream(s)")
        end),
    MCPTool(
        name = "test_trigger_resource_update",
        description = "Announce a resource update to subscriptions/listen streams",
        parameters = ToolParameter[],
        handler = args -> begin
            n = notify_resource_updated(SERVER_REF[], "test://watched-resource")
            TextContent(text = "resource updated; notified $n stream(s)")
        end),
    MCPTool(
        name = "test_missing_capability",
        description = "MRTR diagnostic: needs the client's sampling capability (undeclared -> -32021)",
        parameters = ToolParameter[],
        handler = (args, ctx) -> begin
            resp = get(input_responses(ctx), "sample", nothing)
            resp === nothing && return InputRequired(Dict("sample" => sampling_request(Dict(
                "messages" => [Dict("role" => "user",
                                    "content" => Dict("type" => "text", "text" => "Say ok"))],
                "maxTokens" => 8))))
            TextContent(text = "sampled")
        end),
    MCPTool(
        name = "test_streaming_elicitation",
        description = "MRTR diagnostic: elicits a confirmation via input_required on the response stream",
        parameters = ToolParameter[],
        handler = (args, ctx) -> begin
            resp = get(input_responses(ctx), "confirm", nothing)
            resp === nothing && return InputRequired(
                Dict("confirm" => elicit_request("Proceed with the diagnostic?")))
            TextContent(text = "confirmed")
        end),
    # ---- Tasks extension (SEP-2663) fixtures: the tasks-* scenario contract ----
    MCPTool(
        name = "greet",
        description = "Sync-only greeting",
        parameters = [ToolParameter(name = "name", description = "Who to greet",
                                    type = "string", required = true)],
        handler = args -> TextContent(text = "Hello, $(args["name"])!")),
    MCPTool(
        name = "slow_compute",
        description = "Task-supporting compute: sleeps `seconds` then returns; seconds:0 takes the immediate-result shortcut",
        parameters = [
            ToolParameter(name = "seconds", description = "How long to compute",
                          type = "number", required = true),
            ToolParameter(name = "label", description = "Echoed label", type = "string"),
        ],
        task_support = :optional,
        handler = (args, ctx) -> begin
            secs = round(Int, args["seconds"])
            secs > 0 && task_detach(ctx)
            for _ in 1:(secs * 20)
                task_cancelled(ctx) && return TextContent(text = "slow_compute cancelled")
                sleep(0.05)
            end
            TextContent(text = "slow_compute done after $(secs)s ($(get(args, "label", "")))")
        end),
    MCPTool(
        name = "failing_job",
        description = "Task-required job that reports a tool-level error (isError -> completed)",
        parameters = ToolParameter[],
        task_support = :required,
        handler = (args, ctx) -> begin
            task_detach(ctx)
            sleep(1.0)
            CallToolResult(
                content = [Dict{String,Any}("type" => "text",
                                            "text" => "failing_job: simulated tool error")],
                is_error = true)
        end),
    MCPTool(
        name = "protocol_error_job",
        description = "Task-supporting job that fails with a protocol-level (JSON-RPC) error",
        parameters = ToolParameter[],
        task_support = :optional,
        handler = (args, ctx) -> begin
            task_detach(ctx)
            sleep(0.5)
            error("protocol_error_job: simulated internal failure")
        end),
    MCPTool(
        name = "confirm_delete",
        description = "Task-supporting confirmation: parks on one elicitation inputRequest, completes on the response",
        parameters = [ToolParameter(name = "filename", description = "File to delete",
                                    type = "string", required = true)],
        task_support = :optional,
        handler = (args, ctx) -> begin
            task_detach(ctx)
            resp = task_await_input(ctx, elicit_request(
                "Really delete $(args["filename"])?";
                requested_schema = Dict{String,Any}(
                    "type" => "object",
                    "properties" => Dict{String,Any}(
                        "confirm" => Dict{String,Any}("type" => "boolean")))))
            confirmed = _val(_val(resp, "content"), "confirm") === true
            TextContent(text = confirmed ?
                "confirm_delete: deleted $(args["filename"])" :
                "confirm_delete: kept $(args["filename"])")
        end),
    MCPTool(
        name = "multi_input",
        description = "Task-supporting fan-out: two parallel elicitation inputRequests (partial fulfillment)",
        parameters = ToolParameter[],
        task_support = :optional,
        handler = (args, ctx) -> begin
            task_detach(ctx)
            responses = task_await_input(ctx, [
                elicit_request("First input?"),
                elicit_request("Second input?"),
            ])
            names = [string(something(_val(_val(r, "content"), "name"), "?")) for r in responses]
            TextContent(text = "multi_input done: $(join(names, ", "))")
        end),
    MCPTool(
        name = "test_tool_with_task",
        description = "MRTR-to-task composition: gathers user_name via the MRTR round, then escalates to a task",
        parameters = ToolParameter[],
        task_support = :required,
        handler = (args, ctx) -> begin
            resp = get(input_responses(ctx), "user_name", nothing)
            resp === nothing && return InputRequired(Dict("user_name" => elicit_request(
                "What is your name?";
                requested_schema = Dict{String,Any}(
                    "type" => "object",
                    "properties" => Dict{String,Any}(
                        "name" => Dict{String,Any}("type" => "string"))))))
            task_detach(ctx)
            sleep(0.2)
            user_name = something(_val(_val(resp, "content"), "name"), "unknown")
            TextContent(text = "Task complete for user: $(user_name)")
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
    capabilities = ModelContextProtocol.Capability[
        ModelContextProtocol.ToolCapability(list_changed = true),
        ModelContextProtocol.PromptCapability(list_changed = true),
        ModelContextProtocol.ResourceCapability(list_changed = true, subscribe = true),
        ModelContextProtocol.LoggingCapability(),
    ],
    name = "conformance-fixture-server",
    version = "0.1.0",
    description = "Fixture server for the official MCP conformance suite",
    tools = tools,
    resources = resources,
    resource_templates = templates,
    prompts = prompts,
)

SERVER_REF[] = server

transport = HttpTransport(host = "127.0.0.1", port = PORT)
server.transport = transport
ModelContextProtocol.connect(transport)

println("Conformance fixture server listening on http://127.0.0.1:$PORT/")
start!(server)

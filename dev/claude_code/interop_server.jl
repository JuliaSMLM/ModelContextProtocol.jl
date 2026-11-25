# Interop probe server for a real MCP client (Claude Code). It answers one question
# the conformance suite cannot: what does a shipping client actually negotiate and
# declare when it talks to this package?
#
# Run from the repo root, over stdio (the client spawns it) or HTTP:
#
#     julia --project dev/claude_code/interop_server.jl
#     julia --project dev/claude_code/interop_server.jl http 8798
#
# dev/claude_code/README.md has the client-side commands.

using ModelContextProtocol
using ModelContextProtocol: HttpTransport

# Parsed-JSON accessor tolerant of String or Symbol keys.
_val(d, k) = d isa AbstractDict ?
    (haskey(d, k) ? d[k] : (haskey(d, Symbol(k)) ? d[Symbol(k)] : nothing)) : nothing

_keys(d) = d isa AbstractDict ? sort!([string(k) for k in keys(d)]) : String[]

tools = [
    MCPTool(
        name = "era_probe",
        description = "Report which MCP protocol era and version this request used, and which client capabilities it declared",
        parameters = ToolParameter[],
        handler = (args, ctx) -> begin
            modern = ctx.protocol_version !== nothing
            caps = ctx.client_capabilities
            lines = [
                "era: $(modern ? "modern (per-request _meta)" : "legacy (initialize)")",
                "protocol version: $(something(modern ? ctx.protocol_version : ctx.state.protocol_version, "none"))",
                "client capabilities: $(join(_keys(caps), ", "))",
                "elicitation modes: $(join(_keys(_val(caps, "elicitation")), ", "))",
                "extensions: $(join(_keys(_val(caps, "extensions")), ", "))",
            ]
            TextContent(text = join(lines, "\n"))
        end),
    MCPTool(
        name = "ask_name",
        description = "Ask the user for their name with a form (MRTR elicitation), then greet them",
        parameters = ToolParameter[],
        handler = (args, ctx) -> begin
            resp = get(input_responses(ctx), "user_name", nothing)
            name = _val(resp, "action") == "accept" ? _val(_val(resp, "content"), "name") : nothing
            if name === nothing && resp === nothing
                return InputRequired(Dict("user_name" => elicit_request(
                    "What is your name?";
                    requested_schema = Dict{String,Any}(
                        "type" => "object",
                        "properties" => Dict{String,Any}(
                            "name" => Dict{String,Any}("type" => "string")),
                        "required" => ["name"]))))
            end
            TextContent(text = name === nothing ?
                "The question was declined or cancelled." : "Hello, $(name)!")
        end),
    MCPTool(
        name = "slow_job",
        description = "Run for `seconds` as a background task (tasks extension), then report",
        parameters = [ToolParameter(name = "seconds", description = "How long to run",
                                    type = "number", default = 20)],
        task_support = :optional,
        handler = (args, ctx) -> begin
            secs = round(Int, args["seconds"])
            detached = task_detach(ctx)
            for _ in 1:(secs * 10)
                task_cancelled(ctx) && return TextContent(text = "slow_job cancelled")
                sleep(0.1)
            end
            TextContent(text = "slow_job finished after $(secs)s (ran as a task: $(detached))")
        end),
    MCPTool(
        name = "confirm_job",
        description = "Start a background task that pauses to ask the user a yes/no question",
        parameters = ToolParameter[],
        task_support = :optional,
        handler = (args, ctx) -> begin
            task_detach(ctx)
            resp = task_await_input(ctx, elicit_request(
                "Continue with the job?";
                requested_schema = Dict{String,Any}(
                    "type" => "object",
                    "properties" => Dict{String,Any}(
                        "confirm" => Dict{String,Any}("type" => "boolean")),
                    "required" => ["confirm"])))
            yes = _val(_val(resp, "content"), "confirm") === true
            TextContent(text = yes ? "confirm_job: continued" : "confirm_job: stopped")
        end),
]

server = mcp_server(
    name = "interop-probe",
    version = "0.1.0",
    description = "Probe server for checking a real client against ModelContextProtocol.jl",
    tools = tools,
)

if length(ARGS) >= 1 && ARGS[1] == "http"
    port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 8798
    transport = HttpTransport(host = "127.0.0.1", port = port)
    server.transport = transport
    ModelContextProtocol.connect(transport)
    println("Interop probe server listening on http://127.0.0.1:$port/")
end

start!(server)

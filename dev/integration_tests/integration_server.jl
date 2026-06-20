# Self-contained MCP server for the Python-SDK integration tests (stdio transport).
#
# Exposes two tools (echo, add) and one resource so the cross-language client can
# exercise tools/list, tools/call (string + numeric args), resources/list and
# resources/read. NOTHING may be written to stdout before start! — it owns the
# stdin/stdout JSON-RPC stream and a stray println would corrupt the wire. Pkg and
# precompile chatter go to stderr (and the MCPLogger), which is fine.
using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."); io = devnull)

using ModelContextProtocol

echo_tool = MCPTool(
    name = "echo",
    description = "Echo the input text",
    parameters = [
        ToolParameter(name = "text", description = "Text to echo", type = "string", required = true),
    ],
    handler = (args) -> TextContent(text = "Echo: $(args["text"])"),
    return_type = TextContent,
)

add_tool = MCPTool(
    name = "add",
    description = "Add two numbers",
    parameters = [
        ToolParameter(name = "a", description = "First addend", type = "number", required = true),
        ToolParameter(name = "b", description = "Second addend", type = "number", required = true),
    ],
    handler = (args) -> TextContent(text = string(args["a"] + args["b"])),
    return_type = TextContent,
)

data_resource = MCPResource(
    uri = "test://integration/data",
    name = "Integration Test Data",
    description = "Static JSON data resource for integration testing",
    mime_type = "application/json",
    data_provider = () -> Dict("answer" => 42, "source" => "julia"),
)

server = mcp_server(
    name = "julia-integration-test-server",
    version = "1.0.0",
    description = "Server exercised by the Python-SDK cross-language integration tests",
    tools = [echo_tool, add_tool],
    resources = [data_resource],
)

start!(server)

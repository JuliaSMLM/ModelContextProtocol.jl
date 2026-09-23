# examples/mcp_tools/julia_version.jl
using JSON

# Define a tool - now with simplified return
julia_version_tool = MCPTool(
    name = "julia_version",
    description = "Get the Julia version used to run this tool",
    parameters = [],
    # Return Dict directly - it will be automatically converted to TextContent
    handler = params -> Dict("version" => string(VERSION)),
    return_type = TextContent  # Explicitly expect single TextContent
)
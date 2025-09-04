# examples/reg_dir_immediate.jl
# Alternative approach: Register components immediately but with minimal upfront cost
using ModelContextProtocol

# Initialize shared storage in Main
if !isdefined(Main, :storage)
    global storage
    Main.storage = Dict{String, Any}()
end

# Create simple lightweight tools that defer compilation until first use
simple_version_tool = MCPTool(
    name = "julia_version",
    description = "Get the Julia version used to run this tool",
    parameters = [],
    handler = args -> "Julia $(VERSION)"
)

simple_echo_tool = MCPTool(
    name = "echo", 
    description = "Echo back a message",
    parameters = [
        ToolParameter(name="message", type="string", description="Message to echo", required=true)
    ],
    handler = args -> "Echo: $(get(args, "message", ""))"
)

# Create server with simple tools immediately
server = mcp_server(
    name = "mcp_tools_directory",
    description = "example mcp tools",
    tools = [simple_version_tool, simple_echo_tool]
)

# Start the server
start!(server)
# examples/reg_dir.jl
# 
# Demonstrates auto-registration of MCP components from a directory structure
# This example automatically loads components from mcp_tools/ subdirectories:
#   - mcp_tools/tools/     - .jl files defining MCPTool instances
#   - mcp_tools/resources/ - .jl files defining MCPResource instances
#   - mcp_tools/prompts/   - .jl files defining MCPPrompt instances
# Each .jl file should define one or more MCP components that will be auto-registered

using ModelContextProtocol

# Initialize shared storage in Main
# This allows tools in the mcp_tools directory to share state
if !isdefined(Main, :storage)
    global storage  # Declare `storage` as a global variable
    Main.storage = Dict{String, Any}()  # Assign it to `Main`
end

# Create and start server with all components
# The auto_register_dir parameter tells the server to automatically scan
# mcp_tools/ for subdirectories (tools/, resources/, prompts/) and load
# all .jl files from each subdirectory, registering the MCP components they define
server = mcp_server(
    name = "mcp_tools_directory",
    description = "example mcp tools",
    auto_register_dir=joinpath(@__DIR__, "mcp_tools")
)

# Start the server
start!(server)
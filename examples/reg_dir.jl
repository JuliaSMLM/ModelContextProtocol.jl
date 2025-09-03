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

# Create server without auto-registration to avoid initialization delays
server = mcp_server(
    name = "mcp_tools_directory",
    description = "example mcp tools"
)

# Schedule async auto-registration to happen after server starts
# This ensures initialize responds quickly while components are registered in background
@async begin
    sleep(0.1)  # Small delay to ensure server is ready
    @info "Auto-registering components from $(joinpath(@__DIR__, "mcp_tools"))"
    ModelContextProtocol.auto_register!(server, joinpath(@__DIR__, "mcp_tools"))
    @info "Auto-registration completed"
end

# Start the server
start!(server)
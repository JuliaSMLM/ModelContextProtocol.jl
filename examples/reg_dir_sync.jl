# examples/reg_dir_sync.jl
# Test version with no async - sync auto-registration but optimized for speed
using ModelContextProtocol

# Initialize shared storage
if !isdefined(Main, :storage)
    global storage
    Main.storage = Dict{String, Any}()
end

# Create server with synchronous auto-registration
# This will help us test if the async is causing the Windows issue
server = mcp_server(
    name = "mcp_tools_directory", 
    description = "example mcp tools",
    auto_register_dir = joinpath(@__DIR__, "mcp_tools")
)

start!(server)
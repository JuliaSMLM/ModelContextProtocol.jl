# examples/reg_dir.jl

using Pkg
Pkg.activate(@__DIR__)

using ModelContextProtocol

# Initialize shared storage in Main
if !isdefined(Main, :storage)
    global storage  # Declare `storage` as a global variable
    Main.storage = Dict{String, Any}()  # Assign it to `Main`
end



# Create and start server with all components
server = mcp_server(
    name = "mcp_tools_directory",
    description = "example mcp tools",
    auto_register_dir=joinpath(@__DIR__, "mcp_tools")
)

# Start the server
start!(server)
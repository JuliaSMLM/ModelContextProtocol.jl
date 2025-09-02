#!/usr/bin/env julia

# examples/reg_dir_http.jl
# 
# Demonstrates auto-registration of MCP components from a directory structure
# using Streamable HTTP transport instead of stdio
#
# This example automatically loads components from mcp_tools/ subdirectories:
#   - mcp_tools/tools/     - .jl files defining MCPTool instances
#   - mcp_tools/resources/ - .jl files defining MCPResource instances  
#   - mcp_tools/prompts/   - .jl files defining MCPPrompt instances
# Each .jl file should define one or more MCP components that will be auto-registered

using ModelContextProtocol
using ModelContextProtocol: HttpTransport

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
    name = "mcp_tools_directory_http",
    description = "Auto-registered MCP tools via HTTP",
    auto_register_dir=joinpath(@__DIR__, "mcp_tools")
)

# Create HTTP transport
transport = HttpTransport(
    host = "127.0.0.1",
    port = 3004,
    endpoint = "/",
    protocol_version = "2025-03-26"
)

# Set the transport on the server
server.transport = transport

# Connect the transport (starts HTTP server)
ModelContextProtocol.connect(transport)

println("Starting HTTP MCP server with auto-registered components on http://127.0.0.1:3004")
println("Components loaded from: $(joinpath(@__DIR__, "mcp_tools"))")
println()
println("Test with:")
println("  curl -X POST http://127.0.0.1:3004/ -H 'Content-Type: application/json' \\")
println("    -H 'MCP-Protocol-Version: 2025-03-26' \\")
println("    -d '{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{},\"id\":1}'")
println()
println("Press Ctrl+C to stop the server")

# Start the server
start!(server)
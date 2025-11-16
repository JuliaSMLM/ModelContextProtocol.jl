using Test
using ModelContextProtocol
using JSON3, URIs, DataStructures, Logging, Base64, HTTP
using OrderedCollections: LittleDict

# Only import internals that are actually needed for specific tests
using ModelContextProtocol: ServerState, process_message  # For backward compat tests
using ModelContextProtocol: ServerConfig, ResourceCapability, ToolCapability  # For server config tests
using ModelContextProtocol: handle_initialize, handle_read_resource, handle_list_resources, handle_get_prompt, handle_call_tool, handle_ping  # For handler tests
using ModelContextProtocol: RequestContext, CallToolResult, content2dict  # For handler tests
using ModelContextProtocol: InitializeParams, InitializeResult, ClientCapabilities, Implementation  # For integration tests
using ModelContextProtocol: JSONRPCRequest, JSONRPCResponse, JSONRPCError, ReadResourceParams, ReadResourceResult, GetPromptParams, GetPromptResult  # For integration tests
using ModelContextProtocol: HandlerResult, CallToolParams, ListResourcesParams  # For integration tests
using ModelContextProtocol: user, assistant  # For role constants
using ModelContextProtocol: PromptCapability  # For server tests
using ModelContextProtocol: MCPLogger  # For logging tests

@testset "ModelContextProtocol.jl" begin
    include("core/types.jl")
    include("core/server.jl")
    include("features/tools.jl") 
    include("features/resources.jl")
    include("features/prompts.jl")
    include("features/auto_register.jl")
    include("protocol/jsonrpc.jl")
    include("protocol/handlers.jl")
    include("protocol/parameters.jl")
    include("utils/serialization.jl")
    include("utils/logging.jl")
    include("transports/test_stdio.jl")
    include("transports/test_http.jl")
    include("transports/test_streamable_http.jl")
    include("integration/full_server.jl")
end
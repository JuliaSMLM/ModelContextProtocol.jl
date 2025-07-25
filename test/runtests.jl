using Test
using ModelContextProtocol
using ModelContextProtocol: handle_initialize, handle_read_resource, handle_list_resources, handle_get_prompt, handle_ping, handle_call_tool, RequestContext, CallToolParams, CallToolResult, content2dict
using JSON3, URIs, DataStructures, Logging, Base64, HTTP
using OrderedCollections: LittleDict

@testset "ModelContextProtocol.jl" begin
    include("core/types.jl")
    include("core/server.jl")
    include("features/tools.jl") 
    include("features/resources.jl")
    include("features/prompts.jl")
    include("protocol/jsonrpc.jl")
    include("protocol/handlers.jl")
    include("protocol/parameters.jl")
    include("utils/serialization.jl")
    include("utils/logging.jl")
    include("transports/test_stdio.jl")
    include("transports/test_http.jl")
    include("integration/full_server.jl")
end
using Test
using ModelContextProtocol
using JSON3, URIs, DataStructures, Logging, Base64, HTTP, Dates
using OrderedCollections: LittleDict

# Only import internals that are actually needed for specific tests
using ModelContextProtocol: ServerState, process_message  # For backward compat tests
using ModelContextProtocol: ServerConfig, ResourceCapability, ToolCapability  # For server config tests
using ModelContextProtocol: handle_initialize, handle_read_resource, handle_list_resources, handle_get_prompt, handle_call_tool, handle_ping, handle_list_tools, handle_list_prompts  # For handler tests
using ModelContextProtocol: RequestContext, CallToolResult, content2dict  # For handler tests
using ModelContextProtocol: InitializeParams, InitializeResult, ClientCapabilities, Implementation  # For integration tests
using ModelContextProtocol: JSONRPCRequest, JSONRPCResponse, JSONRPCError, ReadResourceParams, ReadResourceResult, GetPromptParams, GetPromptResult  # For integration tests
using ModelContextProtocol: HandlerResult, CallToolParams, ListResourcesParams, ListToolsParams, ListPromptsParams  # For integration tests
using ModelContextProtocol: user, assistant  # For role constants
using ModelContextProtocol: PromptCapability  # For server tests
using ModelContextProtocol: MCPLogger  # For logging tests
using ModelContextProtocol: add_token!, decode_jwt_payload, auth_error_response, check_allowlist  # For OAuth Resource Server tests
using ModelContextProtocol: GitHubOAuthValidatorWithOrg, GITHUB_API_URL  # For GitHub validator tests
using ModelContextProtocol: WELL_KNOWN_PATH, handle_well_known_request  # For protected-resource-metadata tests

# End-to-end tests spawn the example servers as real subprocesses (slow JIT
# startup), so they run locally by default and are skipped on CI. Force either
# way with MCP_TEST_E2E. GitHub Actions sets CI=true, which Pkg.test inherits.
const ON_CI   = get(ENV, "CI", "false") == "true"
const RUN_E2E = get(ENV, "MCP_TEST_E2E", ON_CI ? "false" : "true") == "true"

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
    include("protocol/test_versioning.jl")
    include("utils/serialization.jl")
    include("utils/logging.jl")
    include("transports/test_stdio.jl")
    include("transports/test_http.jl")
    include("transports/test_streamable_http.jl")
    include("integration/full_server.jl")
    include("auth/test_auth.jl")

    if RUN_E2E
        include("e2e/test_protocol_e2e.jl")
    else
        @info "Skipping E2E protocol tests (local-only; set MCP_TEST_E2E=true to run, e.g. in the nightly CI job)"
    end
end
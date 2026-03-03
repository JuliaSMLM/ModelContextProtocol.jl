using Test
using ModelContextProtocol
using JSON3, URIs, DataStructures, Logging, Base64, HTTP, Dates
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
using ModelContextProtocol: add_token!, decode_jwt_payload, auth_error_response, check_allowlist  # For auth tests
using ModelContextProtocol: GitHubOAuthValidatorWithOrg, GITHUB_API_URL  # For GitHub auth tests
using ModelContextProtocol: WELL_KNOWN_PATH, handle_well_known_request  # For HTTP auth tests
using ModelContextProtocol: constant_time_compare, base64url_encode  # For PKCE tests
using ModelContextProtocol: OAuthErrorCodes, PendingAuthorization, AuthorizationCode, IssuedToken  # For OAuth server tests
using ModelContextProtocol: is_oauth_endpoint, handle_oauth_request, get_callback_uri  # For OAuth server tests
using ModelContextProtocol: AUTHORIZATION_SERVER_METADATA_PATH, OPENID_CONFIGURATION_PATH  # For metadata tests
using ModelContextProtocol: build_authorization_server_metadata, is_authorization_server_metadata_path  # For metadata tests
using ModelContextProtocol: store_pending!, get_pending, delete_pending!, store_auth_code!, get_auth_code, delete_auth_code!  # For storage tests
using ModelContextProtocol: store_token!, get_token, delete_token!, get_token_by_refresh, cleanup_expired!  # For storage tests
using ModelContextProtocol: store_client!, get_client, delete_client!  # For DCR storage tests
using ModelContextProtocol: negotiate_version, is_supported_version  # For versioning tests

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
    include("auth/test_oauth_server.jl")
end
# src/auth/oauth_server/oauth_server.jl
# OAuth 2.1 Authorization Server for MCP
# Implements MCP 2025-11-25 authorization specification

# Include components in dependency order
include("types.jl")
include("pkce.jl")
include("storage.jl")
include("dcr.jl")        # Dynamic Client Registration (RFC 7591)
include("metadata.jl")
include("upstream.jl")
include("endpoints.jl")
include("server.jl")

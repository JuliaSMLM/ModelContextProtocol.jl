# src/auth/oauth_server/types.jl
# Core types for OAuth 2.1 Authorization Server implementation
# Implements MCP 2025-11-25 authorization specification

using Dates: DateTime, now, UTC, Second
using Random: randstring

"""
    OAuthServerConfig(; issuer, token_endpoint, authorization_endpoint, ...)

Configuration for the OAuth 2.1 Authorization Server.

# Fields
- `issuer::String`: The authorization server's issuer identifier (your server URL)
- `authorization_endpoint::String`: URL for the authorization endpoint
- `token_endpoint::String`: URL for the token endpoint
- `registration_endpoint::Union{String,Nothing}`: URL for dynamic client registration (optional)
- `response_types_supported::Vector{String}`: Supported response types (default: ["code"])
- `grant_types_supported::Vector{String}`: Supported grant types
- `code_challenge_methods_supported::Vector{String}`: Supported PKCE methods (must include "S256")
- `token_endpoint_auth_methods_supported::Vector{String}`: Supported client auth methods
- `scopes_supported::Vector{String}`: Supported OAuth scopes
- `access_token_ttl::Int`: Access token lifetime in seconds (default: 3600)
- `refresh_token_ttl::Int`: Refresh token lifetime in seconds (default: 30 days)
- `authorization_code_ttl::Int`: Authorization code lifetime in seconds (default: 600)
"""
Base.@kwdef struct OAuthServerConfig
    issuer::String
    authorization_endpoint::String
    token_endpoint::String
    registration_endpoint::Union{String,Nothing} = nothing

    # Supported features per OAuth 2.1 / MCP spec
    response_types_supported::Vector{String} = ["code"]
    grant_types_supported::Vector{String} = ["authorization_code", "refresh_token"]
    code_challenge_methods_supported::Vector{String} = ["S256"]
    token_endpoint_auth_methods_supported::Vector{String} = ["none", "client_secret_post"]
    scopes_supported::Vector{String} = String[]

    # Token lifetimes
    access_token_ttl::Int = 3600              # 1 hour
    refresh_token_ttl::Int = 86400 * 30       # 30 days
    authorization_code_ttl::Int = 600         # 10 minutes
end

function Base.show(io::IO, config::OAuthServerConfig)
    print(io, "OAuthServerConfig(issuer=", config.issuer, ")")
end

"""
    UpstreamOAuthProvider

Abstract type for upstream OAuth providers (GitHub, Google, etc.).
Upstream providers handle the actual user authentication.
"""
abstract type UpstreamOAuthProvider end

"""
    TokenStorage

Abstract type for token and authorization code storage.
Implementations can use in-memory, Redis, database, etc.
"""
abstract type TokenStorage end

"""
    AuthorizationRequest(; client_id, redirect_uri, response_type, state, ...)

Parsed authorization request from an MCP client.

# Fields
- `client_id::String`: Client identifier (URL for CIMD or registered ID)
- `redirect_uri::String`: Where to redirect after authorization
- `response_type::String`: Must be "code" for authorization code flow
- `state::String`: Opaque state value for CSRF protection
- `code_challenge::String`: PKCE code challenge
- `code_challenge_method::String`: PKCE method (should be "S256")
- `resource::String`: Target resource (RFC 8707)
- `scope::Union{String,Nothing}`: Requested scopes (space-separated)
"""
Base.@kwdef struct AuthorizationRequest
    client_id::String
    redirect_uri::String
    response_type::String
    state::String
    code_challenge::String
    code_challenge_method::String
    resource::String
    scope::Union{String,Nothing} = nothing
end

function Base.show(io::IO, req::AuthorizationRequest)
    print(io, "AuthorizationRequest(client_id=", req.client_id, ", resource=", req.resource, ")")
end

"""
    PendingAuthorization(; state, client_id, redirect_uri, ...)

Stored state for an in-progress authorization flow.
Created when /authorize is called, consumed when upstream callback arrives.

# Fields
- `state::String`: Original state from client (used as lookup key)
- `client_id::String`: Client identifier
- `redirect_uri::String`: Client's redirect URI
- `code_challenge::String`: PKCE code challenge
- `code_challenge_method::String`: PKCE method
- `resource::String`: Target resource
- `scope::Vector{String}`: Requested scopes
- `created_at::DateTime`: When this was created
- `upstream_state::String`: State value sent to upstream provider
"""
Base.@kwdef struct PendingAuthorization
    state::String
    client_id::String
    redirect_uri::String
    code_challenge::String
    code_challenge_method::String
    resource::String
    scope::Vector{String} = String[]
    created_at::DateTime = now(UTC)
    upstream_state::String = randstring(32)
end

function Base.show(io::IO, pending::PendingAuthorization)
    print(io, "PendingAuthorization(client_id=", pending.client_id, ")")
end

"""
    AuthorizationCode(; code, client_id, redirect_uri, ...)

An issued authorization code, to be exchanged for tokens.

# Fields
- `code::String`: The authorization code value
- `client_id::String`: Client that requested authorization
- `redirect_uri::String`: Redirect URI used in authorization request
- `code_challenge::String`: PKCE code challenge (for verification)
- `code_challenge_method::String`: PKCE method
- `resource::String`: Target resource
- `user::AuthenticatedUser`: The authenticated user
- `scope::Vector{String}`: Granted scopes
- `created_at::DateTime`: When code was issued
- `expires_at::DateTime`: When code expires
"""
Base.@kwdef struct AuthorizationCode
    code::String
    client_id::String
    redirect_uri::String
    code_challenge::String
    code_challenge_method::String
    resource::String
    user::AuthenticatedUser
    scope::Vector{String} = String[]
    created_at::DateTime = now(UTC)
    expires_at::DateTime
end

function Base.show(io::IO, code::AuthorizationCode)
    print(io, "AuthorizationCode(client_id=", code.client_id, ", user=", code.user.username, ")")
end

"""
    IssuedToken(; access_token, token_type, user, client_id, ...)

An issued access token with associated metadata.

# Fields
- `access_token::String`: The access token value
- `token_type::String`: Token type (always "Bearer")
- `user::AuthenticatedUser`: The authenticated user
- `client_id::String`: Client the token was issued to
- `scope::Vector{String}`: Granted scopes
- `resource::String`: Target resource this token is valid for
- `created_at::DateTime`: When token was issued
- `expires_at::DateTime`: When token expires
- `refresh_token::Union{String,Nothing}`: Associated refresh token
"""
Base.@kwdef struct IssuedToken
    access_token::String
    token_type::String = "Bearer"
    user::AuthenticatedUser
    client_id::String
    scope::Vector{String} = String[]
    resource::String
    created_at::DateTime = now(UTC)
    expires_at::DateTime
    refresh_token::Union{String,Nothing} = nothing
end

function Base.show(io::IO, token::IssuedToken)
    print(io, "IssuedToken(user=", token.user.username, ", expires=", token.expires_at, ")")
end

"""
    TokenRequest(; grant_type, code, redirect_uri, code_verifier, ...)

Parsed token request from an MCP client.

# Fields
- `grant_type::String`: "authorization_code" or "refresh_token"
- `code::Union{String,Nothing}`: Authorization code (for authorization_code grant)
- `redirect_uri::Union{String,Nothing}`: Redirect URI (must match authorization request)
- `code_verifier::Union{String,Nothing}`: PKCE code verifier
- `refresh_token::Union{String,Nothing}`: Refresh token (for refresh_token grant)
- `client_id::Union{String,Nothing}`: Client identifier
- `resource::Union{String,Nothing}`: Target resource (RFC 8707)
- `scope::Union{String,Nothing}`: Requested scopes (for refresh, may be subset)
"""
Base.@kwdef struct TokenRequest
    grant_type::String
    code::Union{String,Nothing} = nothing
    redirect_uri::Union{String,Nothing} = nothing
    code_verifier::Union{String,Nothing} = nothing
    refresh_token::Union{String,Nothing} = nothing
    client_id::Union{String,Nothing} = nothing
    resource::Union{String,Nothing} = nothing
    scope::Union{String,Nothing} = nothing
end

function Base.show(io::IO, req::TokenRequest)
    print(io, "TokenRequest(grant_type=", req.grant_type, ")")
end

"""
    TokenResponse(; access_token, token_type, expires_in, ...)

Token endpoint success response.

# Fields
- `access_token::String`: The issued access token
- `token_type::String`: Token type (always "Bearer")
- `expires_in::Int`: Token lifetime in seconds
- `refresh_token::Union{String,Nothing}`: Refresh token (if issued)
- `scope::Union{String,Nothing}`: Granted scopes (space-separated)
"""
Base.@kwdef struct TokenResponse
    access_token::String
    token_type::String = "Bearer"
    expires_in::Int
    refresh_token::Union{String,Nothing} = nothing
    scope::Union{String,Nothing} = nothing
end

function Base.show(io::IO, resp::TokenResponse)
    print(io, "TokenResponse(expires_in=", resp.expires_in, "s)")
end

"""
    OAuthError(; error, error_description, error_uri)

OAuth error response per RFC 6749.

# Fields
- `error::String`: Error code (e.g., "invalid_request", "invalid_grant")
- `error_description::Union{String,Nothing}`: Human-readable error description
- `error_uri::Union{String,Nothing}`: URI for more information
"""
Base.@kwdef struct OAuthError
    error::String
    error_description::Union{String,Nothing} = nothing
    error_uri::Union{String,Nothing} = nothing
end

function Base.show(io::IO, err::OAuthError)
    print(io, "OAuthError(", err.error, ")")
end

"""
    RegisteredClient

A dynamically registered OAuth client per RFC 7591.

# Fields
- `client_id::String`: Unique client identifier
- `client_secret::Union{String,Nothing}`: Client secret (for confidential clients)
- `client_name::Union{String,Nothing}`: Human-readable client name
- `redirect_uris::Vector{String}`: Allowed redirect URIs
- `grant_types::Vector{String}`: Allowed grant types
- `response_types::Vector{String}`: Allowed response types
- `token_endpoint_auth_method::String`: Authentication method for token endpoint
- `created_at::DateTime`: Registration timestamp
"""
Base.@kwdef struct RegisteredClient
    client_id::String
    client_secret::Union{String,Nothing} = nothing
    client_name::Union{String,Nothing} = nothing
    redirect_uris::Vector{String} = String[]
    grant_types::Vector{String} = ["authorization_code", "refresh_token"]
    response_types::Vector{String} = ["code"]
    token_endpoint_auth_method::String = "none"  # Public client by default
    created_at::DateTime = now(UTC)
end

function Base.show(io::IO, client::RegisteredClient)
    print(io, "RegisteredClient(id=", client.client_id, ", name=", something(client.client_name, "unnamed"), ")")
end

# Standard OAuth error codes
module OAuthErrorCodes
    const INVALID_REQUEST = "invalid_request"
    const INVALID_CLIENT = "invalid_client"
    const INVALID_GRANT = "invalid_grant"
    const UNAUTHORIZED_CLIENT = "unauthorized_client"
    const UNSUPPORTED_GRANT_TYPE = "unsupported_grant_type"
    const INVALID_SCOPE = "invalid_scope"
    const ACCESS_DENIED = "access_denied"
    const UNSUPPORTED_RESPONSE_TYPE = "unsupported_response_type"
    const SERVER_ERROR = "server_error"
    const TEMPORARILY_UNAVAILABLE = "temporarily_unavailable"
end

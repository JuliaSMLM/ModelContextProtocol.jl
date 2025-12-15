# src/auth/auth.jl
# OAuth 2.0 Authorization Framework for MCP
# Implements MCP 2025-11-25 authorization specification

"""
    AuthProvider

Abstract type for authentication providers (GitHub, Google, custom OAuth servers).
"""
abstract type AuthProvider end

"""
    TokenValidator

Abstract type for token validation strategies (JWT, introspection).
"""
abstract type TokenValidator end

"""
    AuthenticatedUser(; subject::String, provider::String,
                      username::Union{String,Nothing}=nothing,
                      scopes::Vector{String}=String[],
                      claims::Dict{String,Any}=Dict{String,Any}())

Represent an authenticated user after successful token validation.

# Fields
- `subject::String`: Unique user identifier (sub claim from token)
- `provider::String`: Authentication provider name (e.g., "github", "google")
- `username::Union{String,Nothing}`: Human-readable username if available
- `scopes::Vector{String}`: Granted OAuth scopes
- `claims::Dict{String,Any}`: Raw claims from the token
"""
Base.@kwdef struct AuthenticatedUser
    subject::String
    provider::String
    username::Union{String,Nothing} = nothing
    scopes::Vector{String} = String[]
    claims::Dict{String,Any} = Dict{String,Any}()
end

"""
    OAuthConfig(; issuer::String, audience::String,
                 required_scopes::Vector{String}=String[],
                 jwks_uri::Union{String,Nothing}=nothing,
                 introspection_endpoint::Union{String,Nothing}=nothing)

Configure OAuth 2.0 token validation for an MCP server.

# Fields
- `issuer::String`: Expected token issuer (iss claim)
- `audience::String`: Expected audience (aud claim) - typically your server's URL
- `required_scopes::Vector{String}`: Scopes required to access the server
- `jwks_uri::Union{String,Nothing}`: URL to fetch JSON Web Key Set for JWT validation
- `introspection_endpoint::Union{String,Nothing}`: Token introspection endpoint URL
"""
Base.@kwdef struct OAuthConfig
    issuer::String
    audience::String
    required_scopes::Vector{String} = String[]
    jwks_uri::Union{String,Nothing} = nothing
    introspection_endpoint::Union{String,Nothing} = nothing
end

"""
    AuthResult

Result of an authentication attempt.
"""
struct AuthResult
    success::Bool
    user::Union{AuthenticatedUser,Nothing}
    error::Union{String,Nothing}
    error_code::Union{Symbol,Nothing}  # :invalid_token, :expired, :insufficient_scope, etc.
end

# Convenience constructors
AuthResult(user::AuthenticatedUser) = AuthResult(true, user, nothing, nothing)
AuthResult(error::String, code::Symbol) = AuthResult(false, nothing, error, code)

"""
    AuthMiddleware(; config::OAuthConfig,
                    validator::TokenValidator,
                    allowlist::Union{Set{String},Nothing}=nothing,
                    enabled::Bool=true)

Middleware for authenticating HTTP requests to an MCP server.

# Fields
- `config::OAuthConfig`: OAuth configuration
- `validator::TokenValidator`: Token validation strategy
- `allowlist::Union{Set{String},Nothing}`: Optional set of allowed usernames/subjects
- `enabled::Bool`: Whether authentication is enabled (for development/testing)
"""
Base.@kwdef mutable struct AuthMiddleware
    config::OAuthConfig
    validator::TokenValidator
    allowlist::Union{Set{String},Nothing} = nothing
    enabled::Bool = true
end

"""
    ProtectedResourceMetadata(; resource::String,
                               authorization_servers::Vector{String},
                               scopes_supported::Vector{String}=String[],
                               bearer_methods_supported::Vector{String}=["header"])

MCP Protected Resource Metadata per RFC 9728.
Served at `.well-known/oauth-protected-resource`.

# Fields
- `resource::String`: The protected resource identifier (your server URL)
- `authorization_servers::Vector{String}`: URLs of authorization servers that can issue tokens
- `scopes_supported::Vector{String}`: OAuth scopes the resource understands
- `bearer_methods_supported::Vector{String}`: How tokens can be sent (header, body, query)
"""
Base.@kwdef struct ProtectedResourceMetadata
    resource::String
    authorization_servers::Vector{String}
    scopes_supported::Vector{String} = String[]
    bearer_methods_supported::Vector{String} = ["header"]
end

"""
    extract_bearer_token(authorization_header::String) -> Union{String,Nothing}

Extract Bearer token from Authorization header.

# Arguments
- `authorization_header::String`: The Authorization header value

# Returns
- `Union{String,Nothing}`: The token if present and valid format, nothing otherwise
"""
function extract_bearer_token(authorization_header::String)::Union{String,Nothing}
    if startswith(authorization_header, "Bearer ")
        return strip(authorization_header[8:end])
    end
    return nothing
end

"""
    validate_token(validator::TokenValidator, token::String, config::OAuthConfig) -> AuthResult

Validate an OAuth token using the specified validator.

# Arguments
- `validator::TokenValidator`: The validation strategy to use
- `token::String`: The token to validate
- `config::OAuthConfig`: OAuth configuration with expected issuer, audience, etc.

# Returns
- `AuthResult`: Success with user info, or failure with error details
"""
function validate_token end  # To be implemented by concrete validators

"""
    check_allowlist(user::AuthenticatedUser, allowlist::Set{String}) -> Bool

Check if user is in the allowlist.

# Arguments
- `user::AuthenticatedUser`: The authenticated user
- `allowlist::Set{String}`: Set of allowed usernames or subjects

# Returns
- `Bool`: true if user is allowed
"""
function check_allowlist(user::AuthenticatedUser, allowlist::Set{String})::Bool
    # Check both username and subject
    if !isnothing(user.username) && user.username in allowlist
        return true
    end
    return user.subject in allowlist
end

"""
    authenticate_request(middleware::AuthMiddleware, authorization_header::Union{String,Nothing}) -> AuthResult

Authenticate an HTTP request using the auth middleware.

# Arguments
- `middleware::AuthMiddleware`: The authentication middleware
- `authorization_header::Union{String,Nothing}`: The Authorization header value

# Returns
- `AuthResult`: Authentication result
"""
function authenticate_request(
    middleware::AuthMiddleware,
    authorization_header::Union{String,Nothing}
)::AuthResult
    # Skip if auth disabled
    if !middleware.enabled
        return AuthResult(AuthenticatedUser(
            subject = "anonymous",
            provider = "none",
            username = "anonymous"
        ))
    end

    # Check for Authorization header
    if isnothing(authorization_header) || isempty(authorization_header)
        return AuthResult("Missing Authorization header", :missing_token)
    end

    # Extract Bearer token
    token = extract_bearer_token(authorization_header)
    if isnothing(token)
        return AuthResult("Invalid Authorization header format. Expected: Bearer <token>", :invalid_format)
    end

    # Validate the token
    result = validate_token(middleware.validator, token, middleware.config)
    if !result.success
        return result
    end

    # Check allowlist if configured
    if !isnothing(middleware.allowlist)
        if !check_allowlist(result.user, middleware.allowlist)
            return AuthResult("User not in allowlist", :forbidden)
        end
    end

    return result
end

# Include sub-modules
include("token.jl")
include("middleware.jl")
include("metadata.jl")

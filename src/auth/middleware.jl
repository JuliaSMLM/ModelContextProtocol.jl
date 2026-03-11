# src/auth/middleware.jl
# HTTP authentication middleware integration

"""
    AuthError

Error codes for authentication failures per MCP spec.
"""
module AuthErrors
    const MISSING_TOKEN = 401
    const INVALID_TOKEN = 401
    const EXPIRED_TOKEN = 401
    const INSUFFICIENT_SCOPE = 403
    const FORBIDDEN = 403
end

"""
    auth_error_response(error_code::Symbol, message::String) -> Tuple{Int,String,Dict{String,String}}

Generate HTTP response for authentication errors.

# Returns
- Tuple of (status_code, body, headers)
"""
function auth_error_response(error_code::Symbol, message::String; resource_metadata_url::Union{String,Nothing}=nothing)
    status = if error_code in (:missing_token, :invalid_token, :invalid_format, :expired, :not_yet_valid, :invalid_issuer, :invalid_audience)
        401
    elseif error_code in (:insufficient_scope, :forbidden)
        403
    else
        401
    end

    # WWW-Authenticate header per RFC 6750 and RFC 9728
    # Include resource_metadata URL to help clients discover auth requirements
    www_auth = if error_code == :missing_token
        if !isnothing(resource_metadata_url)
            "Bearer resource_metadata=\"$resource_metadata_url\""
        else
            "Bearer"
        end
    elseif error_code == :insufficient_scope
        base = "Bearer error=\"insufficient_scope\", error_description=\"$message\""
        if !isnothing(resource_metadata_url)
            "$base, resource_metadata=\"$resource_metadata_url\""
        else
            base
        end
    else
        base = "Bearer error=\"invalid_token\", error_description=\"$message\""
        if !isnothing(resource_metadata_url)
            "$base, resource_metadata=\"$resource_metadata_url\""
        else
            base
        end
    end

    headers = Dict{String,String}(
        "WWW-Authenticate" => www_auth,
        "Content-Type" => "application/json"
    )

    body = JSON3.write(Dict(
        "error" => String(error_code),
        "error_description" => message
    ))

    return (status, body, headers)
end

"""
    RequestAuthContext

Authentication context attached to authenticated requests.
"""
Base.@kwdef struct RequestAuthContext
    user::AuthenticatedUser
    token::String
    authenticated_at::DateTime = now(UTC)
end

"""
    create_auth_middleware(config::OAuthConfig;
                          validator::TokenValidator=JWTValidator(),
                          allowlist::Union{Set{String},Nothing}=nothing,
                          enabled::Bool=true) -> AuthMiddleware

Create an authentication middleware for HTTP transport.

# Arguments
- `config::OAuthConfig`: OAuth configuration
- `validator::TokenValidator`: Token validation strategy (default: JWTValidator)
- `allowlist::Union{Set{String},Nothing}`: Optional allowlist of usernames/subjects
- `enabled::Bool`: Whether auth is enabled (default: true)

# Example
```julia
auth = create_auth_middleware(
    OAuthConfig(
        issuer = "https://github.com",
        audience = "my-mcp-server"
    ),
    allowlist = Set(["user1", "user2"])
)
```
"""
function create_auth_middleware(
    config::OAuthConfig;
    validator::TokenValidator = JWTValidator(),
    allowlist::Union{Set{String},Nothing} = nothing,
    enabled::Bool = true
)
    return AuthMiddleware(
        config = config,
        validator = validator,
        allowlist = allowlist,
        enabled = enabled
    )
end

"""
    create_simple_auth(tokens::Dict{String,String};
                      allowlist::Union{Set{String},Nothing}=nothing) -> AuthMiddleware

Create a simple API key-based authentication middleware.

# Arguments
- `tokens::Dict{String,String}`: Map of API keys to usernames
- `allowlist::Union{Set{String},Nothing}`: Optional additional allowlist

# Example
```julia
auth = create_simple_auth(Dict(
    "sk-abc123" => "user1",
    "sk-def456" => "user2"
))
```
"""
function create_simple_auth(
    tokens::Dict{String,String};
    allowlist::Union{Set{String},Nothing} = nothing
)
    validator = SimpleTokenValidator()

    for (token, username) in tokens
        add_token!(validator, token, AuthenticatedUser(
            subject = username,
            provider = "api_key",
            username = username
        ))
    end

    config = OAuthConfig(
        issuer = "local",
        audience = "local"
    )

    return AuthMiddleware(
        config = config,
        validator = validator,
        allowlist = allowlist,
        enabled = true
    )
end

"""
    disable_auth() -> AuthMiddleware

Create a disabled auth middleware (for development/testing).
All requests will be allowed with an anonymous user.
"""
function disable_auth()
    return AuthMiddleware(
        config = OAuthConfig(issuer = "none", audience = "none"),
        validator = SimpleTokenValidator(),
        enabled = false
    )
end

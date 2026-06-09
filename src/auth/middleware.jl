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
    # Map internal validator codes to an HTTP status and a GENERIC, client-facing
    # OAuth error. We deliberately do NOT echo the specific reason (expired vs.
    # wrong issuer vs. malformed vs. which scope) — that would be a token/policy
    # oracle. `message` is retained for the caller / server-side logging only.
    is_scope = error_code === :insufficient_scope
    is_forbidden = is_scope || error_code === :forbidden
    status = is_forbidden ? 403 : 401

    oauth_error = if is_forbidden
        "insufficient_scope"
    elseif error_code === :missing_token
        "invalid_request"
    else
        "invalid_token"
    end
    description = if is_forbidden
        "The request requires higher privileges than the access token provides."
    elseif error_code === :missing_token
        "Authentication required."
    else
        "The access token is missing, invalid, or expired."
    end

    # WWW-Authenticate per RFC 6750 / 9728. Every value comes from a fixed
    # vocabulary or server-controlled config (resource_metadata_url), so there is
    # no untrusted interpolation to escape.
    params = String[]
    if error_code !== :missing_token
        push!(params, "error=\"$(oauth_error)\"")
        push!(params, "error_description=\"$(description)\"")
    end
    if !isnothing(resource_metadata_url)
        push!(params, "resource_metadata=\"$(resource_metadata_url)\"")
    end
    www_auth = isempty(params) ? "Bearer" : "Bearer " * join(params, ", ")

    headers = Dict{String,String}(
        "WWW-Authenticate" => www_auth,
        "Content-Type" => "application/json"
    )
    body = JSON3.write(Dict(
        "error" => oauth_error,
        "error_description" => description
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
                          validator::TokenValidator,
                          allowlist::Union{Set{String},Nothing}=nothing,
                          enabled::Bool=true) -> AuthMiddleware

Create an authentication middleware for the HTTP transport.

# Arguments
- `config::OAuthConfig`: OAuth configuration
- `validator::TokenValidator`: Token validation strategy (REQUIRED — no default, so
  an unsafe validator is never selected implicitly. Note `JWTValidator` does not verify
  signatures; prefer `IntrospectionValidator` or `GitHubOAuthValidator` for tokens from
  external issuers.)
- `allowlist::Union{Set{String},Nothing}`: Optional allowlist of usernames/subjects
- `enabled::Bool`: Whether auth is enabled (default: true)

# Example
```julia
auth = create_auth_middleware(
    OAuthConfig(
        issuer = "https://github.com",
        audience = "my-mcp-server"
    ),
    validator = IntrospectionValidator(client_id = "id", client_secret = "secret"),
    allowlist = Set(["user1", "user2"])
)
```
"""
function create_auth_middleware(
    config::OAuthConfig;
    validator::TokenValidator,
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

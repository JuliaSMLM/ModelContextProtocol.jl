# src/auth/providers/github.jl
# GitHub OAuth provider for MCP authentication

"""
    GITHUB_API_URL

Base URL for GitHub API.
"""
const GITHUB_API_URL = "https://api.github.com"

"""
    GitHubOAuthValidator(; cache_ttl_seconds::Int=300)

Token validator for GitHub OAuth access tokens.
Validates tokens by calling GitHub's /user API endpoint.

# Fields
- `cache_ttl_seconds::Int`: How long to cache user info (default: 5 minutes)
- `user_cache::Dict{String,Tuple{AuthenticatedUser,DateTime}}`: Cache of validated tokens
"""
Base.@kwdef mutable struct GitHubOAuthValidator <: TokenValidator
    cache_ttl_seconds::Int = 300
    user_cache::Dict{String,Tuple{AuthenticatedUser,DateTime}} = Dict{String,Tuple{AuthenticatedUser,DateTime}}()
end

"""
    fetch_github_user(token::String) -> Union{Dict{String,Any},Nothing}

Fetch user information from GitHub API using an access token.
Returns nothing if the token is invalid or the request fails.
"""
function fetch_github_user(token::String)::Union{Dict{String,Any},Nothing}
    try
        response = HTTP.get(
            "$GITHUB_API_URL/user",
            [
                "Authorization" => "Bearer $token",
                "Accept" => "application/vnd.github+json",
                "X-GitHub-Api-Version" => "2022-11-28"
            ]
        )

        if response.status == 200
            return JSON3.read(String(response.body), Dict{String,Any})
        end
        return nothing
    catch e
        if e isa HTTP.StatusError && e.status == 401
            return nothing  # Invalid token
        end
        @warn "GitHub API request failed" exception=e
        return nothing
    end
end

"""
    check_github_org_membership(token::String, org::String) -> Bool

Check if the authenticated user is a member of the specified GitHub organization.
"""
function check_github_org_membership(token::String, org::String)::Bool
    try
        response = HTTP.get(
            "$GITHUB_API_URL/user/memberships/orgs/$org",
            [
                "Authorization" => "Bearer $token",
                "Accept" => "application/vnd.github+json",
                "X-GitHub-Api-Version" => "2022-11-28"
            ]
        )
        return response.status == 200
    catch e
        if e isa HTTP.StatusError && e.status in (404, 403)
            return false  # Not a member or org not found
        end
        @warn "GitHub org membership check failed" exception=e
        return false
    end
end

"""
    validate_token(validator::GitHubOAuthValidator, token::String, config::OAuthConfig) -> AuthResult

Validate a GitHub OAuth access token by calling GitHub's API.
"""
function validate_token(validator::GitHubOAuthValidator, token::String, config::OAuthConfig)::AuthResult
    # Check cache first
    if haskey(validator.user_cache, token)
        user, cached_at = validator.user_cache[token]
        if (now(UTC) - cached_at).value / 1000 < validator.cache_ttl_seconds
            return AuthResult(user)
        else
            delete!(validator.user_cache, token)
        end
    end

    # Fetch user from GitHub
    user_data = fetch_github_user(token)

    if isnothing(user_data)
        return AuthResult("Invalid GitHub token", :invalid_token)
    end

    # Extract username
    username = get(user_data, "login", nothing)
    if isnothing(username)
        return AuthResult("GitHub user has no login", :invalid_token)
    end

    # Build scopes from token (GitHub doesn't expose scopes in /user response)
    # The actual scopes are determined at token creation time
    scopes = String[]

    # Check required scopes if specified in config
    # Note: GitHub access tokens don't expose their scopes via API,
    # so we can only verify permissions by trying operations

    # Build authenticated user
    user = AuthenticatedUser(
        subject = string(get(user_data, "id", username)),
        provider = "github",
        username = username,
        scopes = scopes,
        claims = Dict{String,Any}(
            "login" => username,
            "id" => get(user_data, "id", nothing),
            "name" => get(user_data, "name", nothing),
            "email" => get(user_data, "email", nothing),
            "avatar_url" => get(user_data, "avatar_url", nothing),
            "html_url" => get(user_data, "html_url", nothing)
        )
    )

    # Cache the result
    validator.user_cache[token] = (user, now(UTC))

    return AuthResult(user)
end

"""
    GitHubAuthConfig(; client_id::String,
                      allowed_users::Set{String}=Set{String}(),
                      required_org::Union{String,Nothing}=nothing,
                      cache_ttl_seconds::Int=300)

GitHub OAuth configuration for MCP server authentication.

# Fields
- `client_id::String`: GitHub OAuth App client ID (for documentation/reference)
- `allowed_users::Set{String}`: Set of allowed GitHub usernames (empty = allow all authenticated)
- `required_org::Union{String,Nothing}`: Require membership in this GitHub organization
- `cache_ttl_seconds::Int`: How long to cache validated tokens
"""
Base.@kwdef struct GitHubAuthConfig
    client_id::String = ""
    allowed_users::Set{String} = Set{String}()
    required_org::Union{String,Nothing} = nothing
    cache_ttl_seconds::Int = 300
end

"""
    create_github_auth(; allowed_users::Union{Vector{String},Set{String}}=String[],
                        required_org::Union{String,Nothing}=nothing,
                        cache_ttl_seconds::Int=300) -> AuthMiddleware

Create an authentication middleware configured for GitHub OAuth.

# Arguments
- `allowed_users`: List of GitHub usernames allowed to access the server
- `required_org`: Optionally require membership in a GitHub organization
- `cache_ttl_seconds`: How long to cache validated tokens (default: 5 minutes)

# Returns
`AuthMiddleware` configured for GitHub OAuth validation.

# Example
```julia
# Allow specific users
auth = create_github_auth(
    allowed_users = ["user1", "user2", "user3"]
)

# Require organization membership
auth = create_github_auth(
    required_org = "JuliaSMLM"
)

# Both user allowlist and org requirement
auth = create_github_auth(
    allowed_users = ["user1", "user2"],
    required_org = "LidkeLab"
)
```
"""
function create_github_auth(;
    allowed_users::Union{Vector{String},Set{String}} = String[],
    required_org::Union{String,Nothing} = nothing,
    cache_ttl_seconds::Int = 300
)::AuthMiddleware
    # Convert to Set if needed
    allowlist = if allowed_users isa Set
        allowed_users
    elseif isempty(allowed_users)
        nothing  # No allowlist = allow all authenticated users
    else
        Set(allowed_users)
    end

    validator = GitHubOAuthValidatorWithOrg(
        base_validator = GitHubOAuthValidator(cache_ttl_seconds = cache_ttl_seconds),
        required_org = required_org
    )

    config = OAuthConfig(
        issuer = "https://github.com",
        audience = "github"
    )

    return AuthMiddleware(
        config = config,
        validator = validator,
        allowlist = allowlist,
        enabled = true
    )
end

"""
    GitHubOAuthValidatorWithOrg <: TokenValidator

Wrapper validator that adds organization membership checking.

# Fields
- `base_validator::GitHubOAuthValidator`: The underlying GitHub token validator
- `required_org::Union{String,Nothing}`: Required organization membership
"""
Base.@kwdef struct GitHubOAuthValidatorWithOrg <: TokenValidator
    base_validator::GitHubOAuthValidator
    required_org::Union{String,Nothing} = nothing
end

function validate_token(validator::GitHubOAuthValidatorWithOrg, token::String, config::OAuthConfig)::AuthResult
    # First validate the token with base validator
    result = validate_token(validator.base_validator, token, config)

    if !result.success
        return result
    end

    # Check org membership if required
    if !isnothing(validator.required_org)
        if !check_github_org_membership(token, validator.required_org)
            return AuthResult(
                "User is not a member of required organization: $(validator.required_org)",
                :forbidden
            )
        end
    end

    return result
end

"""
    clear_cache!(validator::GitHubOAuthValidator)

Clear the token validation cache.
"""
function clear_cache!(validator::GitHubOAuthValidator)
    empty!(validator.user_cache)
end

function clear_cache!(validator::GitHubOAuthValidatorWithOrg)
    clear_cache!(validator.base_validator)
end

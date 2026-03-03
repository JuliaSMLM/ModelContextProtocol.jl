# src/auth/providers/github.jl
# GitHub OAuth provider for MCP authentication

using Dates: DateTime, now, UTC, Second

"""
    GITHUB_API_URL

Base URL for GitHub API.
"""
const GITHUB_API_URL::String = "https://api.github.com"

"""
    GitHubOAuthValidator(; cache_ttl_seconds::Int=300)

Token validator for GitHub OAuth access tokens.
Validates tokens by calling GitHub's /user API endpoint.

# Fields
- `cache_ttl_seconds::Int`: How long to cache user info (default: 5 minutes)
- `user_cache::Dict{String,Tuple{AuthenticatedUser,DateTime}}`: Cache of validated tokens
- `cache_lock::ReentrantLock`: Lock for thread-safe cache access
"""
struct GitHubOAuthValidator <: TokenValidator
    cache_ttl_seconds::Int
    user_cache::Dict{String,Tuple{AuthenticatedUser,DateTime}}
    cache_lock::ReentrantLock
end

function GitHubOAuthValidator(; cache_ttl_seconds::Int=300)
    GitHubOAuthValidator(
        cache_ttl_seconds,
        Dict{String,Tuple{AuthenticatedUser,DateTime}}(),
        ReentrantLock()
    )
end

function Base.show(io::IO, v::GitHubOAuthValidator)
    cached = lock(v.cache_lock) do
        length(v.user_cache)
    end
    print(io, "GitHubOAuthValidator(ttl=", v.cache_ttl_seconds, "s, cached=", cached, ")")
end

"""
    fetch_github_user(token::String) -> Union{Dict{String,Any},Nothing}

Fetch user information from GitHub API using an access token.
Returns `nothing` if the token is invalid or the request fails.
"""
function fetch_github_user(token::String)
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
        if e isa HTTP.StatusError
            # 401 = invalid token, other status codes are also failures
            return nothing
        elseif e isa HTTP.RequestError
            @warn "GitHub API request failed" exception=(e, catch_backtrace())
            return nothing
        else
            rethrow(e)
        end
    end
end

"""
    check_github_org_membership(token::String, org::String) -> Bool

Check if the authenticated user is a member of the specified GitHub organization.
"""
function check_github_org_membership(token::String, org::String)
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
        if e isa HTTP.StatusError
            # 404 = not a member, 403 = org not found or no permission
            return false
        elseif e isa HTTP.RequestError
            @warn "GitHub org membership check failed" exception=(e, catch_backtrace())
            return false
        else
            rethrow(e)
        end
    end
end

"""
    validate_token(validator::GitHubOAuthValidator, token::AbstractString, config::OAuthConfig) -> AuthResult

Validate a GitHub OAuth access token by calling GitHub's API.
"""
function validate_token(validator::GitHubOAuthValidator, token::AbstractString, config::OAuthConfig)
    token_str = String(token)

    # Check cache first (thread-safe)
    cached_result = lock(validator.cache_lock) do
        if haskey(validator.user_cache, token_str)
            user, cached_at = validator.user_cache[token_str]
            if now(UTC) - cached_at < Second(validator.cache_ttl_seconds)
                return AuthResult(user)
            else
                delete!(validator.user_cache, token_str)
            end
        end
        return nothing
    end

    if !isnothing(cached_result)
        return cached_result
    end

    # Fetch user from GitHub
    user_data = fetch_github_user(token_str)

    if isnothing(user_data)
        return AuthResult("Invalid GitHub token", :invalid_token)
    end

    # Extract username
    username = get(user_data, "login", nothing)
    if isnothing(username)
        return AuthResult("GitHub user has no login", :invalid_token)
    end

    # Build authenticated user
    user = AuthenticatedUser(
        subject = string(get(user_data, "id", username)),
        provider = "github",
        username = username,
        scopes = String[],  # GitHub doesn't expose scopes in /user response
        claims = Dict{String,Any}(
            "login" => username,
            "id" => get(user_data, "id", nothing),
            "name" => get(user_data, "name", nothing),
            "email" => get(user_data, "email", nothing),
            "avatar_url" => get(user_data, "avatar_url", nothing),
            "html_url" => get(user_data, "html_url", nothing)
        )
    )

    # Cache the result (thread-safe)
    lock(validator.cache_lock) do
        validator.user_cache[token_str] = (user, now(UTC))
    end

    return AuthResult(user)
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
)
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
struct GitHubOAuthValidatorWithOrg <: TokenValidator
    base_validator::GitHubOAuthValidator
    required_org::Union{String,Nothing}
end

function GitHubOAuthValidatorWithOrg(; base_validator::GitHubOAuthValidator, required_org=nothing)
    GitHubOAuthValidatorWithOrg(base_validator, required_org)
end

function Base.show(io::IO, v::GitHubOAuthValidatorWithOrg)
    org_info = isnothing(v.required_org) ? "" : ", org=$(v.required_org)"
    print(io, "GitHubOAuthValidatorWithOrg(", v.base_validator, org_info, ")")
end

function validate_token(validator::GitHubOAuthValidatorWithOrg, token::AbstractString, config::OAuthConfig)
    # First validate the token with base validator
    result = validate_token(validator.base_validator, token, config)

    if !result.success
        return result
    end

    # Check org membership if required
    if !isnothing(validator.required_org)
        if !check_github_org_membership(String(token), validator.required_org)
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
    lock(validator.cache_lock) do
        empty!(validator.user_cache)
    end
end

function clear_cache!(validator::GitHubOAuthValidatorWithOrg)
    clear_cache!(validator.base_validator)
end

# src/auth/oauth_server/upstream.jl
# Upstream OAuth provider abstraction and implementations

using HTTP
using URIs

# ============================================================================
# Abstract Interface
# ============================================================================

"""
    build_authorize_url(provider::UpstreamOAuthProvider, state::String,
                        redirect_uri::String) -> String

Build the authorization URL for redirecting to the upstream provider.

# Arguments
- `provider::UpstreamOAuthProvider`: The upstream provider
- `state::String`: State parameter for CSRF protection
- `redirect_uri::String`: Your callback URL

# Returns
The full authorization URL to redirect the user to.
"""
function build_authorize_url end

"""
    exchange_code(provider::UpstreamOAuthProvider, code::String,
                  redirect_uri::String) -> Union{UpstreamTokenResponse,Nothing}

Exchange an authorization code for tokens from the upstream provider.

# Arguments
- `provider::UpstreamOAuthProvider`: The upstream provider
- `code::String`: The authorization code from the callback
- `redirect_uri::String`: The redirect URI used in authorization

# Returns
`UpstreamTokenResponse` on success, `nothing` on failure.
"""
function exchange_code end

"""
    fetch_user_info(provider::UpstreamOAuthProvider, access_token::String) -> Union{AuthenticatedUser,Nothing}

Fetch user information from the upstream provider using an access token.

# Arguments
- `provider::UpstreamOAuthProvider`: The upstream provider
- `access_token::String`: Access token from the upstream provider

# Returns
`AuthenticatedUser` on success, `nothing` on failure.
"""
function fetch_user_info end

"""
    UpstreamTokenResponse

Response from upstream provider's token endpoint.
"""
Base.@kwdef struct UpstreamTokenResponse
    access_token::String
    token_type::String = "Bearer"
    expires_in::Union{Int,Nothing} = nothing
    refresh_token::Union{String,Nothing} = nothing
    scope::Union{String,Nothing} = nothing
end

# ============================================================================
# GitHub Upstream Provider
# ============================================================================

"""
    GitHubUpstreamProvider(; client_id, client_secret, scopes, ...)

Upstream OAuth provider for GitHub.

# Fields
- `client_id::String`: GitHub OAuth App client ID
- `client_secret::String`: GitHub OAuth App client secret
- `scopes::Vector{String}`: OAuth scopes to request (default: ["read:user"])
- `authorize_url::String`: GitHub authorization endpoint
- `token_url::String`: GitHub token endpoint
- `user_api_url::String`: GitHub user API endpoint

# Example
```julia
github = GitHubUpstreamProvider(
    client_id = ENV["GITHUB_CLIENT_ID"],
    client_secret = ENV["GITHUB_CLIENT_SECRET"],
    scopes = ["read:user", "read:org"]
)
```
"""
Base.@kwdef struct GitHubUpstreamProvider <: UpstreamOAuthProvider
    client_id::String
    client_secret::String
    scopes::Vector{String} = ["read:user"]
    authorize_url::String = "https://github.com/login/oauth/authorize"
    token_url::String = "https://github.com/login/oauth/access_token"
    user_api_url::String = "https://api.github.com/user"
end

function Base.show(io::IO, provider::GitHubUpstreamProvider)
    print(io, "GitHubUpstreamProvider(client_id=", provider.client_id[1:min(8,length(provider.client_id))], "...)")
end

function build_authorize_url(provider::GitHubUpstreamProvider, state::String, redirect_uri::String)
    params = Dict{String,String}(
        "client_id" => provider.client_id,
        "redirect_uri" => redirect_uri,
        "scope" => join(provider.scopes, " "),
        "state" => state,
        "allow_signup" => "false"  # Don't allow new GitHub signups
    )

    query = join(["$k=$(URIs.escapeuri(v))" for (k, v) in params], "&")
    return "$(provider.authorize_url)?$query"
end

function exchange_code(provider::GitHubUpstreamProvider, code::String, redirect_uri::String)
    try
        response = HTTP.post(
            provider.token_url,
            [
                "Accept" => "application/json",
                "Content-Type" => "application/x-www-form-urlencoded"
            ],
            join([
                "client_id=$(URIs.escapeuri(provider.client_id))",
                "client_secret=$(URIs.escapeuri(provider.client_secret))",
                "code=$(URIs.escapeuri(code))",
                "redirect_uri=$(URIs.escapeuri(redirect_uri))"
            ], "&")
        )

        if response.status != 200
            @warn "GitHub token exchange failed" status=response.status
            return nothing
        end

        data = JSON3.read(String(response.body), Dict{String,Any})

        # Check for error response
        if haskey(data, "error")
            @warn "GitHub token exchange error" error=data["error"] description=get(data, "error_description", nothing)
            return nothing
        end

        return UpstreamTokenResponse(
            access_token = data["access_token"],
            token_type = get(data, "token_type", "Bearer"),
            scope = get(data, "scope", nothing)
        )
    catch e
        if e isa HTTP.StatusError
            @warn "GitHub token exchange HTTP error" status=e.status
        elseif e isa HTTP.RequestError
            @warn "GitHub token exchange request failed" exception=(e, catch_backtrace())
        else
            rethrow(e)
        end
        return nothing
    end
end

function fetch_user_info(provider::GitHubUpstreamProvider, access_token::String)
    try
        response = HTTP.get(
            provider.user_api_url,
            [
                "Authorization" => "Bearer $access_token",
                "Accept" => "application/vnd.github+json",
                "X-GitHub-Api-Version" => "2022-11-28"
            ]
        )

        if response.status != 200
            @warn "GitHub user info fetch failed" status=response.status
            return nothing
        end

        data = JSON3.read(String(response.body), Dict{String,Any})

        username = get(data, "login", nothing)
        if isnothing(username)
            @warn "GitHub user has no login"
            return nothing
        end

        return AuthenticatedUser(
            subject = string(get(data, "id", username)),
            provider = "github",
            username = username,
            scopes = String[],  # GitHub doesn't return scopes in user response
            claims = Dict{String,Any}(
                "login" => username,
                "id" => get(data, "id", nothing),
                "name" => get(data, "name", nothing),
                "email" => get(data, "email", nothing),
                "avatar_url" => get(data, "avatar_url", nothing),
                "html_url" => get(data, "html_url", nothing)
            )
        )
    catch e
        if e isa HTTP.StatusError
            @warn "GitHub user info HTTP error" status=e.status
        elseif e isa HTTP.RequestError
            @warn "GitHub user info request failed" exception=(e, catch_backtrace())
        else
            rethrow(e)
        end
        return nothing
    end
end

"""
    check_github_org_membership(access_token::String, org::String) -> Bool

Check if the authenticated user is a member of a GitHub organization.

# Arguments
- `access_token::String`: GitHub access token
- `org::String`: Organization name to check

# Returns
`true` if the user is a member of the organization.
"""
function check_upstream_github_org_membership(access_token::String, org::String)
    try
        response = HTTP.get(
            "https://api.github.com/user/memberships/orgs/$org",
            [
                "Authorization" => "Bearer $access_token",
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

# ============================================================================
# Test Upstream Provider (for development/testing)
# ============================================================================

"""
    TestUpstreamProvider(; username, user_id, auto_approve)

A test upstream provider for development and testing that doesn't require external OAuth.

When `auto_approve=true`, the authorize endpoint immediately redirects back with an auth code
without showing a login page. When `auto_approve=false`, it shows a simple HTML form.

# Fields
- `username::String`: Username to return for authenticated user (default: "testuser")
- `user_id::String`: User ID to return (default: "test-123")
- `auto_approve::Bool`: Skip login page and auto-authenticate (default: true)
- `access_tokens::Dict{String,String}`: Maps generated access tokens to usernames

# Example
```julia
# Auto-approve for automated testing
test_provider = TestUpstreamProvider(auto_approve=true)

# Or show login form for manual testing
test_provider = TestUpstreamProvider(auto_approve=false)
```
"""
Base.@kwdef mutable struct TestUpstreamProvider <: UpstreamOAuthProvider
    username::String = "testuser"
    user_id::String = "test-123"
    auto_approve::Bool = true
    base_url::String = "http://127.0.0.1:3000"  # Server base URL for absolute redirects
    # Internal state: maps access_token -> username
    access_tokens::Dict{String,String} = Dict{String,String}()
    # Internal state: maps auth_code -> (username, redirect_uri)
    pending_codes::Dict{String,Tuple{String,String}} = Dict{String,Tuple{String,String}}()
    # Lock for thread-safe access to mutable state
    lock::ReentrantLock = ReentrantLock()
end

function Base.show(io::IO, provider::TestUpstreamProvider)
    print(io, "TestUpstreamProvider(username=$(provider.username), auto_approve=$(provider.auto_approve))")
end

function build_authorize_url(provider::TestUpstreamProvider, state::String, redirect_uri::String)
    # For test provider, we redirect to a special endpoint on our own server
    # that will either auto-approve or show a login form
    params = Dict{String,String}(
        "state" => state,
        "redirect_uri" => redirect_uri,
        "provider" => "test"
    )
    query = join(["$k=$(URIs.escapeuri(v))" for (k, v) in params], "&")
    # Return absolute URL to test login endpoint
    return "$(provider.base_url)/_test/login?$query"
end

function exchange_code(provider::TestUpstreamProvider, code::String, redirect_uri::String)
    lock(provider.lock) do
        # Check if we have this code pending
        if !haskey(provider.pending_codes, code)
            @warn "Test provider: unknown authorization code" code
            return nothing
        end

        username, expected_redirect = provider.pending_codes[code]

        # Remove the code (single use)
        delete!(provider.pending_codes, code)

        # Generate access token
        access_token = "test_token_" * bytes2hex(rand(UInt8, 16))
        provider.access_tokens[access_token] = username

        return UpstreamTokenResponse(
            access_token = access_token,
            token_type = "Bearer",
            expires_in = 3600
        )
    end
end

function fetch_user_info(provider::TestUpstreamProvider, access_token::String)
    username = lock(provider.lock) do
        get(provider.access_tokens, access_token, nothing)
    end
    if isnothing(username)
        @warn "Test provider: unknown access token"
        return nothing
    end

    return AuthenticatedUser(
        subject = provider.user_id,
        provider = "test",
        username = username,
        scopes = String[],
        claims = Dict{String,Any}(
            "login" => username,
            "id" => provider.user_id,
            "name" => "Test User",
            "email" => "$(username)@test.local"
        )
    )
end

"""
    generate_test_auth_code!(provider::TestUpstreamProvider, username::String, redirect_uri::String) -> String

Generate an authorization code for testing. Called by the test login endpoint.
"""
function generate_test_auth_code!(provider::TestUpstreamProvider, username::String, redirect_uri::String)
    lock(provider.lock) do
        code = "test_code_" * bytes2hex(rand(UInt8, 16))
        provider.pending_codes[code] = (username, redirect_uri)
        return code
    end
end

"""
    render_test_login_page(state::String, redirect_uri::String, server_base::String) -> String

Generate HTML for test login page.
"""
function render_test_login_page(state::String, redirect_uri::String, server_base::String)
    """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Test OAuth Login</title>
        <style>
            body { font-family: -apple-system, system-ui, sans-serif; max-width: 400px; margin: 100px auto; padding: 20px; }
            h1 { color: #333; }
            form { background: #f5f5f5; padding: 20px; border-radius: 8px; }
            input { width: 100%; padding: 10px; margin: 10px 0; box-sizing: border-box; }
            button { width: 100%; padding: 12px; background: #0066cc; color: white; border: none; border-radius: 4px; cursor: pointer; }
            button:hover { background: #0052a3; }
            .info { color: #666; font-size: 14px; margin-top: 20px; }
        </style>
    </head>
    <body>
        <h1>Test OAuth Login</h1>
        <form method="POST" action="$server_base/_test/login">
            <input type="hidden" name="state" value="$state">
            <input type="hidden" name="redirect_uri" value="$redirect_uri">
            <label>Username:</label>
            <input type="text" name="username" value="testuser" required>
            <button type="submit">Login</button>
        </form>
        <p class="info">This is a test OAuth provider for development. Enter any username to authenticate.</p>
    </body>
    </html>
    """
end

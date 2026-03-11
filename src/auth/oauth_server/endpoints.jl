# src/auth/oauth_server/endpoints.jl
# OAuth 2.1 Authorization Server endpoints
# Implements /authorize, /callback, and /token

using Random: randstring
using Dates: DateTime, now, UTC, Second

# ============================================================================
# Authorization Endpoint (/authorize)
# ============================================================================

"""
    parse_authorization_request(query_params::Dict{String,String}) -> Union{AuthorizationRequest,OAuthError}

Parse and validate an authorization request from query parameters.

# Arguments
- `query_params::Dict{String,String}`: Query parameters from the request

# Returns
`AuthorizationRequest` on success, `OAuthError` on validation failure.
"""
function parse_authorization_request(query_params::Dict{String,String}; issuer::String="")
    # Required parameters (resource is optional per RFC 8707)
    required = ["client_id", "redirect_uri", "response_type", "state",
                "code_challenge", "code_challenge_method"]

    for param in required
        if !haskey(query_params, param) || isempty(query_params[param])
            return OAuthError(
                error = OAuthErrorCodes.INVALID_REQUEST,
                error_description = "Missing required parameter: $param"
            )
        end
    end

    # Validate response_type
    if query_params["response_type"] != "code"
        return OAuthError(
            error = OAuthErrorCodes.UNSUPPORTED_RESPONSE_TYPE,
            error_description = "Only 'code' response_type is supported"
        )
    end

    # Validate code_challenge_method
    method = query_params["code_challenge_method"]
    if !validate_code_challenge_method(method)
        return OAuthError(
            error = OAuthErrorCodes.INVALID_REQUEST,
            error_description = "Unsupported code_challenge_method: $method"
        )
    end

    # MCP spec requires S256
    if method != "S256"
        return OAuthError(
            error = OAuthErrorCodes.INVALID_REQUEST,
            error_description = "MCP requires S256 code_challenge_method"
        )
    end

    # Validate redirect_uri format (must be localhost or HTTPS)
    redirect_uri = query_params["redirect_uri"]
    if !is_valid_redirect_uri(redirect_uri)
        return OAuthError(
            error = OAuthErrorCodes.INVALID_REQUEST,
            error_description = "Invalid redirect_uri: must be localhost or HTTPS"
        )
    end

    # Resource is optional - default to issuer if not provided
    resource = get(query_params, "resource", issuer)
    if isempty(resource)
        resource = issuer
    end

    return AuthorizationRequest(
        client_id = query_params["client_id"],
        redirect_uri = redirect_uri,
        response_type = query_params["response_type"],
        state = query_params["state"],
        code_challenge = query_params["code_challenge"],
        code_challenge_method = method,
        resource = resource,
        scope = get(query_params, "scope", nothing)
    )
end

"""
    is_valid_redirect_uri(uri::AbstractString) -> Bool

Validate that a redirect URI is safe per OAuth security requirements.
Must be localhost (for development) or HTTPS.
"""
function is_valid_redirect_uri(uri::AbstractString)
    parsed = URIs.URI(uri)
    scheme = lowercase(parsed.scheme)
    host = lowercase(parsed.host)

    # Allow localhost variants
    if host in ("localhost", "127.0.0.1", "[::1]")
        return scheme in ("http", "https")
    end

    # Everything else must be HTTPS
    return scheme == "https"
end

"""
    handle_authorize(request::AuthorizationRequest, upstream::UpstreamOAuthProvider,
                     storage::TokenStorage, callback_uri::String) -> Tuple{Int,String,Dict{String,String}}

Handle the authorization endpoint request.

# Arguments
- `request::AuthorizationRequest`: Parsed authorization request
- `upstream::UpstreamOAuthProvider`: Upstream provider for authentication
- `storage::TokenStorage`: Storage for pending authorizations
- `callback_uri::String`: Your server's callback URI

# Returns
Tuple of (status_code, body, headers) - typically a 302 redirect.
"""
function handle_authorize(
    request::AuthorizationRequest,
    upstream::UpstreamOAuthProvider,
    storage::TokenStorage,
    callback_uri::String
)
    # Parse scopes
    scopes = if !isnothing(request.scope)
        String.(split(request.scope))
    else
        String[]
    end

    # Create pending authorization
    pending = PendingAuthorization(
        state = request.state,
        client_id = request.client_id,
        redirect_uri = request.redirect_uri,
        code_challenge = request.code_challenge,
        code_challenge_method = request.code_challenge_method,
        resource = request.resource,
        scope = scopes
    )

    # Store pending authorization (keyed by upstream_state)
    store_pending!(storage, pending)

    # Build redirect URL to upstream provider
    upstream_url = build_authorize_url(upstream, pending.upstream_state, callback_uri)

    headers = Dict{String,String}(
        "Location" => upstream_url,
        "Cache-Control" => "no-store"
    )

    return (302, "", headers)
end

# ============================================================================
# Callback Endpoint (/callback)
# ============================================================================

"""
    handle_callback(code::String, state::String, upstream::UpstreamOAuthProvider,
                    storage::TokenStorage, callback_uri::String,
                    config::OAuthServerConfig;
                    user_validator=nothing) -> Tuple{Int,String,Dict{String,String}}

Handle the callback from the upstream OAuth provider.

# Arguments
- `code::String`: Authorization code from upstream provider
- `state::String`: State parameter (our upstream_state)
- `upstream::UpstreamOAuthProvider`: Upstream provider
- `storage::TokenStorage`: Token storage
- `callback_uri::String`: Your callback URI (for code exchange)
- `config::OAuthServerConfig`: OAuth server configuration
- `user_validator`: Optional function `(user::AuthenticatedUser) -> Bool` to validate users

# Returns
Tuple of (status_code, body, headers) - redirect to client or error page.
"""
function handle_callback(
    code::String,
    state::String,
    upstream::UpstreamOAuthProvider,
    storage::TokenStorage,
    callback_uri::String,
    config::OAuthServerConfig;
    user_validator::Union{Function,Nothing} = nothing
)
    # Retrieve pending authorization
    pending = get_pending(storage, state)
    if isnothing(pending)
        return error_redirect(
            "about:blank",  # Can't redirect to client - we lost their info
            OAuthErrorCodes.INVALID_REQUEST,
            "Authorization session expired or invalid",
            ""
        )
    end

    # Delete pending (single-use)
    delete_pending!(storage, state)

    # Exchange code with upstream provider
    token_response = exchange_code(upstream, code, callback_uri)
    if isnothing(token_response)
        return error_redirect(
            pending.redirect_uri,
            OAuthErrorCodes.ACCESS_DENIED,
            "Failed to authenticate with upstream provider",
            pending.state
        )
    end

    # Fetch user info from upstream
    user = fetch_user_info(upstream, token_response.access_token)
    if isnothing(user)
        return error_redirect(
            pending.redirect_uri,
            OAuthErrorCodes.ACCESS_DENIED,
            "Failed to retrieve user information",
            pending.state
        )
    end

    # Apply custom user validation (allowlist, org membership, etc.)
    if !isnothing(user_validator)
        if !user_validator(user)
            return error_redirect(
                pending.redirect_uri,
                OAuthErrorCodes.ACCESS_DENIED,
                "User not authorized to access this resource",
                pending.state
            )
        end
    end

    # Issue our own authorization code
    auth_code = AuthorizationCode(
        code = generate_secure_token(32),
        client_id = pending.client_id,
        redirect_uri = pending.redirect_uri,
        code_challenge = pending.code_challenge,
        code_challenge_method = pending.code_challenge_method,
        resource = pending.resource,
        user = user,
        scope = pending.scope,
        expires_at = now(UTC) + Second(config.authorization_code_ttl)
    )

    # Store authorization code
    store_auth_code!(storage, auth_code)

    # Redirect back to client with our authorization code
    redirect_url = build_success_redirect(pending.redirect_uri, auth_code.code, pending.state)

    headers = Dict{String,String}(
        "Location" => redirect_url,
        "Cache-Control" => "no-store"
    )

    return (302, "", headers)
end

"""
    error_redirect(redirect_uri::String, error_code::String,
                   description::String, state::String) -> Tuple{Int,String,Dict{String,String}}

Build an error redirect response.
"""
function error_redirect(redirect_uri::String, error_code::String, description::String, state::String)
    params = [
        "error=$(URIs.escapeuri(error_code))",
        "error_description=$(URIs.escapeuri(description))"
    ]

    if !isempty(state)
        push!(params, "state=$(URIs.escapeuri(state))")
    end

    separator = occursin("?", redirect_uri) ? "&" : "?"
    redirect_url = "$(redirect_uri)$(separator)$(join(params, "&"))"

    headers = Dict{String,String}(
        "Location" => redirect_url,
        "Cache-Control" => "no-store"
    )

    return (302, "", headers)
end

"""
    build_success_redirect(redirect_uri::String, code::String, state::String) -> String

Build a success redirect URL with authorization code.
"""
function build_success_redirect(redirect_uri::String, code::String, state::String)
    params = [
        "code=$(URIs.escapeuri(code))",
        "state=$(URIs.escapeuri(state))"
    ]

    separator = occursin("?", redirect_uri) ? "&" : "?"
    return "$(redirect_uri)$(separator)$(join(params, "&"))"
end

# ============================================================================
# Token Endpoint (/token)
# ============================================================================

"""
    parse_token_request(body::AbstractString) -> Union{TokenRequest,OAuthError}

Parse a token request from form-encoded body.

# Arguments
- `body::AbstractString`: The request body (application/x-www-form-urlencoded)

# Returns
`TokenRequest` on success, `OAuthError` on validation failure.
"""
function parse_token_request(body::AbstractString)
    params = Dict{String,String}()

    for part in split(body, "&")
        if occursin("=", part)
            key, value = split(part, "=", limit=2)
            params[URIs.unescapeuri(key)] = URIs.unescapeuri(value)
        end
    end

    # Required: grant_type
    if !haskey(params, "grant_type")
        return OAuthError(
            error = OAuthErrorCodes.INVALID_REQUEST,
            error_description = "Missing required parameter: grant_type"
        )
    end

    grant_type = params["grant_type"]

    if grant_type == "authorization_code"
        # Required for authorization_code grant
        for param in ["code", "redirect_uri", "code_verifier"]
            if !haskey(params, param) || isempty(params[param])
                return OAuthError(
                    error = OAuthErrorCodes.INVALID_REQUEST,
                    error_description = "Missing required parameter for authorization_code grant: $param"
                )
            end
        end
    elseif grant_type == "refresh_token"
        if !haskey(params, "refresh_token") || isempty(params["refresh_token"])
            return OAuthError(
                error = OAuthErrorCodes.INVALID_REQUEST,
                error_description = "Missing required parameter: refresh_token"
            )
        end
    else
        return OAuthError(
            error = OAuthErrorCodes.UNSUPPORTED_GRANT_TYPE,
            error_description = "Unsupported grant_type: $grant_type"
        )
    end

    return TokenRequest(
        grant_type = grant_type,
        code = get(params, "code", nothing),
        redirect_uri = get(params, "redirect_uri", nothing),
        code_verifier = get(params, "code_verifier", nothing),
        refresh_token = get(params, "refresh_token", nothing),
        client_id = get(params, "client_id", nothing),
        resource = get(params, "resource", nothing),
        scope = get(params, "scope", nothing)
    )
end

"""
    handle_token(request::TokenRequest, storage::TokenStorage,
                 config::OAuthServerConfig) -> Tuple{Int,String,Dict{String,String}}

Handle the token endpoint request.

# Arguments
- `request::TokenRequest`: Parsed token request
- `storage::TokenStorage`: Token storage
- `config::OAuthServerConfig`: OAuth server configuration

# Returns
Tuple of (status_code, body, headers).
"""
function handle_token(request::TokenRequest, storage::TokenStorage, config::OAuthServerConfig)
    headers = Dict{String,String}(
        "Content-Type" => "application/json",
        "Cache-Control" => "no-store",
        "Pragma" => "no-cache"
    )

    if request.grant_type == "authorization_code"
        return handle_authorization_code_grant(request, storage, config, headers)
    elseif request.grant_type == "refresh_token"
        return handle_refresh_token_grant(request, storage, config, headers)
    else
        error_response = OAuthError(
            error = OAuthErrorCodes.UNSUPPORTED_GRANT_TYPE,
            error_description = "Unsupported grant_type"
        )
        return (400, oauth_error_json(error_response), headers)
    end
end

"""
    handle_authorization_code_grant(request::TokenRequest, storage::TokenStorage,
                                    config::OAuthServerConfig, headers::Dict) -> Tuple{Int,String,Dict}

Handle authorization_code grant type.
"""
function handle_authorization_code_grant(
    request::TokenRequest,
    storage::TokenStorage,
    config::OAuthServerConfig,
    headers::Dict{String,String}
)
    # Retrieve authorization code
    auth_code = get_auth_code(storage, request.code)
    if isnothing(auth_code)
        error_response = OAuthError(
            error = OAuthErrorCodes.INVALID_GRANT,
            error_description = "Invalid or expired authorization code"
        )
        return (400, oauth_error_json(error_response), headers)
    end

    # Delete authorization code (single-use per OAuth spec)
    delete_auth_code!(storage, request.code)

    # Validate redirect_uri matches
    if auth_code.redirect_uri != request.redirect_uri
        error_response = OAuthError(
            error = OAuthErrorCodes.INVALID_GRANT,
            error_description = "redirect_uri does not match authorization request"
        )
        return (400, oauth_error_json(error_response), headers)
    end

    # Validate PKCE
    if !validate_pkce(auth_code.code_challenge, request.code_verifier, auth_code.code_challenge_method)
        error_response = OAuthError(
            error = OAuthErrorCodes.INVALID_GRANT,
            error_description = "Invalid code_verifier"
        )
        return (400, oauth_error_json(error_response), headers)
    end

    # Issue access token
    token = issue_token(auth_code, config)
    store_token!(storage, token)

    # Build response
    response = TokenResponse(
        access_token = token.access_token,
        token_type = token.token_type,
        expires_in = config.access_token_ttl,
        refresh_token = token.refresh_token,
        scope = isempty(token.scope) ? nothing : join(token.scope, " ")
    )

    return (200, token_response_json(response), headers)
end

"""
    handle_refresh_token_grant(request::TokenRequest, storage::TokenStorage,
                               config::OAuthServerConfig, headers::Dict) -> Tuple{Int,String,Dict}

Handle refresh_token grant type.
"""
function handle_refresh_token_grant(
    request::TokenRequest,
    storage::TokenStorage,
    config::OAuthServerConfig,
    headers::Dict{String,String}
)
    # Find token by refresh token
    old_token = get_token_by_refresh(storage, request.refresh_token)
    if isnothing(old_token)
        error_response = OAuthError(
            error = OAuthErrorCodes.INVALID_GRANT,
            error_description = "Invalid refresh token"
        )
        return (400, oauth_error_json(error_response), headers)
    end

    # Delete old token
    delete_token!(storage, old_token.access_token)

    # Issue new token (with new refresh token for rotation)
    new_token = IssuedToken(
        access_token = generate_secure_token(32),
        user = old_token.user,
        client_id = old_token.client_id,
        scope = old_token.scope,
        resource = old_token.resource,
        expires_at = now(UTC) + Second(config.access_token_ttl),
        refresh_token = generate_secure_token(32)  # Rotate refresh token
    )

    store_token!(storage, new_token)

    # Build response
    response = TokenResponse(
        access_token = new_token.access_token,
        token_type = new_token.token_type,
        expires_in = config.access_token_ttl,
        refresh_token = new_token.refresh_token,
        scope = isempty(new_token.scope) ? nothing : join(new_token.scope, " ")
    )

    return (200, token_response_json(response), headers)
end

# ============================================================================
# Helper Functions
# ============================================================================

"""
    generate_secure_token(token_length::Int=32) -> String

Generate a cryptographically secure random token.
"""
function generate_secure_token(token_length::Int=32)
    # Use URL-safe base64 characters
    charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    return String([charset[rand(1:length(charset))] for _ in 1:token_length])
end

"""
    issue_token(auth_code::AuthorizationCode, config::OAuthServerConfig) -> IssuedToken

Issue an access token from an authorization code.
"""
function issue_token(auth_code::AuthorizationCode, config::OAuthServerConfig)
    return IssuedToken(
        access_token = generate_secure_token(32),
        user = auth_code.user,
        client_id = auth_code.client_id,
        scope = auth_code.scope,
        resource = auth_code.resource,
        expires_at = now(UTC) + Second(config.access_token_ttl),
        refresh_token = generate_secure_token(32)
    )
end

"""
    oauth_error_json(error::OAuthError) -> String

Serialize an OAuth error to JSON.
"""
function oauth_error_json(error::OAuthError)
    data = Dict{String,Any}("error" => error.error)

    if !isnothing(error.error_description)
        data["error_description"] = error.error_description
    end

    if !isnothing(error.error_uri)
        data["error_uri"] = error.error_uri
    end

    return JSON3.write(data)
end

"""
    token_response_json(response::TokenResponse) -> String

Serialize a token response to JSON.
"""
function token_response_json(response::TokenResponse)
    data = Dict{String,Any}(
        "access_token" => response.access_token,
        "token_type" => response.token_type,
        "expires_in" => response.expires_in
    )

    if !isnothing(response.refresh_token)
        data["refresh_token"] = response.refresh_token
    end

    if !isnothing(response.scope)
        data["scope"] = response.scope
    end

    return JSON3.write(data)
end

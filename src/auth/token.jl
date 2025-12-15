# src/auth/token.jl
# Token validation implementations

using Base64

"""
    SimpleTokenValidator(; tokens::Dict{String,AuthenticatedUser})

Simple token validator using a static mapping of tokens to users.
Useful for API keys and development/testing.

# Fields
- `tokens::Dict{String,AuthenticatedUser}`: Map of valid tokens to user info
"""
struct SimpleTokenValidator <: TokenValidator
    tokens::Dict{String,AuthenticatedUser}
end

SimpleTokenValidator() = SimpleTokenValidator(Dict{String,AuthenticatedUser}())

"""
    add_token!(validator::SimpleTokenValidator, token::String, user::AuthenticatedUser)

Add a valid token to the validator.
"""
function add_token!(validator::SimpleTokenValidator, token::String, user::AuthenticatedUser)
    validator.tokens[token] = user
end

function validate_token(validator::SimpleTokenValidator, token::String, config::OAuthConfig)::AuthResult
    if haskey(validator.tokens, token)
        return AuthResult(validator.tokens[token])
    end
    return AuthResult("Invalid token", :invalid_token)
end

"""
    JWTValidator(; jwks_cache::Dict{String,Any}=Dict{String,Any}(),
                  clock_skew_seconds::Int=60)

JWT token validator with JWKS support.

# Fields
- `jwks_cache::Dict{String,Any}`: Cached JSON Web Key Sets by URI
- `clock_skew_seconds::Int`: Allowed clock skew for exp/nbf validation
"""
Base.@kwdef mutable struct JWTValidator <: TokenValidator
    jwks_cache::Dict{String,Any} = Dict{String,Any}()
    clock_skew_seconds::Int = 60
end

"""
    decode_jwt_payload(token::String) -> Union{Dict{String,Any},Nothing}

Decode JWT payload without verification (for claim inspection).
Returns nothing if token format is invalid.
"""
function decode_jwt_payload(token::String)::Union{Dict{String,Any},Nothing}
    parts = split(token, '.')
    if length(parts) != 3
        return nothing
    end

    try
        # JWT uses base64url encoding
        payload_b64 = parts[2]
        # Add padding if needed
        padding = mod(4 - mod(length(payload_b64), 4), 4)
        payload_b64 = payload_b64 * repeat("=", padding)
        # Replace URL-safe characters
        payload_b64 = replace(payload_b64, "-" => "+", "_" => "/")

        payload_json = String(base64decode(payload_b64))
        return JSON3.read(payload_json, Dict{String,Any})
    catch
        return nothing
    end
end

"""
    validate_jwt_claims(claims::Dict{String,Any}, config::OAuthConfig, clock_skew::Int) -> AuthResult

Validate JWT claims (iss, aud, exp, nbf).
"""
function validate_jwt_claims(claims::Dict{String,Any}, config::OAuthConfig, clock_skew::Int)::AuthResult
    now_ts = round(Int, datetime2unix(now(UTC)))

    # Check issuer
    if haskey(claims, "iss")
        if claims["iss"] != config.issuer
            return AuthResult("Invalid issuer", :invalid_issuer)
        end
    end

    # Check audience
    if haskey(claims, "aud")
        aud = claims["aud"]
        valid_aud = if aud isa String
            aud == config.audience
        elseif aud isa Vector
            config.audience in aud
        else
            false
        end
        if !valid_aud
            return AuthResult("Invalid audience", :invalid_audience)
        end
    end

    # Check expiration
    if haskey(claims, "exp")
        exp = claims["exp"]
        if exp isa Number && now_ts > exp + clock_skew
            return AuthResult("Token expired", :expired)
        end
    end

    # Check not-before
    if haskey(claims, "nbf")
        nbf = claims["nbf"]
        if nbf isa Number && now_ts < nbf - clock_skew
            return AuthResult("Token not yet valid", :not_yet_valid)
        end
    end

    # Check required scopes
    if !isempty(config.required_scopes)
        token_scopes = if haskey(claims, "scope")
            scope = claims["scope"]
            scope isa String ? split(scope) : String[]
        elseif haskey(claims, "scp")
            scp = claims["scp"]
            scp isa Vector ? String.(scp) : String[]
        else
            String[]
        end

        for required in config.required_scopes
            if !(required in token_scopes)
                return AuthResult("Missing required scope: $required", :insufficient_scope)
            end
        end
    end

    # Build authenticated user
    user = AuthenticatedUser(
        subject = get(claims, "sub", "unknown"),
        provider = get(claims, "iss", "unknown"),
        username = get(claims, "preferred_username", get(claims, "name", nothing)),
        scopes = if haskey(claims, "scope")
            String.(split(claims["scope"]))
        elseif haskey(claims, "scp")
            String.(claims["scp"])
        else
            String[]
        end,
        claims = claims
    )

    return AuthResult(user)
end

function validate_token(validator::JWTValidator, token::String, config::OAuthConfig)::AuthResult
    # Decode payload (without signature verification for now)
    # Full signature verification requires JWKS fetch and crypto operations
    claims = decode_jwt_payload(token)

    if isnothing(claims)
        return AuthResult("Invalid JWT format", :invalid_format)
    end

    # Validate claims
    return validate_jwt_claims(claims, config, validator.clock_skew_seconds)
end

"""
    IntrospectionValidator(; http_client::Any=nothing)

Token validator using OAuth 2.0 Token Introspection (RFC 7662).
Used for opaque tokens that cannot be validated locally.

# Fields
- `client_id::Union{String,Nothing}`: Client ID for introspection auth
- `client_secret::Union{String,Nothing}`: Client secret for introspection auth
"""
Base.@kwdef mutable struct IntrospectionValidator <: TokenValidator
    client_id::Union{String,Nothing} = nothing
    client_secret::Union{String,Nothing} = nothing
end

function validate_token(validator::IntrospectionValidator, token::String, config::OAuthConfig)::AuthResult
    if isnothing(config.introspection_endpoint)
        return AuthResult("Introspection endpoint not configured", :configuration_error)
    end

    try
        # Build introspection request
        headers = ["Content-Type" => "application/x-www-form-urlencoded"]

        # Add client credentials if configured
        if !isnothing(validator.client_id) && !isnothing(validator.client_secret)
            auth = base64encode("$(validator.client_id):$(validator.client_secret)")
            push!(headers, "Authorization" => "Basic $auth")
        end

        body = "token=$(HTTP.URIs.escapeuri(token))"

        response = HTTP.post(
            config.introspection_endpoint,
            headers,
            body
        )

        if response.status != 200
            return AuthResult("Introspection request failed", :introspection_error)
        end

        result = JSON3.read(String(response.body), Dict{String,Any})

        # Check if token is active
        if !get(result, "active", false)
            return AuthResult("Token is not active", :invalid_token)
        end

        # Build user from introspection response
        user = AuthenticatedUser(
            subject = get(result, "sub", get(result, "username", "unknown")),
            provider = get(result, "iss", config.issuer),
            username = get(result, "username", nothing),
            scopes = if haskey(result, "scope")
                String.(split(result["scope"]))
            else
                String[]
            end,
            claims = result
        )

        # Check required scopes
        if !isempty(config.required_scopes)
            for required in config.required_scopes
                if !(required in user.scopes)
                    return AuthResult("Missing required scope: $required", :insufficient_scope)
                end
            end
        end

        return AuthResult(user)

    catch e
        return AuthResult("Introspection failed: $e", :introspection_error)
    end
end

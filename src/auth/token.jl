# src/auth/token.jl
# Token validation implementations

using Base64
using Dates: datetime2unix

"""
    SimpleTokenValidator(; tokens::Dict{String,AuthenticatedUser})

Simple token validator using a static mapping of tokens to users.
Useful for API keys and development/testing.

!!! note "Development use"
    Lookups are plain dictionary comparisons (not constant-time) and tokens are held
    in memory in plaintext. Intended for development and trusted static API keys, not
    as a general-purpose production token store.

# Fields
- `tokens::Dict{String,AuthenticatedUser}`: Map of valid tokens to user info
"""
struct SimpleTokenValidator <: TokenValidator
    tokens::Dict{String,AuthenticatedUser}
end

SimpleTokenValidator() = SimpleTokenValidator(Dict{String,AuthenticatedUser}())

function Base.show(io::IO, v::SimpleTokenValidator)
    print(io, "SimpleTokenValidator(", length(v.tokens), " tokens)")
end

"""
    add_token!(validator::SimpleTokenValidator, token::String, user::AuthenticatedUser)

Add a valid token to the validator.
"""
function add_token!(validator::SimpleTokenValidator, token::String, user::AuthenticatedUser)
    validator.tokens[token] = user
end

function validate_token(validator::SimpleTokenValidator, token::AbstractString, config::OAuthConfig)
    if haskey(validator.tokens, token)
        return AuthResult(validator.tokens[token])
    end
    return AuthResult("Invalid token", :invalid_token)
end

"""
    JWTValidator(; clock_skew_seconds::Int=60)

JWT token validator that validates claims (iss, aud, exp, nbf, scope).

!!! warning "No Signature Verification"
    This validator decodes and validates JWT claims but does **not** verify
    cryptographic signatures (JWKS/JWK). Tokens from untrusted issuers can
    be forged. Use `IntrospectionValidator` (RFC 7662) when accepting tokens
    from external issuers. Signature verification via JWKS may be added in a
    future release.

# Fields
- `jwks_cache::Dict{String,Any}`: Reserved for future JWKS support
- `clock_skew_seconds::Int`: Allowed clock skew for exp/nbf validation
"""
struct JWTValidator <: TokenValidator
    jwks_cache::Dict{String,Any}
    clock_skew_seconds::Int
end

JWTValidator(; clock_skew_seconds::Int=60) = JWTValidator(Dict{String,Any}(), clock_skew_seconds)

function Base.show(io::IO, v::JWTValidator)
    print(io, "JWTValidator(skew=", v.clock_skew_seconds, "s)")
end

"""
    decode_jwt_payload(token::String) -> Union{Dict{String,Any},Nothing}

Decode JWT payload without verification (for claim inspection).
Returns `nothing` if token format is invalid.
"""
function decode_jwt_payload(token::String)
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
function validate_jwt_claims(claims::Dict{String,Any}, config::OAuthConfig, clock_skew::Int)
    now_ts = round(Int, datetime2unix(now(UTC)))

    # Issuer: when an issuer is configured the token MUST carry a matching `iss`.
    # Fail closed if it is absent (a forged unsigned token must not pass by omission).
    if !isempty(config.issuer)
        iss = get(claims, "iss", nothing)
        if iss === nothing || iss != config.issuer
            return AuthResult("Invalid issuer", :invalid_issuer)
        end
    end

    # Audience: when an audience is configured the token MUST carry a matching `aud`.
    if !isempty(config.audience)
        aud = get(claims, "aud", nothing)
        valid_aud = if aud isa AbstractString
            aud == config.audience
        elseif aud isa AbstractVector
            config.audience in aud
        else
            false
        end
        if !valid_aud
            return AuthResult("Invalid audience", :invalid_audience)
        end
    end

    # Expiration is REQUIRED and must be in the future (no non-expiring tokens).
    exp = get(claims, "exp", nothing)
    if !(exp isa Number)
        return AuthResult("Token missing expiration", :invalid_token)
    end
    if now_ts > exp + clock_skew
        return AuthResult("Token expired", :expired)
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

"""
    decode_jwt_header(token::String) -> Union{Dict{String,Any},Nothing}

Decode the JWT header (first segment) without verification. Returns `nothing` if
the token format is invalid.
"""
function decode_jwt_header(token::String)
    parts = split(token, '.')
    length(parts) == 3 || return nothing
    try
        header_b64 = parts[1]
        padding = mod(4 - mod(length(header_b64), 4), 4)
        header_b64 = replace(header_b64 * repeat("=", padding), "-" => "+", "_" => "/")
        return JSON3.read(String(base64decode(header_b64)), Dict{String,Any})
    catch
        return nothing
    end
end

function validate_token(validator::JWTValidator, token::AbstractString, config::OAuthConfig)
    # WARNING: Decodes payload WITHOUT cryptographic signature verification.
    # Do not use with untrusted issuers. See JWTValidator docstring.
    tok = String(token)

    # Reject "alg: none" (unsigned) tokens outright. Even though we don't verify
    # signatures yet, accepting alg=none is a classic JWT authentication bypass.
    header = decode_jwt_header(tok)
    if isnothing(header)
        return AuthResult("Invalid JWT format", :invalid_format)
    end
    alg = get(header, "alg", nothing)
    if !(alg isa AbstractString) || isempty(alg) || lowercase(String(alg)) == "none"
        return AuthResult("Unsupported or missing JWT algorithm", :invalid_token)
    end

    claims = decode_jwt_payload(tok)
    if isnothing(claims)
        return AuthResult("Invalid JWT format", :invalid_format)
    end

    # Validate claims
    return validate_jwt_claims(claims, config, validator.clock_skew_seconds)
end

"""
    IntrospectionValidator(; client_id=nothing, client_secret=nothing)

Token validator using OAuth 2.0 Token Introspection (RFC 7662).
Used for opaque tokens that cannot be validated locally.

# Fields
- `client_id::Union{String,Nothing}`: Client ID for introspection auth
- `client_secret::Union{String,Nothing}`: Client secret for introspection auth
"""
struct IntrospectionValidator <: TokenValidator
    client_id::Union{String,Nothing}
    client_secret::Union{String,Nothing}
end

IntrospectionValidator(; client_id=nothing, client_secret=nothing) =
    IntrospectionValidator(client_id, client_secret)

function Base.show(io::IO, v::IntrospectionValidator)
    has_creds = !isnothing(v.client_id)
    print(io, "IntrospectionValidator(", has_creds ? "with credentials" : "no credentials", ")")
end

function validate_token(validator::IntrospectionValidator, token::AbstractString, config::OAuthConfig)
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

        body = "token=$(HTTP.URIs.escapeuri(String(token)))"

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

        # Audience / issuer binding: a token that is active at the AS but was minted
        # for a different resource must not be accepted here. Enforce when the
        # introspection response carries the claim (RFC 7662 responses vary).
        # When an issuer/audience is configured the introspection response MUST carry a
        # matching claim — fail closed if absent, so a token minted for another resource
        # (active at a shared AS) cannot be replayed here.
        if !isempty(config.issuer)
            iss = get(result, "iss", nothing)
            if iss === nothing || iss != config.issuer
                return AuthResult("Invalid issuer", :invalid_issuer)
            end
        end
        if !isempty(config.audience)
            aud = get(result, "aud", nothing)
            ok = aud isa AbstractString ? aud == config.audience :
                 aud isa AbstractVector ? config.audience in aud : false
            ok || return AuthResult("Invalid audience", :invalid_audience)
        end
        if haskey(result, "exp") && result["exp"] isa Number
            if round(Int, datetime2unix(now(UTC))) > result["exp"]
                return AuthResult("Token expired", :expired)
            end
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
        if e isa HTTP.StatusError
            return AuthResult("Introspection request failed: HTTP $(e.status)", :introspection_error)
        elseif e isa HTTP.RequestError
            return AuthResult("Introspection request failed: $(e.error)", :introspection_error)
        else
            rethrow(e)
        end
    end
end

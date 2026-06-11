# src/auth/token.jl
# Token validation implementations

using Base64
using Dates: datetime2unix
import JWTs

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

    # Check not-before. A present `nbf` MUST be numeric (RFC 7519 NumericDate); a
    # non-numeric value is malformed and rejected rather than silently ignored (which
    # would let a string nbf bypass the not-before gate).
    if haskey(claims, "nbf")
        nbf = claims["nbf"]
        nbf isa Number || return AuthResult("Token has malformed nbf", :invalid_token)
        if now_ts < nbf - clock_skew
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

# Upper bound on a JWKS document we will read into memory. Real JWKS documents are
# a few KB; 1 MB is generous headroom while bounding a compromised/misrouted endpoint.
const MAX_JWKS_BYTES = 1_000_000

"""
    JWKSValidator(jwks_uri::String; allowed_algs=["RS256", "RS384", "RS512"],
                  clock_skew_seconds=60, refresh_interval_seconds=300,
                  allow_insecure_http=false)
    JWKSValidator(keyset::JWTs.JWKSet; ...)

JWT validator with cryptographic signature verification against a JSON Web Key Set
(RFC 7517), plus the same claims validation as `JWTValidator` (iss, aud, exp, nbf,
scopes — all fail-closed). This is the recommended validator for JWTs from external
authorization servers (Keycloak, Auth0, GitHub Apps, etc.).

Keys are fetched lazily: construction never touches the network, so a server can
start while its authorization server is down (requests fail closed until keys load).
An unknown `kid` triggers a JWKS re-fetch (key rotation) at most once per
`refresh_interval_seconds` — rate-limited so attacker-supplied `kid` values cannot
hammer the JWKS endpoint. Fetches use bounded HTTP timeouts and a response size cap
(`MAX_JWKS_BYTES`), and never hold the validator lock during network I/O.

`file://` URIs are supported for local key sets. An `http://` URL is rejected at
construction unless `allow_insecure_http=true` (a plaintext JWKS lets an on-path
attacker swap in their own signing key — use only for localhost/testing). The second
constructor accepts a pre-built `JWTs.JWKSet` (e.g. static keys) directly; with no URL
it never refreshes.

!!! note "Algorithm allowlist"
    Tokens whose header `alg` is not in `allowed_algs` are rejected before any
    cryptography runs (this also rejects `alg=none`). The default allows the RSA
    family only; do not add HMAC algorithms (`HS*`) for keys published in a public
    JWKS document.

# Fields
- `keyset::JWTs.JWKSet`: Key set (url-backed or static) holding keys by `kid`
- `allowed_algs::Vector{String}`: Permitted JWT signature algorithms
- `clock_skew_seconds::Int`: Allowed clock skew for exp/nbf validation
- `refresh_interval_seconds::Float64`: Minimum seconds between JWKS fetch attempts (>= 0)
"""
mutable struct JWKSValidator <: TokenValidator
    keyset::JWTs.JWKSet
    allowed_algs::Vector{String}
    clock_skew_seconds::Int
    refresh_interval_seconds::Float64
    last_refresh_attempt::Float64  # time() of the last fetch attempt; -Inf = never
    lock::ReentrantLock
end

function JWKSValidator(keyset::JWTs.JWKSet;
                       allowed_algs::Vector{String}=["RS256", "RS384", "RS512"],
                       clock_skew_seconds::Int=60,
                       refresh_interval_seconds::Real=300,
                       allow_insecure_http::Bool=false)
    if startswith(keyset.url, "http://") && !allow_insecure_http
        throw(ArgumentError(
            "Refusing plaintext http:// JWKS URL '$(keyset.url)': an on-path attacker " *
            "could substitute signing keys. Use https://, or pass allow_insecure_http=true " *
            "for localhost/testing."))
    end
    # A negative interval is a configuration error; clamp to 0 (no throttle).
    JWKSValidator(keyset, allowed_algs, clock_skew_seconds,
                  max(0.0, Float64(refresh_interval_seconds)), -Inf, ReentrantLock())
end

JWKSValidator(jwks_uri::String; kwargs...) = JWKSValidator(JWTs.JWKSet(jwks_uri); kwargs...)

function Base.show(io::IO, v::JWKSValidator)
    nkeys = length(v.keyset.keys)
    src = isempty(v.keyset.url) ? "static" : v.keyset.url
    print(io, "JWKSValidator(", src, ", ", nkeys, " keys)")
end

"""
    fetch_jwks_keys(url::String) -> Union{Vector{Dict{String,Any}},Nothing}

Fetch and parse the `keys` array of a JWKS document from an `http(s)://` or `file://`
URL. Network fetches use bounded connect/read timeouts and reject responses larger than
`MAX_JWKS_BYTES` (read is aborted once the cap is exceeded, so an oversized or unbounded
body cannot exhaust memory). Returns `nothing` on any failure (fetch, oversize, parse,
or missing `keys` field) — callers fail closed.
"""
function fetch_jwks_keys(url::String)
    try
        body = if startswith(url, "file://")
            path = url[8:end]
            (isfile(path) && filesize(path) <= MAX_JWKS_BYTES) || return nothing
            read(path, String)
        else
            captured = fetch_jwks_http_body(url)
            captured === nothing && return nothing
            captured
        end
        parsed = JSON3.read(body)
        haskey(parsed, "keys") || return nothing
        # JWTs.refresh! expects plain Dicts (JSON.parse shape); JWK fields are flat strings
        return [Dict{String,Any}(String(k) => v for (k, v) in pairs(key)) for key in parsed["keys"]]
    catch e
        @debug "JWKS fetch failed" url=url error=e
        return nothing
    end
end

"""
    fetch_jwks_http_body(url::String) -> Union{String,Nothing}

GET a JWKS over HTTP(S) with bounded connect/read timeouts, streaming the body and
aborting once `MAX_JWKS_BYTES` is exceeded. Returns the body string on a 200, or
`nothing` on non-200, oversize, or transport error.
"""
function fetch_jwks_http_body(url::String)
    # HTTP.open returns the Response, not the closure's value, so capture the body
    # into a closed-over variable. It stays `nothing` on non-200 or oversize, both of
    # which leave callers failing closed.
    body = nothing
    HTTP.open("GET", url; connect_timeout=10, readtimeout=10, retry=false) do io
        HTTP.startread(io)
        HTTP.status(io.message) == 200 || return
        buf = IOBuffer()
        over = false
        while !eof(io)
            write(buf, readavailable(io))
            if buf.size > MAX_JWKS_BYTES  # over cap: abort the read, fail closed
                over = true
                break
            end
        end
        over || (body = String(take!(buf)))
    end
    return body
end

"""
    lookup_jwks_key!(validator::JWKSValidator, kid::String) -> Union{JWTs.JWK,Nothing}

Look up a verification key by `kid`, re-fetching the JWKS on a miss (key rotation)
subject to the refresh rate limit. The network fetch happens outside the validator
lock; the key-set swap and re-lookup happen under it.
"""
function lookup_jwks_key!(validator::JWKSValidator, kid::String)
    needs_refresh = lock(validator.lock) do
        key = get(validator.keyset.keys, kid, nothing)
        key !== nothing && return key
        isempty(validator.keyset.url) && return nothing
        if time() - validator.last_refresh_attempt >= validator.refresh_interval_seconds
            validator.last_refresh_attempt = time()
            return :refresh
        end
        nothing
    end
    needs_refresh === :refresh || return needs_refresh

    fresh = fetch_jwks_keys(validator.keyset.url)
    rebuilt = if fresh === nothing
        nothing
    else
        # JWTs.refresh! can throw on a malformed JWK entry (it reads kid/kty before its
        # own per-key try). Contain that so a bad upstream document fails auth closed
        # rather than 500-ing, and keep the previously cached keys on failure.
        try
            keys = Dict{String,JWTs.JWK}()
            JWTs.refresh!(fresh, keys)  # builds verification keys; skips unsupported entries
            keys
        catch e
            @debug "JWKS key build failed; retaining cached keys" error=e
            nothing
        end
    end
    lock(validator.lock) do
        rebuilt !== nothing && (validator.keyset.keys = rebuilt)
        get(validator.keyset.keys, kid, nothing)
    end
end

function validate_token(validator::JWKSValidator, token::AbstractString, config::OAuthConfig)
    tok = String(token)

    # Header gate before any cryptography: well-formed, allowlisted alg, kid present.
    header = decode_jwt_header(tok)
    isnothing(header) && return AuthResult("Invalid JWT format", :invalid_format)
    alg = get(header, "alg", nothing)
    if !(alg isa AbstractString) || !(String(alg) in validator.allowed_algs)
        return AuthResult("Unsupported or missing JWT algorithm", :invalid_token)
    end
    kid = get(header, "kid", nothing)
    if !(kid isa AbstractString) || isempty(kid)
        return AuthResult("JWT missing key id (kid)", :invalid_token)
    end

    key = lookup_jwks_key!(validator, String(kid))
    key === nothing && return AuthResult("Unknown signing key", :invalid_token)

    # Cryptographic signature verification. JWTs also cross-checks the token's alg
    # against the resolved key's algorithm, so a kid pointing at a key of a different
    # type cannot validate.
    jwt = JWTs.JWT(; jwt=tok)
    JWTs.issigned(jwt) || return AuthResult("Invalid JWT format", :invalid_format)
    verified = try
        JWTs.validate!(jwt, key; algorithms=validator.allowed_algs)
    catch
        false
    end
    verified === true || return AuthResult("Invalid token signature", :invalid_token)

    claims = decode_jwt_payload(tok)
    isnothing(claims) && return AuthResult("Invalid JWT format", :invalid_format)
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

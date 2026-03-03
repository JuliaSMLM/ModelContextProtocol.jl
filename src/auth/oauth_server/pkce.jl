# src/auth/oauth_server/pkce.jl
# PKCE (Proof Key for Code Exchange) implementation per RFC 7636
# Required by MCP 2025-11-25 specification

using SHA: sha256
using Base64: base64encode
using Random: rand

"""
    base64url_encode(data::Vector{UInt8}) -> String

Encode bytes using Base64 URL-safe encoding without padding.
Per RFC 7636 Appendix B.
"""
function base64url_encode(data::Vector{UInt8})
    b64 = base64encode(data)
    # Replace standard Base64 chars with URL-safe variants
    b64 = replace(b64, "+" => "-", "/" => "_")
    # Remove padding
    b64 = rstrip(b64, '=')
    return b64
end

"""
    compute_code_challenge(code_verifier::AbstractString, method::AbstractString="S256") -> String

Compute the code challenge from a code verifier.

# Arguments
- `code_verifier::AbstractString`: The PKCE code verifier (43-128 chars)
- `method::AbstractString`: Challenge method ("S256" or "plain")

# Returns
The computed code challenge string.
"""
function compute_code_challenge(code_verifier::AbstractString, method::AbstractString="S256")
    if method == "S256"
        # S256: BASE64URL(SHA256(ASCII(code_verifier)))
        hash = sha256(Vector{UInt8}(code_verifier))
        return base64url_encode(hash)
    elseif method == "plain"
        return String(code_verifier)
    else
        throw(ArgumentError("Unsupported code_challenge_method: $method"))
    end
end

"""
    validate_pkce(code_challenge::AbstractString, code_verifier::AbstractString,
                  method::AbstractString="S256") -> Bool

Validate a PKCE code verifier against the stored code challenge.

# Arguments
- `code_challenge::AbstractString`: The code challenge from the authorization request
- `code_verifier::AbstractString`: The code verifier from the token request
- `method::AbstractString`: The code challenge method ("S256" or "plain")

# Returns
`true` if the code verifier is valid, `false` otherwise.

# Example
```julia
# During authorization request, client sends:
#   code_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
#   code_challenge_method = "S256"

# During token request, client sends:
#   code_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

# Server validates:
valid = validate_pkce(code_challenge, code_verifier, "S256")
```
"""
function validate_pkce(
    code_challenge::AbstractString,
    code_verifier::AbstractString,
    method::AbstractString="S256"
)
    # Validate code_verifier format per RFC 7636 Section 4.1
    # Must be 43-128 characters from [A-Z] / [a-z] / [0-9] / "-" / "." / "_" / "~"
    if length(code_verifier) < 43 || length(code_verifier) > 128
        return false
    end

    # Check character set
    valid_chars = r"^[A-Za-z0-9\-._~]+$"
    if !occursin(valid_chars, code_verifier)
        return false
    end

    # Compute expected challenge and compare
    computed_challenge = compute_code_challenge(code_verifier, method)

    # Use constant-time comparison to prevent timing attacks
    return constant_time_compare(computed_challenge, String(code_challenge))
end

"""
    constant_time_compare(a::AbstractString, b::AbstractString) -> Bool

Compare two strings in constant time to prevent timing attacks.
"""
function constant_time_compare(a::AbstractString, b::AbstractString)
    # Convert to String to ensure consistent codeunit access
    sa = String(a)
    sb = String(b)

    if length(sa) != length(sb)
        return false
    end

    result = 0
    for (ca, cb) in zip(codeunits(sa), codeunits(sb))
        result |= ca ⊻ cb
    end

    return result == 0
end

"""
    generate_code_verifier(len::Int=64) -> String

Generate a random PKCE code verifier.
Useful for testing and client implementations.

# Arguments
- `len::Int`: Length of the verifier (43-128, default: 64)

# Returns
A random code verifier string.
"""
function generate_code_verifier(len::Int=64)
    if len < 43 || len > 128
        throw(ArgumentError("Code verifier length must be between 43 and 128"))
    end

    # Characters allowed per RFC 7636
    charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    n = Base.length(charset)
    return String([charset[rand(1:n)] for _ in 1:len])
end

"""
    validate_code_challenge_method(method::AbstractString) -> Bool

Check if a code challenge method is supported.
MCP spec requires S256 support.

# Arguments
- `method::AbstractString`: The code challenge method to validate

# Returns
`true` if the method is supported.
"""
function validate_code_challenge_method(method::AbstractString)
    return method in ("S256", "plain")
end

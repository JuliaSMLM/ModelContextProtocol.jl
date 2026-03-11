# src/auth/oauth_server/dcr.jl
# Dynamic Client Registration per RFC 7591
# Required for MCP clients like Claude Desktop to auto-register

using UUIDs: uuid4
using Dates

# RegisteredClient type is defined in types.jl

"""
    generate_client_id() -> String

Generate a unique client ID. Uses 16 hex chars (64 bits) for shorter URLs.
"""
function generate_client_id()
    return bytes2hex(rand(UInt8, 8))  # 16 chars instead of 36-char UUID
end

"""
    generate_client_secret() -> String

Generate a secure client secret.
"""
function generate_client_secret()
    # Generate 32 random bytes, base64url encode
    bytes = rand(UInt8, 32)
    return base64url_encode(bytes)
end

"""
    parse_registration_request(body::AbstractString) -> Dict{String,Any}

Parse a client registration request body.
Returns the parsed request or throws on invalid JSON.
"""
function parse_registration_request(body::AbstractString)
    if isempty(strip(body))
        return Dict{String,Any}()
    end
    return JSON3.read(body, Dict{String,Any})
end

"""
    validate_redirect_uris(uris::Vector) -> Bool

Validate redirect URIs per RFC 7591 and MCP requirements.
"""
function validate_redirect_uris(uris::Vector)
    for uri in uris
        # Must be valid URI
        try
            parsed = URIs.URI(uri)
            # For non-localhost, should be HTTPS
            if parsed.scheme == "http" && !startswith(parsed.host, "localhost") && !startswith(parsed.host, "127.")
                # Allow HTTP for localhost only
                @warn "Non-HTTPS redirect URI" uri=uri
            end
        catch
            return false
        end
    end
    return true
end

"""
    handle_client_registration(storage::TokenStorage, request::Dict{String,Any}, issuer::String) -> Tuple{Int,Dict{String,Any}}

Handle a dynamic client registration request per RFC 7591.

# Arguments
- `storage::TokenStorage`: Storage for registered clients
- `request::Dict{String,Any}`: Parsed registration request
- `issuer::String`: The authorization server issuer URL

# Returns
Tuple of (HTTP status code, response body as Dict)
"""
function handle_client_registration(
    storage::TokenStorage,
    request::Dict{String,Any},
    issuer::String
)
    # Extract client metadata from request
    client_name = get(request, "client_name", nothing)
    redirect_uris = get(request, "redirect_uris", String[])
    grant_types = get(request, "grant_types", ["authorization_code", "refresh_token"])
    response_types = get(request, "response_types", ["code"])
    token_endpoint_auth_method = get(request, "token_endpoint_auth_method", "none")

    # Validate redirect_uris if provided
    if !isempty(redirect_uris)
        if !validate_redirect_uris(redirect_uris)
            return (400, Dict{String,Any}(
                "error" => "invalid_redirect_uri",
                "error_description" => "One or more redirect_uris are invalid"
            ))
        end
    end

    # Validate grant_types - we only support authorization_code and refresh_token
    supported_grants = Set(["authorization_code", "refresh_token"])
    for grant in grant_types
        if !(grant in supported_grants)
            return (400, Dict{String,Any}(
                "error" => "invalid_client_metadata",
                "error_description" => "Unsupported grant_type: $grant"
            ))
        end
    end

    # Validate response_types - we only support "code"
    for rt in response_types
        if rt != "code"
            return (400, Dict{String,Any}(
                "error" => "invalid_client_metadata",
                "error_description" => "Unsupported response_type: $rt. Only 'code' is supported."
            ))
        end
    end

    # Validate token_endpoint_auth_method
    supported_auth_methods = Set(["none", "client_secret_post", "client_secret_basic"])
    if !(token_endpoint_auth_method in supported_auth_methods)
        return (400, Dict{String,Any}(
            "error" => "invalid_client_metadata",
            "error_description" => "Unsupported token_endpoint_auth_method: $token_endpoint_auth_method"
        ))
    end

    # Generate client credentials
    client_id = generate_client_id()

    # Generate secret only for confidential clients
    client_secret = nothing
    client_secret_expires_at = 0  # 0 means never expires
    if token_endpoint_auth_method != "none"
        client_secret = generate_client_secret()
    end

    # Create registered client
    client = RegisteredClient(
        client_id = client_id,
        client_secret = client_secret,
        client_name = client_name,
        redirect_uris = convert(Vector{String}, redirect_uris),
        grant_types = convert(Vector{String}, grant_types),
        response_types = convert(Vector{String}, response_types),
        token_endpoint_auth_method = token_endpoint_auth_method
    )

    # Store the client
    store_client!(storage, client)

    # Build response per RFC 7591 Section 3.2.1
    response = Dict{String,Any}(
        "client_id" => client_id,
        "client_id_issued_at" => Int(floor(datetime2unix(client.created_at))),
        "grant_types" => grant_types,
        "response_types" => response_types,
        "token_endpoint_auth_method" => token_endpoint_auth_method
    )

    # Include optional fields if present
    if !isnothing(client_secret)
        response["client_secret"] = client_secret
        response["client_secret_expires_at"] = client_secret_expires_at
    end

    if !isnothing(client_name)
        response["client_name"] = client_name
    end

    if !isempty(redirect_uris)
        response["redirect_uris"] = redirect_uris
    end

    return (201, response)
end

"""
    is_valid_client(storage::TokenStorage, client_id::String, redirect_uri::Union{String,Nothing}=nothing) -> Bool

Check if a client_id is valid (either registered or a known static client).

# Arguments
- `storage::TokenStorage`: Storage containing registered clients
- `client_id::String`: The client ID to validate
- `redirect_uri::Union{String,Nothing}`: Optional redirect URI to validate against registered URIs
"""
function is_valid_client(
    storage::TokenStorage,
    client_id::String,
    redirect_uri::Union{String,Nothing}=nothing
)
    client = get_client(storage, client_id)
    if isnothing(client)
        # For MCP, we allow any client_id for public clients
        # This enables simple testing and non-DCR clients
        return true
    end

    # If client is registered and redirect_uri is provided, validate it
    if !isnothing(redirect_uri) && !isempty(client.redirect_uris)
        return redirect_uri in client.redirect_uris
    end

    return true
end

"""
    validate_client_credentials(storage::TokenStorage, client_id::String, client_secret::Union{String,Nothing}) -> Bool

Validate client credentials for token endpoint authentication.
"""
function validate_client_credentials(
    storage::TokenStorage,
    client_id::String,
    client_secret::Union{String,Nothing}
)
    client = get_client(storage, client_id)

    if isnothing(client)
        # Unknown client - allow if no secret provided (public client)
        return isnothing(client_secret)
    end

    # Check auth method
    if client.token_endpoint_auth_method == "none"
        # Public client - no secret needed
        return true
    else
        # Confidential client - secret required
        if isnothing(client_secret) || isnothing(client.client_secret)
            return false
        end
        return constant_time_compare(client_secret, client.client_secret)
    end
end

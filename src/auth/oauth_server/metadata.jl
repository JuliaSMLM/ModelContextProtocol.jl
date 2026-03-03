# src/auth/oauth_server/metadata.jl
# Authorization Server Metadata per RFC 8414
# and OpenID Connect Discovery 1.0 support

"""
    AUTHORIZATION_SERVER_METADATA_PATH

Standard path for OAuth 2.0 Authorization Server Metadata (RFC 8414).
"""
const AUTHORIZATION_SERVER_METADATA_PATH::String = "/.well-known/oauth-authorization-server"

"""
    OPENID_CONFIGURATION_PATH

Standard path for OpenID Connect Discovery 1.0.
"""
const OPENID_CONFIGURATION_PATH::String = "/.well-known/openid-configuration"

"""
    build_authorization_server_metadata(config::OAuthServerConfig) -> Dict{String,Any}

Build the Authorization Server Metadata document per RFC 8414.

# Arguments
- `config::OAuthServerConfig`: The OAuth server configuration

# Returns
A dictionary containing the metadata fields.
"""
function build_authorization_server_metadata(config::OAuthServerConfig)
    metadata = Dict{String,Any}(
        "issuer" => config.issuer,
        "authorization_endpoint" => config.authorization_endpoint,
        "token_endpoint" => config.token_endpoint,
        "response_types_supported" => config.response_types_supported,
        "grant_types_supported" => config.grant_types_supported,
        "code_challenge_methods_supported" => config.code_challenge_methods_supported,
        "token_endpoint_auth_methods_supported" => config.token_endpoint_auth_methods_supported,
    )

    # Optional fields
    if !isnothing(config.registration_endpoint)
        metadata["registration_endpoint"] = config.registration_endpoint
    end

    if !isempty(config.scopes_supported)
        metadata["scopes_supported"] = config.scopes_supported
    end

    # MCP 2025-11-25 spec additions
    # Indicate support for Client ID Metadata Documents
    metadata["client_id_metadata_document_supported"] = true

    return metadata
end

"""
    handle_authorization_server_metadata(config::OAuthServerConfig) -> Tuple{Int,String,Dict{String,String}}

Handle a request to the authorization server metadata endpoint.

# Arguments
- `config::OAuthServerConfig`: The OAuth server configuration

# Returns
Tuple of (status_code, body, headers).
"""
function handle_authorization_server_metadata(config::OAuthServerConfig)
    metadata = build_authorization_server_metadata(config)
    body = JSON3.write(metadata)

    headers = Dict{String,String}(
        "Content-Type" => "application/json",
        "Cache-Control" => "max-age=3600"  # Cache for 1 hour
    )

    return (200, body, headers)
end

"""
    is_authorization_server_metadata_path(path::AbstractString, issuer::AbstractString) -> Bool

Check if a request path matches an authorization server metadata endpoint.

Per MCP 2025-11-25, clients should try multiple discovery paths.
For issuer with path: Try path-specific variants first.
For issuer without path: Try root variants.

# Arguments
- `path::AbstractString`: The request path
- `issuer::AbstractString`: The authorization server issuer URL

# Returns
`true` if the path is a metadata endpoint.
"""
function is_authorization_server_metadata_path(path::AbstractString, issuer::AbstractString)
    # Parse issuer to extract path component
    issuer_uri = URIs.URI(issuer)
    issuer_path = issuer_uri.path

    # Root-level metadata paths
    if path == AUTHORIZATION_SERVER_METADATA_PATH
        return true
    end
    if path == OPENID_CONFIGURATION_PATH
        return true
    end

    # Path-specific variants (for multi-tenant setups)
    if !isempty(issuer_path) && issuer_path != "/"
        # RFC 8414: /.well-known/oauth-authorization-server/{path}
        path_specific = "$(AUTHORIZATION_SERVER_METADATA_PATH)$(issuer_path)"
        if path == path_specific
            return true
        end

        # OIDC: /.well-known/openid-configuration/{path}
        oidc_path_specific = "$(OPENID_CONFIGURATION_PATH)$(issuer_path)"
        if path == oidc_path_specific
            return true
        end

        # OIDC path append: {path}/.well-known/openid-configuration
        oidc_append = "$(issuer_path)/.well-known/openid-configuration"
        if path == oidc_append
            return true
        end
    end

    return false
end

# src/auth/metadata.jl
# Protected Resource Metadata per RFC 9728 and MCP 2025-11-25 spec

"""
    create_protected_resource_metadata(resource_url::String,
                                       authorization_servers::Vector{String};
                                       scopes::Vector{String}=String[]) -> ProtectedResourceMetadata

Create Protected Resource Metadata for the MCP server.

# Arguments
- `resource_url::String`: The URL of your MCP server (the protected resource)
- `authorization_servers::Vector{String}`: URLs of OAuth authorization servers
- `scopes::Vector{String}`: OAuth scopes the server understands

# Example
```julia
metadata = create_protected_resource_metadata(
    "https://mcp.example.com",
    ["https://github.com/login/oauth"],
    scopes = ["read:user", "repo"]
)
```
"""
function create_protected_resource_metadata(
    resource_url::String,
    authorization_servers::Vector{String};
    scopes::Vector{String} = String[]
)::ProtectedResourceMetadata
    return ProtectedResourceMetadata(
        resource = resource_url,
        authorization_servers = authorization_servers,
        scopes_supported = scopes,
        bearer_methods_supported = ["header"]
    )
end

"""
    metadata_to_json(metadata::ProtectedResourceMetadata) -> String

Serialize Protected Resource Metadata to JSON for HTTP response.
"""
function metadata_to_json(metadata::ProtectedResourceMetadata)::String
    return JSON3.write(Dict{String,Any}(
        "resource" => metadata.resource,
        "authorization_servers" => metadata.authorization_servers,
        "scopes_supported" => metadata.scopes_supported,
        "bearer_methods_supported" => metadata.bearer_methods_supported
    ))
end

"""
    WELL_KNOWN_PATH

Standard path for Protected Resource Metadata.
"""
const WELL_KNOWN_PATH = "/.well-known/oauth-protected-resource"

"""
    handle_well_known_request(metadata::ProtectedResourceMetadata) -> Tuple{Int,String,Dict{String,String}}

Handle a request to the .well-known/oauth-protected-resource endpoint.

# Returns
- Tuple of (status_code, body, headers)
"""
function handle_well_known_request(metadata::ProtectedResourceMetadata)
    body = metadata_to_json(metadata)
    headers = Dict{String,String}(
        "Content-Type" => "application/json",
        "Cache-Control" => "max-age=3600"  # Cache for 1 hour
    )
    return (200, body, headers)
end

"""
    GitHubAuthorizationServer

Pre-configured authorization server metadata for GitHub OAuth.
"""
const GitHubAuthorizationServer = "https://github.com/login/oauth"

"""
    create_github_resource_metadata(resource_url::String;
                                   scopes::Vector{String}=["read:user"]) -> ProtectedResourceMetadata

Create Protected Resource Metadata configured for GitHub OAuth.

# Arguments
- `resource_url::String`: Your MCP server URL
- `scopes::Vector{String}`: GitHub OAuth scopes to request (default: ["read:user"])

# Example
```julia
metadata = create_github_resource_metadata(
    "https://mcp.lidkelab.org",
    scopes = ["read:user", "read:org"]
)
```
"""
function create_github_resource_metadata(
    resource_url::String;
    scopes::Vector{String} = ["read:user"]
)::ProtectedResourceMetadata
    return create_protected_resource_metadata(
        resource_url,
        [GitHubAuthorizationServer],
        scopes = scopes
    )
end

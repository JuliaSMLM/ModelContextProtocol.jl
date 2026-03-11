# src/protocol/versioning.jl
# MCP Protocol Version Management
#
# Handles version negotiation and feature gating based on negotiated protocol version.
# Per MCP spec: if client requests a version we support, respond with that version.
# Otherwise, respond with our latest version and let client decide.

"""
Latest MCP protocol version supported by this implementation.
"""
const LATEST_PROTOCOL_VERSION = "2025-11-25"

"""
All MCP protocol versions supported by this implementation, newest first.
"""
const SUPPORTED_PROTOCOL_VERSIONS = [
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05"
]

"""
Minimum protocol version required for each feature.

Features are identified by Symbol keys. The value is the minimum protocol version
that introduced the feature. Use `supports(version, feature)` to check availability.

# Features
- `:tasks` - Experimental task tracking (SEP-1686)
- `:sse_priming_events` - SSE priming for stream resumability (SEP-1699)
- `:icon_metadata` - Icon metadata for tools/resources/prompts (SEP-973)
- `:tool_calling_in_sampling` - Tool calling in sampling requests (SEP-1577)
- `:oauth_openid_connect` - OpenID Connect discovery for OAuth (PR #797)
- `:oauth_incremental_scope` - Incremental scope consent (SEP-835)
- `:streamable_http` - Streamable HTTP transport
- `:resource_links` - ResourceLink content type
"""
const FEATURE_VERSIONS = Dict{Symbol, String}(
    # 2025-11-25 features
    :tasks => "2025-11-25",
    :sse_priming_events => "2025-11-25",
    :icon_metadata => "2025-11-25",
    :tool_calling_in_sampling => "2025-11-25",
    :oauth_openid_connect => "2025-11-25",
    :oauth_incremental_scope => "2025-11-25",
    :url_elicitation => "2025-11-25",

    # 2025-06-18 features
    :resource_links => "2025-06-18",

    # 2025-03-26 features
    :streamable_http => "2025-03-26",
)

"""
    negotiate_version(client_version::Union{AbstractString, Nothing}) -> String

Negotiate protocol version with client per MCP specification.

If client requests a version we support, return that version.
Otherwise, return our latest version (client decides if compatible).

# Arguments
- `client_version`: Protocol version requested by client, or nothing

# Returns
- `String`: The negotiated protocol version
"""
function negotiate_version(client_version::Union{AbstractString, Nothing})::String
    if !isnothing(client_version) && client_version in SUPPORTED_PROTOCOL_VERSIONS
        return String(client_version)
    end
    return LATEST_PROTOCOL_VERSION
end

"""
    supports(version::AbstractString, feature::Symbol) -> Bool

Check if a protocol version supports a specific feature.

# Arguments
- `version`: The negotiated protocol version
- `feature`: Feature identifier (see `FEATURE_VERSIONS` for available features)

# Returns
- `Bool`: true if the version supports the feature

# Example
```julia
if supports(session.protocol_version, :tasks)
    # Include task tracking in response
end

if supports(ctx.protocol_version, :sse_priming_events)
    send_priming_event(stream)
end
```
"""
function supports(version::AbstractString, feature::Symbol)::Bool
    min_version = get(FEATURE_VERSIONS, feature, nothing)
    isnothing(min_version) && return false
    return version >= min_version
end

"""
    is_supported_version(version::AbstractString) -> Bool

Check if a protocol version is in our supported versions list.

# Arguments
- `version`: Protocol version string to check

# Returns
- `Bool`: true if we support this version
"""
function is_supported_version(version::AbstractString)::Bool
    return version in SUPPORTED_PROTOCOL_VERSIONS
end

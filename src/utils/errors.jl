# src/utils/errors.jl

"""
    ErrorCodes

Define standard error codes used in the JSON-RPC and MCP protocols.
"""
module ErrorCodes
    # JSON-RPC standard error codes
    const PARSE_ERROR = -32700
    const INVALID_REQUEST = -32600
    const METHOD_NOT_FOUND = -32601
    const INVALID_PARAMS = -32602
    const INTERNAL_ERROR = -32603
    
    # MCP specific error codes. These predate the 2026-07-28 error-code allocation
    # policy and sit in the grandfathered implementation-defined sub-range
    # (-32000..-32019); they are legal for legacy-era responses but MUST NOT be
    # emitted on modern-era (2026-07-28+) responses.
    const RESOURCE_NOT_FOUND = -32000
    const TOOL_NOT_FOUND = -32001
    const INVALID_URI = -32002
    const PROMPT_NOT_FOUND = -32003
    const INSUFFICIENT_SCOPE = -32004  # authenticated principal lacks a tool's required_scopes

    # Spec-defined error codes from the reserved sub-range (-32020..-32099),
    # introduced by the 2026-07-28 revision
    const HEADER_MISMATCH = -32020                     # HTTP header does not match request body
    const MISSING_REQUIRED_CLIENT_CAPABILITY = -32021  # request needs an undeclared client capability
    const UNSUPPORTED_PROTOCOL_VERSION = -32022        # requested protocol version not supported
end
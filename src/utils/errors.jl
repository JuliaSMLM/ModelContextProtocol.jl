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
    
    # MCP specific error codes
    const RESOURCE_NOT_FOUND = -32000
    const TOOL_NOT_FOUND = -32001
    const INVALID_URI = -32002
    const PROMPT_NOT_FOUND = -32003
    const INSUFFICIENT_SCOPE = -32004  # authenticated principal lacks a tool's required_scopes
end
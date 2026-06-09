# src/protocol/messages.jl

"""
    RequestMeta(; progress_token::Union{ProgressToken,Nothing}=nothing)

Metadata for MCP protocol requests, including progress tracking information.

# Fields
- `progress_token::Union{ProgressToken,Nothing}`: Optional token for tracking request progress
"""
Base.@kwdef struct RequestMeta
    progress_token::Union{ProgressToken,Nothing} = nothing
end

"""
    ClientCapabilities(; experimental::Union{Dict{String,Dict{String,Any}},Nothing}=nothing,
                    roots::Union{Dict{String,Bool},Nothing}=nothing,
                    sampling::Union{Dict{String,Any},Nothing}=nothing)

Capabilities reported by an MCP client during initialization.

# Fields
- `experimental::Union{Dict{String,Dict{String,Any}},Nothing}`: Experimental features supported
- `roots::Union{Dict{String,Bool},Nothing}`: Root directories client has access to
- `sampling::Union{Dict{String,Any},Nothing}`: Sampling capabilities for model generation
"""
Base.@kwdef struct ClientCapabilities
    experimental::Union{Dict{String,Dict{String,Any}},Nothing} = nothing
    roots::Union{Dict{String,Bool},Nothing} = nothing
    sampling::Union{Dict{String,Any},Nothing} = nothing
end

"""
    Implementation(; name::String="default-client", version::String="1.0.0",
                   title::Union{String,Nothing}=nothing,
                   description::Union{String,Nothing}=nothing)

Information about a client or server implementation of the MCP protocol.

# Fields
- `name::String`: Name of the implementation
- `version::String`: Version string of the implementation
- `title::Union{String,Nothing}`: Optional human-readable display name
- `description::Union{String,Nothing}`: Optional human-readable description (MCP 2025-11-25)
"""
Base.@kwdef struct Implementation
    name::String = "default-client"
    version::String = "1.0.0"
    title::Union{String,Nothing} = nothing
    description::Union{String,Nothing} = nothing
end

"""
    InitializeParams(; capabilities::ClientCapabilities=ClientCapabilities(),
                   clientInfo::Implementation=Implementation(),
                   protocolVersion::Union{String,Nothing}=nothing) <: RequestParams

Parameters for MCP protocol initialization requests.

# Fields
- `capabilities::ClientCapabilities`: Client capabilities being reported
- `clientInfo::Implementation`: Information about the client implementation  
- `protocolVersion::Union{String,Nothing}`: Version of the MCP protocol requested by the client. The server negotiates against `SUPPORTED_PROTOCOL_VERSIONS` (latest: `LATEST_PROTOCOL_VERSION`); see `negotiate_version`.
"""
Base.@kwdef struct InitializeParams <: RequestParams
    capabilities::ClientCapabilities = ClientCapabilities()
    clientInfo::Implementation = Implementation()
    protocolVersion::Union{String,Nothing} = nothing  # Negotiated against SUPPORTED_PROTOCOL_VERSIONS
end

"""
    InitializeResult(; serverInfo::Dict{String,Any}, capabilities::Dict{String,Any},
                   protocolVersion::String, instructions::String="") <: ResponseResult

Result returned in response to MCP protocol initialization.

# Fields
- `serverInfo::Dict{String,Any}`: Information about the server implementation
- `capabilities::Dict{String,Any}`: Server capabilities being reported
- `protocolVersion::String`: Version of the MCP protocol being used
- `instructions::String`: Optional usage instructions for clients
"""
Base.@kwdef struct InitializeResult <: ResponseResult
    serverInfo::Dict{String,Any}
    capabilities::Dict{String,Any}
    protocolVersion::String
    instructions::String = ""
end

#= Resource-Related Messages =#

"""
    ListResourcesParams(; cursor::Union{String,Nothing}=nothing) <: RequestParams

Parameters for requesting a list of available resources from an MCP server.

# Fields
- `cursor::Union{String,Nothing}`: Optional pagination cursor for long resource lists
"""
Base.@kwdef struct ListResourcesParams <: RequestParams
    cursor::Union{String,Nothing} = nothing
end

"""
    ListResourcesResult(; resources::Vector{Dict{String,Any}}, 
                      nextCursor::Union{String,Nothing}=nothing) <: ResponseResult

Result returned from a list resources request.

# Fields
- `resources::Vector{Dict{String,Any}}`: List of available resources with their metadata
- `nextCursor::Union{String,Nothing}`: Optional pagination cursor for fetching more resources
"""
Base.@kwdef struct ListResourcesResult <: ResponseResult
    resources::Vector{Dict{String,Any}}
    nextCursor::Union{String,Nothing} = nothing
end

"""
    ReadResourceParams(; uri::String) <: RequestParams

Parameters for requesting the contents of a specific resource.

# Fields
- `uri::String`: URI identifier of the resource to read
"""
Base.@kwdef struct ReadResourceParams <: RequestParams
    uri::String
end

"""
    ReadResourceResult(; contents::Vector{Dict{String,Any}}) <: ResponseResult

Result returned from a read resource request.

# Fields
- `contents::Vector{Dict{String,Any}}`: The contents of the requested resource
"""
Base.@kwdef struct ReadResourceResult <: ResponseResult
    contents::Vector{Dict{String,Any}}
end

#= Tool-Related Messages =#

"""
    ListToolsParams(; cursor::Union{String,Nothing}=nothing) <: RequestParams

Parameters for requesting a list of available tools from an MCP server.

# Fields
- `cursor::Union{String,Nothing}`: Optional pagination cursor for long tool lists
"""
Base.@kwdef struct ListToolsParams <: RequestParams 
    cursor::Union{String,Nothing} = nothing
end

"""
    ListToolsResult(; tools::Vector{Dict{String,Any}}, 
                  nextCursor::Union{String,Nothing}=nothing) <: ResponseResult

Result returned from a list tools request.

# Fields
- `tools::Vector{Dict{String,Any}}`: List of available tools with their metadata
- `nextCursor::Union{String,Nothing}`: Optional pagination cursor for fetching more tools
"""
Base.@kwdef struct ListToolsResult <: ResponseResult
    tools::Vector{Dict{String,Any}}
    nextCursor::Union{String,Nothing} = nothing
end

"""
    CallToolParams(; name::String, arguments::Union{Dict{String,Any},Nothing}=nothing) <: RequestParams

Parameters for invoking a specific tool on an MCP server.

# Fields
- `name::String`: Name of the tool to call
- `arguments::Union{Dict{String,Any},Nothing}`: Optional arguments to pass to the tool
"""
Base.@kwdef struct CallToolParams <: RequestParams
    name::String
    arguments::Union{Dict{String,Any},Nothing} = nothing
end

"""
    CallToolResult(; content::Vector{Dict{String,Any}}, is_error::Bool=false,
                   structured_content=nothing) <: ResponseResult

Result returned from a tool invocation.

# Fields
- `content::Vector{Dict{String,Any}}`: Content produced by the tool
- `is_error::Bool`: Whether the tool execution resulted in an error
- `structured_content::Union{Nothing,AbstractDict}`: Optional structured result (a JSON
  object per the MCP spec), serialized as `structuredContent` and omitted when `nothing`.
  Pair it with the tool's `output_schema` so clients can validate and consume it
  programmatically. Per the spec, a tool returning structured content SHOULD also include
  a human-readable serialization (e.g. the JSON as text) in `content` for clients that
  don't consume structured output.
- `_meta::Union{Nothing,AbstractDict}`: Optional result metadata for protocol extensions,
  serialized as `_meta` and omitted when `nothing`
"""
Base.@kwdef struct CallToolResult <: ResponseResult
    content::Vector{Dict{String,Any}}
    is_error::Bool = false
    structured_content::Union{Nothing,AbstractDict} = nothing
    _meta::Union{Nothing,AbstractDict} = nothing
end

#= Prompt-Related Messages =#

"""
    ListPromptsParams(; cursor::Union{String,Nothing}=nothing) <: RequestParams

Parameters for requesting a list of available prompts from an MCP server.

# Fields
- `cursor::Union{String,Nothing}`: Optional pagination cursor for long prompt lists
"""
Base.@kwdef struct ListPromptsParams <: RequestParams
    cursor::Union{String,Nothing} = nothing
end

"""
    ListPromptsResult(; prompts::Vector{Dict{String,Any}}, 
                    nextCursor::Union{String,Nothing}=nothing) <: ResponseResult

Result returned from a list prompts request.

# Fields
- `prompts::Vector{Dict{String,Any}}`: List of available prompts with their metadata
- `nextCursor::Union{String,Nothing}`: Optional pagination cursor for fetching more prompts
"""
Base.@kwdef struct ListPromptsResult <: ResponseResult
    prompts::Vector{Dict{String,Any}}
    nextCursor::Union{String,Nothing} = nothing
end

"""
    GetPromptParams(; name::String, arguments::Union{Dict{String,String},Nothing}=nothing) <: RequestParams

Parameters for requesting a specific prompt from an MCP server.

# Fields
- `name::String`: Name of the prompt to retrieve
- `arguments::Union{Dict{String,String},Nothing}`: Optional arguments to apply to the prompt template
"""
Base.@kwdef struct GetPromptParams <: RequestParams
    name::String
    arguments::Union{Dict{String,String},Nothing} = nothing
end

"""
    GetPromptResult(; description::String, messages::Vector{PromptMessage}) <: ResponseResult

Result returned from a get prompt request.

# Fields
- `description::String`: Description of the prompt
- `messages::Vector{PromptMessage}`: The prompt messages with template variables replaced
"""
Base.@kwdef struct GetPromptResult <: ResponseResult
    description::String
    messages::Vector{PromptMessage}
end

#= Logging Messages =#

"""
    SetLevelParams(; level::String) <: RequestParams

Parameters for `logging/setLevel` requests.

# Fields
- `level::String`: Minimum log level the client wants to receive (one of the MCP/RFC-5424
  levels: "debug", "info", "notice", "warning", "error", "critical", "alert", "emergency")
"""
Base.@kwdef struct SetLevelParams <: RequestParams
    level::String
end

#= Progress and Error Messages =#

"""
    ProgressParams(; progress_token::ProgressToken, progress::Float64,
                 total::Union{Float64,Nothing}=nothing) <: RequestParams

Parameters for progress notifications during long-running operations.

# Fields
- `progress_token::ProgressToken`: Token identifying the operation being reported on
- `progress::Float64`: Current progress value
- `total::Union{Float64,Nothing}`: Optional total expected value
"""
Base.@kwdef struct ProgressParams <: RequestParams
    progress_token::ProgressToken
    progress::Float64
    total::Union{Float64,Nothing} = nothing
end

"""
    ErrorInfo(; code::Int, message::String, data::Union{Dict{String,Any},Nothing}=nothing)

Error information structure for JSON-RPC error responses.

# Fields
- `code::Int`: Numeric error code (predefined in ErrorCodes module)
- `message::String`: Human-readable error description
- `data::Union{Dict{String,Any},Nothing}`: Optional additional error details
"""
Base.@kwdef struct ErrorInfo
    code::Int
    message::String
    data::Union{Dict{String,Any},Nothing} = nothing
end

#= JSON-RPC Message Types =#

"""
    JSONRPCRequest(; id::RequestId, method::String, 
                 params::Union{RequestParams, Nothing}, 
                 meta::RequestMeta=RequestMeta()) <: Request

JSON-RPC request message used to invoke methods on the server.

# Fields
- `id::RequestId`: Unique identifier for the request
- `method::String`: Name of the method to invoke
- `params::Union{RequestParams, Nothing}`: Parameters for the method
- `meta::RequestMeta`: Additional metadata for the request
"""
Base.@kwdef struct JSONRPCRequest <: Request
    id::RequestId
    method::String
    params::Union{RequestParams, Nothing} = nothing
    meta::RequestMeta = RequestMeta()
end

"""
    JSONRPCResponse(; id::RequestId, result::Union{ResponseResult,AbstractDict{String,Any}}) <: Response

JSON-RPC response message returned for successful requests.

# Fields
- `id::RequestId`: Identifier matching the request this is responding to
- `result::Union{ResponseResult,AbstractDict{String,Any}}`: Results of the method execution
"""
Base.@kwdef struct JSONRPCResponse <: Response
    id::RequestId
    result::Union{ResponseResult,AbstractDict{String,Any}}
end

"""
    JSONRPCError(; id::Union{RequestId,Nothing}, error::ErrorInfo) <: Response

JSON-RPC error response message returned when requests fail.

# Fields
- `id::Union{RequestId,Nothing}`: Identifier matching the request this is responding to, or null
- `error::ErrorInfo`: Information about the error that occurred
"""
Base.@kwdef struct JSONRPCError <: Response
    id::Union{RequestId,Nothing} 
    error::ErrorInfo
end

"""
    JSONRPCNotification(; method::String, 
                       params::Union{RequestParams,Dict{String,Any}}) <: Notification

JSON-RPC notification message that does not expect a response.

# Fields
- `method::String`: Name of the notification method
- `params::Union{RequestParams,Dict{String,Any}}`: Parameters for the notification
"""
Base.@kwdef struct JSONRPCNotification <: Notification
    method::String
    params::Union{RequestParams,Dict{String,Any}}
end


# src/types_consolidated.jl
# Consolidated type definitions in dependency order

#==============================================================================
# 1. Core Enums and Type Aliases
==============================================================================#

"""
    Role

Enum representing roles in the MCP protocol.

# Values
- `user`: Content or messages from the user
- `assistant`: Content or messages from the assistant
"""
@enum Role user assistant

"""
    RequestId

Type alias for JSON-RPC request identifiers.

# Type
Union{String,Int} - Can be either a string or integer identifier
"""
const RequestId = Union{String,Int}

"""
    ProgressToken

Type alias for tokens used to track long-running operations.

# Type
Union{String,Int} - Can be either a string or integer identifier
"""
const ProgressToken = Union{String,Int}

#==============================================================================
# 2. Abstract Base Types
==============================================================================#

"""
    MCPMessage

Abstract base type for all message types in the MCP protocol.
Serves as the root type for requests, responses, and notifications.
"""
abstract type MCPMessage end

"""
    Request <: MCPMessage

Abstract base type for client-to-server requests in the MCP protocol.
Request messages expect a corresponding response from the server.
"""
abstract type Request <: MCPMessage end

"""
    Response <: MCPMessage

Abstract base type for server-to-client responses in the MCP protocol.
Response messages are sent from the server in reply to client requests.
"""
abstract type Response <: MCPMessage end

"""
    Notification <: MCPMessage

Abstract base type for one-way notifications in the MCP protocol.
Notification messages don't expect a corresponding response.
"""
abstract type Notification <: MCPMessage end

"""
    RequestParams

Abstract base type for all parameter structures in MCP protocol requests.
Concrete subtypes define parameters for specific request methods.
"""
abstract type RequestParams end

"""
    ResponseResult

Abstract base type for all result structures in MCP protocol responses.
Concrete subtypes define result formats for specific response methods.
"""
abstract type ResponseResult end

"""
    Content

Abstract base type for all content formats in the MCP protocol.
Content can be exchanged between clients and servers in various formats.
"""
abstract type Content end

"""
    ResourceContents

Abstract base type for resource content formats in the MCP protocol.
Resources can contain different types of content based on their MIME type.
"""
abstract type ResourceContents end

"""
    Capability

Abstract base type for all MCP protocol capabilities.
Capabilities represent protocol features that servers can support.
Concrete implementations define configuration for specific feature sets.
"""
abstract type Capability end

"""
    Tool

Abstract base type for all MCP tools.
Tools represent operations that can be invoked by clients.
"""
abstract type Tool end

"""
    Resource

Abstract base type for all MCP resources.
Resources represent data that can be read by clients.
"""
abstract type Resource end

#==============================================================================
# 3. Content Types (needed by tools, prompts, resources)
==============================================================================#

"""
    TextContent(; type::String="text", text::String, 
                annotations::Union{Nothing,Dict{String,Any}}=nothing,
                _meta::Union{Nothing,Dict{String,Any}}=nothing) <: Content

Text-based content for messages and tool responses.

# Fields
- `type::String`: Content type identifier (always "text")
- `text::String`: The actual text content
- `annotations::Union{Nothing,Dict{String,Any}}`: Optional annotations for the client
- `_meta::Union{Nothing,Dict{String,Any}}`: Optional metadata for protocol extensions
"""
Base.@kwdef struct TextContent <: Content
    type::String = "text"
    text::String
    annotations::Union{Nothing,Dict{String,Any}} = nothing
    _meta::Union{Nothing,Dict{String,Any}} = nothing
end

"""
    ImageContent(; type::String="image", data::Vector{UInt8}, mime_type::String,
                 annotations::Union{Nothing,Dict{String,Any}}=nothing,
                 _meta::Union{Nothing,Dict{String,Any}}=nothing) <: Content

Image content for messages and tool responses.

# Fields
- `type::String`: Content type identifier (always "image")
- `data::Vector{UInt8}`: Raw image data (automatically base64-encoded when serialized)
- `mime_type::String`: MIME type of the image (e.g., "image/png")
- `annotations::Union{Nothing,Dict{String,Any}}`: Optional annotations for the client
- `_meta::Union{Nothing,Dict{String,Any}}`: Optional metadata for protocol extensions
"""
Base.@kwdef struct ImageContent <: Content
    type::String = "image"
    data::Vector{UInt8}
    mime_type::String
    annotations::Union{Nothing,Dict{String,Any}} = nothing
    _meta::Union{Nothing,Dict{String,Any}} = nothing
end

"""
    TextResourceContents(; uri::URI, mime_type::String="text/plain", text::String) <: ResourceContents

Text content for resources in the MCP protocol.

# Fields
- `uri::URI`: Resource identifier
- `mime_type::String`: MIME type of the text content
- `text::String`: The actual text content
"""
Base.@kwdef struct TextResourceContents <: ResourceContents
    uri::URI
    mime_type::String = "text/plain"
    text::String
end

"""
    BlobResourceContents(; uri::URI, mime_type::String="application/octet-stream", 
                        blob::Vector{UInt8}) <: ResourceContents

Binary content for resources.

# Fields
- `uri::URI`: Resource identifier
- `mime_type::String`: MIME type of the binary content
- `blob::Vector{UInt8}`: Raw binary data (automatically base64-encoded when serialized)
"""
Base.@kwdef struct BlobResourceContents <: ResourceContents
    uri::URI
    mime_type::String = "application/octet-stream"
    blob::Vector{UInt8}
end

"""
    EmbeddedResource(; type::String="resource", resource::Dict{String,Any},
                     annotations::Union{Nothing,Dict{String,Any}}=nothing,
                     _meta::Union{Nothing,Dict{String,Any}}=nothing) <: Content

Embedded resource content for inline resource data.

# Fields
- `type::String`: Content type identifier (always "resource")
- `resource::Dict{String,Any}`: The embedded resource data
- `annotations::Union{Nothing,Dict{String,Any}}`: Optional annotations for the client
- `_meta::Union{Nothing,Dict{String,Any}}`: Optional metadata for protocol extensions
"""
Base.@kwdef struct EmbeddedResource <: Content
    type::String = "resource"
    resource::Dict{String,Any}
    annotations::Union{Nothing,Dict{String,Any}} = nothing
    _meta::Union{Nothing,Dict{String,Any}} = nothing
end

"""
    ResourceLink(; type::String="link", href::String, 
                 title::Union{String,Nothing}=nothing,
                 annotations::Union{Nothing,Dict{String,Any}}=nothing,
                 _meta::Union{Nothing,Dict{String,Any}}=nothing) <: Content

Link to an external resource (NEW in protocol 2025-06-18).

# Fields
- `type::String`: Content type identifier (always "link")
- `href::String`: URL or URI of the linked resource
- `title::Union{String,Nothing}`: Optional human-readable title for the link
- `annotations::Union{Nothing,Dict{String,Any}}`: Optional annotations for the client
- `_meta::Union{Nothing,Dict{String,Any}}`: Optional metadata for protocol extensions
"""
Base.@kwdef struct ResourceLink <: Content
    type::String = "link"
    href::String
    title::Union{String,Nothing} = nothing
    annotations::Union{Nothing,Dict{String,Any}} = nothing
    _meta::Union{Nothing,Dict{String,Any}} = nothing
end

#==============================================================================
# 4. Tool Types
==============================================================================#

"""
    ToolParameter(; name::String, description::String, type::String, required::Bool=false, default::Any=nothing)

Define a parameter for an MCP tool.

# Fields
- `name::String`: The parameter name (used as the key in the params dictionary)
- `description::String`: Human-readable description of the parameter
- `type::String`: Type of the parameter as specified in the MCP schema (e.g., "string", "number", "boolean")
- `required::Bool`: Whether the parameter is required for tool invocation
- `default::Any`: Default value for the parameter if not provided (nothing means no default)
"""
Base.@kwdef struct ToolParameter
    name::String
    description::String
    type::String 
    required::Bool = false
    default::Any = nothing
end

"""
    MCPTool(; name::String, description::String, parameters::Vector{ToolParameter},
          handler::Function, return_type::Type=Vector{Content}) <: Tool

Implement a tool that can be invoked by clients in the MCP protocol.

# Fields
- `name::String`: Unique identifier for the tool
- `description::String`: Human-readable description of the tool's purpose
- `parameters::Vector{ToolParameter}`: Parameters that the tool accepts
- `handler::Function`: Function that implements the tool's functionality
- `return_type::Type`: Expected return type of the handler (defaults to Vector{Content})

# Handler Return Types
The tool handler can return various types which are automatically converted:
- An instance of the specified Content type (TextContent, ImageContent, etc.)
- A Vector{<:Content} for multiple content items (can mix TextContent, ImageContent, etc.)
- A Dict (automatically converted to JSON and wrapped in TextContent)
- A String (automatically wrapped in TextContent)
- A Tuple{Vector{UInt8}, String} (automatically wrapped in ImageContent)
- A CallToolResult object for full control over the response (including error handling)

When return_type is Vector{Content} (default), single Content items are automatically wrapped in a vector.
Note: When returning CallToolResult directly, the return_type field is ignored.
"""
Base.@kwdef struct MCPTool <: Tool
    name::String
    description::String
    parameters::Vector{ToolParameter}
    handler::Function
    return_type::Type = Vector{Content}  # Can be Content subtype or Vector{<:Content}
end

#==============================================================================
# 5. Prompt Types
==============================================================================#

"""
    PromptArgument(; name::String, description::String="", required::Bool=false)

Define an argument that a prompt template can accept.

# Fields
- `name::String`: The argument name (used in template placeholders)
- `description::String`: Human-readable description of the argument
- `required::Bool`: Whether the argument is required when using the prompt
"""
Base.@kwdef struct PromptArgument
    name::String
    description::String = ""
    required::Bool = false
end

"""
    PromptMessage(; content::Union{TextContent, ImageContent, EmbeddedResource}, role::Role=user)

Represent a single message in a prompt template.

# Fields
- `content::Union{TextContent, ImageContent, EmbeddedResource}`: The content of the message
- `role::Role`: Whether this message is from the user or assistant (defaults to user)
"""
Base.@kwdef struct PromptMessage
    content::Union{TextContent, ImageContent, EmbeddedResource}
    role::Role = user  # Set default in the kwdef constructor
end

"""
    PromptMessage(content::Union{TextContent, ImageContent, EmbeddedResource}) -> PromptMessage

Create a prompt message with only content (role defaults to user).

# Arguments
- `content::Union{TextContent, ImageContent, EmbeddedResource}`: The message content

# Returns
- `PromptMessage`: A new prompt message with the default user role
"""
function PromptMessage(content::Union{TextContent, ImageContent, EmbeddedResource})
    PromptMessage(content = content)
end

"""
    MCPPrompt(; name::String, description::String="", 
            arguments::Vector{PromptArgument}=PromptArgument[], 
            messages::Vector{PromptMessage}=PromptMessage[])

Implement a prompt or prompt template as defined in the MCP schema.
Prompts can include variables that are replaced with arguments when retrieved.

# Fields
- `name::String`: Unique identifier for the prompt
- `description::String`: Human-readable description of the prompt's purpose
- `arguments::Vector{PromptArgument}`: Arguments that this prompt accepts
- `messages::Vector{PromptMessage}`: The sequence of messages in the prompt
"""
Base.@kwdef struct MCPPrompt
    name::String
    description::String = ""
    arguments::Vector{PromptArgument} = PromptArgument[]
    messages::Vector{PromptMessage} = PromptMessage[]
end

"""
    MCPPrompt(name::String, description::String, arguments::Vector{PromptArgument}, text::String) -> MCPPrompt

Create a prompt with a single text message.

# Arguments
- `name::String`: Unique identifier for the prompt
- `description::String`: Human-readable description
- `arguments::Vector{PromptArgument}`: Arguments the prompt accepts
- `text::String`: Text content for the prompt message

# Returns
- `MCPPrompt`: A new prompt with a single user message containing the text
"""
function MCPPrompt(name::String, description::String, arguments::Vector{PromptArgument}, text::String)
    MCPPrompt(
        name = name,
        description = description,
        arguments = arguments,
        messages = [PromptMessage(content = TextContent(text = text), role = user)]
    )
end

#==============================================================================
# 6. Resource Types
==============================================================================#

"""
    MCPResource <: Resource

Implement a resource that clients can access in the MCP protocol.
Resources represent data that can be read by models and tools.

# Fields
- `uri::URI`: Unique identifier for the resource
- `name::String`: Human-readable name for the resource
- `description::String`: Detailed description of the resource
- `mime_type::String`: MIME type of the resource data
- `data_provider::Function`: Function that provides the resource data when called
- `annotations::AbstractDict{String,Any}`: Additional metadata for the resource
"""
struct MCPResource <: Resource
    uri::URI
    name::String
    description::String
    mime_type::String
    data_provider::Function
    annotations::AbstractDict{String,Any}
end

"""
    MCPResource(; uri, name::String="", description::String="",
              mime_type::String="application/json", data_provider::Function,
              annotations::AbstractDict{String,Any}=LittleDict{String,Any}()) -> MCPResource

Create a resource with automatic URI conversion from strings or URIs.

# Arguments
- `uri`: String or URI identifier for the resource
- `name::String`: Human-readable name for the resource
- `description::String`: Detailed description
- `mime_type::String`: MIME type of the resource
- `data_provider::Function`: Function that returns the resource data when called
- `annotations::AbstractDict{String,Any}`: Additional metadata for the resource

# Returns
- `MCPResource`: A new resource with the provided configuration
"""
function MCPResource(; uri, 
    name::String = "", 
    description::String = "", 
    mime_type::String = "application/json", 
    data_provider::Function, 
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}())
    uri_obj = uri isa URI ? uri : URI(uri)
    MCPResource(uri_obj, name, description, mime_type, data_provider, annotations)
end

"""
    ResourceTemplate(; name::String, uri_template::String,
                   mime_type::Union{String,Nothing}=nothing, description::String="")

Define a template for dynamically generating resources with parameterized URIs.

# Fields
- `name::String`: Name of the resource template
- `uri_template::String`: Template string with placeholders for parameters
- `mime_type::Union{String,Nothing}`: MIME type of the generated resources
- `description::String`: Human-readable description of the template
"""
Base.@kwdef struct ResourceTemplate
    name::String
    uri_template::String
    mime_type::Union{String,Nothing} = nothing
    description::String = ""
end

#==============================================================================
# 7. Subscription and Progress Types
==============================================================================#

"""
    Subscription(; uri::String, callback::Function, created_at::DateTime=now())

Define a subscription to resource updates in the MCP protocol.

# Fields
- `uri::String`: The URI of the subscribed resource
- `callback::Function`: Function to call when the resource is updated
- `created_at::DateTime`: When the subscription was created
"""
Base.@kwdef struct Subscription
    uri::String
    callback::Function
    created_at::DateTime = now()
end

"""
    Progress(; token::Union{String,Int}, current::Float64, 
            total::Union{Float64,Nothing}=nothing, message::Union{String,Nothing}=nothing)

Track progress of long-running operations in the MCP protocol.

# Fields
- `token::Union{String,Int}`: Unique identifier for the progress tracker
- `current::Float64`: Current progress value
- `total::Union{Float64,Nothing}`: Optional total expected value
- `message::Union{String,Nothing}`: Optional status message
"""
Base.@kwdef struct Progress
    token::Union{String,Int}
    current::Float64
    total::Union{Float64,Nothing} = nothing
    message::Union{String,Nothing} = nothing
end

#==============================================================================
# 8. Server Configuration Types
==============================================================================#

"""
    ServerConfig(; name::String, version::String="1.0.0", 
               description::String="", capabilities::Vector{Capability}=Capability[],
               instructions::String="")

Define configuration settings for an MCP server instance.

# Fields
- `name::String`: The server name shown to clients
- `version::String`: Server implementation version (e.g., "1.0.0", "2.3.1") - YOUR server's version, not the protocol version
- `description::String`: Human-readable server description
- `capabilities::Vector{Capability}`: Protocol capabilities supported by the server
- `instructions::String`: Usage instructions for clients
"""
Base.@kwdef struct ServerConfig
    name::String
    version::String = "1.0.0"  # Default server version for convenience
    description::String = ""
    capabilities::Vector{Capability} = Capability[]
    instructions::String = ""
end

"""
    ServerState()

Track the internal state of an MCP server during operation.

# Fields
- `initialized::Bool`: Whether the server has been initialized by a client
- `running::Bool`: Whether the server main loop is active
- `last_request_id::Int`: Last used request ID for server-initiated requests
- `pending_requests::Dict{RequestId,String}`: Map of request IDs to method names
"""
mutable struct ServerState
    initialized::Bool
    running::Bool
    last_request_id::Int
    pending_requests::Dict{RequestId, String}  # method name for each pending request
    
    ServerState() = new(false, false, 0, Dict())
end

# Server type moved to server_types.jl to resolve Transport dependency

"""
    ServerError(message::String) <: Exception

Exception type for MCP server-specific errors.

# Fields
- `message::String`: The error message describing what went wrong
"""
struct ServerError <: Exception
    message::String
end

#==============================================================================
# 9. Utility Functions and Type Conversions
==============================================================================#

"""
    convert(::Type{URI}, s::String) -> URI

Convert a string to a URI object.

# Arguments
- `s::String`: The string to convert

# Returns
- `URI`: The resulting URI object
"""
Base.convert(::Type{URI}, s::String) = URI(s)

# Pretty printing
Base.show(io::IO, config::ServerConfig) = print(io, "ServerConfig($(config.name) v$(config.version))")
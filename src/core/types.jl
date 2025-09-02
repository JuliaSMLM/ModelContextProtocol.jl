# src/core/types.jl

# 1. Core enums/aliases

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

# 2. Core abstract types

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
Concrete implementations define specific tool functionality and parameters.
"""
abstract type Tool end

"""
    Resource

Abstract base type for all MCP resources.
Resources represent data that can be read and accessed by clients.
Concrete implementations define specific resource types and access methods.
"""
abstract type Resource end

"""
    ResourceContents

Abstract base type for contents of MCP resources.
ResourceContents represent the actual data stored in resources.
Concrete implementations define specific content formats (text, binary, etc.).
"""
abstract type ResourceContents end


# 3. Core concrete types

"""
    TextContent(; text::String, annotations::AbstractDict{String,Any}=LittleDict{String,Any}()) <: Content

Text-based content for MCP protocol messages.

# Fields
- `type::String`: Content type identifier (always "text")
- `text::String`: The actual text content
- `annotations::AbstractDict{String,Any}`: Optional metadata about the content
"""
Base.@kwdef struct TextContent <: Content
    type::String = "text"  # Schema requires this to be const "text"
    text::String
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}()
end

"""
    ImageContent(; data::Vector{UInt8}, mime_type::String, annotations::AbstractDict{String,Any}=LittleDict{String,Any}()) <: Content

Image-based content for MCP protocol messages.

# Fields
- `type::String`: Content type identifier (always "image")
- `data::Vector{UInt8}`: The binary image data
- `mime_type::String`: MIME type of the image (e.g., "image/png")
- `annotations::AbstractDict{String,Any}`: Optional metadata about the content
"""
Base.@kwdef struct ImageContent <: Content
    type::String = "image"  # Schema requires this to be const "image"
    data::Vector{UInt8}
    mime_type::String
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}()
end

"""
    TextResourceContents(; uri::String, text::String, mime_type::Union{String,Nothing}=nothing) <: ResourceContents

Text-based contents for MCP resources.

# Fields
- `uri::String`: Unique identifier for the resource
- `text::String`: The text content of the resource
- `mime_type::Union{String,Nothing}`: Optional MIME type of the content
"""
Base.@kwdef struct TextResourceContents <: ResourceContents
    uri::String
    text::String
    mime_type::Union{String,Nothing} = nothing
end

"""
    BlobResourceContents(; uri::String, blob::Vector{UInt8}, mime_type::Union{String,Nothing}=nothing) <: ResourceContents

Binary contents for MCP resources.

# Fields
- `uri::String`: Unique identifier for the resource
- `blob::Vector{UInt8}`: The binary content of the resource
- `mime_type::Union{String,Nothing}`: Optional MIME type of the content
"""
Base.@kwdef struct BlobResourceContents <: ResourceContents
    uri::String
    blob::Vector{UInt8}
    mime_type::Union{String,Nothing} = nothing
end

"""
    EmbeddedResource(; resource::Union{TextResourceContents, BlobResourceContents}, 
                    annotations::AbstractDict{String,Any}=LittleDict{String,Any}()) <: Content

Embedded resource content as defined in MCP schema.

# Fields
- `type::String`: Content type identifier (always "resource")
- `resource::Union{TextResourceContents, BlobResourceContents}`: The embedded resource content
- `annotations::AbstractDict{String,Any}`: Optional metadata about the resource
"""
Base.@kwdef struct EmbeddedResource <: Content
    type::String = "resource"  # Schema requires this to be const "resource"
    resource::Union{TextResourceContents, BlobResourceContents}
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}()
end

"""
    ResourceLink(; uri::String, name::String, description::Union{String,Nothing}=nothing, 
                mime_type::Union{String,Nothing}=nothing, title::Union{String,Nothing}=nothing,
                size::Union{Float64,Nothing}=nothing, annotations::AbstractDict{String,Any}=LittleDict{String,Any}()) <: Content

Resource link content for MCP protocol 2025-06-18. References a resource that the server is capable of reading.

# Fields
- `type::String`: Content type identifier (always "resource_link")
- `uri::String`: The URI of the resource being referenced
- `name::String`: Programmatic identifier for the resource
- `description::Union{String,Nothing}`: Optional description of the resource
- `mime_type::Union{String,Nothing}`: Optional MIME type of the resource
- `title::Union{String,Nothing}`: Optional human-friendly display name
- `size::Union{Float64,Nothing}`: Optional size of the resource in bytes
- `annotations::AbstractDict{String,Any}`: Optional metadata about the resource link
"""
Base.@kwdef struct ResourceLink <: Content
    type::String = "resource_link"  # Schema requires this to be const "resource_link"
    uri::String
    name::String
    description::Union{String,Nothing} = nothing
    mime_type::Union{String,Nothing} = nothing
    title::Union{String,Nothing} = nothing
    size::Union{Float64,Nothing} = nothing
    annotations::AbstractDict{String,Any} = LittleDict{String,Any}()
end

"""
    Progress(; token::Union{String,Int}, current::Float64, 
            total::Union{Float64,Nothing}=nothing, message::Union{String,Nothing}=nothing)

Tracks progress of long-running operations in the MCP protocol.

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

"""
    Subscription(; uri::String, callback::Function, created_at::DateTime=now())

Represents subscriptions to resource updates in the MCP protocol.

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

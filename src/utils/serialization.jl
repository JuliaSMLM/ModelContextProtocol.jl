# src/utils/serialization.jl

"""
    StructTypes definitions for MCP types

Define serialization behavior for ModelContextProtocol types via StructTypes.jl.
This module configures how various MCP types are serialized to and from JSON.
"""

# Add StructTypes support for JSON serialization
StructTypes.StructType(::Type{TextContent}) = StructTypes.Struct()
StructTypes.StructType(::Type{ImageContent}) = StructTypes.Struct()
StructTypes.StructType(::Type{TextResourceContents}) = StructTypes.Struct()
StructTypes.StructType(::Type{BlobResourceContents}) = StructTypes.Struct()
StructTypes.StructType(::Type{EmbeddedResource}) = StructTypes.Struct()
StructTypes.StructType(::Type{ClientCapabilities}) = StructTypes.Struct()
StructTypes.StructType(::Type{Implementation}) = StructTypes.Struct()
StructTypes.StructType(::Type{InitializeParams}) = StructTypes.Struct()
StructTypes.StructType(::Type{RequestMeta}) = StructTypes.Struct()
StructTypes.StructType(::Type{ErrorInfo}) = StructTypes.Struct()
StructTypes.StructType(::Type{ListResourcesParams}) = StructTypes.Struct()
StructTypes.StructType(::Type{ListPromptsParams}) = StructTypes.Struct()
StructTypes.StructType(::Type{GetPromptParams}) = StructTypes.Struct()
StructTypes.StructType(::Type{PromptMessage}) = StructTypes.Struct()
StructTypes.StructType(::Type{T}) where {T<:RequestParams} = StructTypes.Struct()
StructTypes.StructType(::Type{T}) where {T<:ResponseResult} = StructTypes.Struct()

"""
    StructTypes.omitempties(::Type{ClientCapabilities}) -> Tuple{Symbol,Symbol,Symbol}

Specify which fields should be omitted from JSON serialization when they are empty or null.

# Arguments
- `::Type{ClientCapabilities}`: The ClientCapabilities type

# Returns
- `Tuple{Symbol,Symbol,Symbol}`: Fields to omit when empty
"""
function StructTypes.omitempties(::Type{ClientCapabilities})
    (:experimental, :roots, :sampling)
end

"""
    StructTypes.omitempties(::Type{ListPromptsResult}) -> Tuple{Symbol}

Specify which fields should be omitted from JSON serialization when they are empty or null.

# Arguments
- `::Type{ListPromptsResult}`: The ListPromptsResult type

# Returns
- `Tuple{Symbol}`: Fields to omit when empty
"""
function StructTypes.omitempties(::Type{ListPromptsResult})
    (:nextCursor,)
end

"""
    content2dict(content::Content) -> Dict{String,Any}

Convert a Content object to its dictionary representation for JSON serialization.

# Arguments
- `content::Content`: The content object to convert

# Returns
- `Dict{String,Any}`: Dictionary representation of the content

# Examples
```julia
text_content = TextContent(text="Hello", type="text")
dict = content2dict(text_content)
# Returns: Dict("type" => "text", "text" => "Hello", "annotations" => Dict())
```
"""
function content2dict end

# TextContent conversion
function content2dict(content::TextContent)
    LittleDict{String,Any}(
        "type" => "text",
        "text" => content.text,
        "annotations" => content.annotations
    )
end

# ImageContent conversion
function content2dict(content::ImageContent)
    LittleDict{String,Any}(
        "type" => "image",
        "data" => base64encode(content.data),
        "mimeType" => content.mime_type,
        "annotations" => content.annotations
    )
end

# EmbeddedResource conversion
function content2dict(content::EmbeddedResource)
    LittleDict{String,Any}(
        "type" => "resource",
        "resource" => serialize_resource_contents(content.resource),
        "annotations" => content.annotations
    )
end

# ResourceLink conversion (new in MCP protocol 2025-06-18)
function content2dict(content::ResourceLink)
    result = LittleDict{String,Any}(
        "type" => "resource_link",
        "uri" => content.uri,
        "name" => content.name,
        "annotations" => content.annotations
    )
    
    # Add optional fields only if they're not nothing
    !isnothing(content.description) && (result["description"] = content.description)
    !isnothing(content.mime_type) && (result["mimeType"] = content.mime_type)
    !isnothing(content.title) && (result["title"] = content.title)
    !isnothing(content.size) && (result["size"] = content.size)
    
    return result
end

# Generic fallback for unknown content types
function content2dict(content::Content)
    throw(ArgumentError("Unsupported content type: $(typeof(content))"))
end


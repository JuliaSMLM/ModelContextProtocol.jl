# src/utils/serialization.jl

"""
    JSON serialization rules for MCP types

JSON.jl serializes structs by field name. Wire-key renames live on the struct
definitions as `JSON.@kwarg` field tags (e.g. `CallToolResult.is_error` → `isError`);
the type-level `omit_null`/`omit_empty` rules below drop optional fields from the wire.
"""

"""
    JSON.omit_null(::Type{ClientCapabilities}) -> Bool

Omit `nothing`-valued capability fields (`experimental`, `roots`, `sampling`) from JSON.
"""
JSON.omit_null(::Type{ClientCapabilities}) = true

"""
    JSON.omit_empty(::Type{ClientCapabilities}) -> Bool

Omit empty capability objects from JSON.
"""
JSON.omit_empty(::Type{ClientCapabilities}) = true

"""
    JSON.omit_null(::Type{ListPromptsResult}) -> Bool

Omit `nextCursor` from JSON when it is `nothing`.
"""
JSON.omit_null(::Type{ListPromptsResult}) = true

"""
    JSON.omit_null(::Type{CallToolResult}) -> Bool

Omit `structuredContent` and `_meta` from the response when they are `nothing`, so
tools that don't use them emit no `structuredContent`/`_meta` keys.
"""
JSON.omit_null(::Type{CallToolResult}) = true

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
    result = LittleDict{String,Any}(
        "type" => "text",
        "text" => content.text
    )
    # Add optional fields if present
    !isnothing(content.annotations) && (result["annotations"] = content.annotations)
    !isnothing(content._meta) && (result["_meta"] = content._meta)
    return result
end

# ImageContent conversion
function content2dict(content::ImageContent)
    result = LittleDict{String,Any}(
        "type" => "image",
        "data" => base64encode(content.data),
        "mimeType" => content.mime_type
    )
    # Add optional fields if present
    !isnothing(content.annotations) && (result["annotations"] = content.annotations)
    !isnothing(content._meta) && (result["_meta"] = content._meta)
    return result
end

# AudioContent conversion
function content2dict(content::AudioContent)
    result = LittleDict{String,Any}(
        "type" => "audio",
        "data" => base64encode(content.data),
        "mimeType" => content.mime_type
    )
    # Add optional fields if present
    !isnothing(content.annotations) && (result["annotations"] = content.annotations)
    !isnothing(content._meta) && (result["_meta"] = content._meta)
    return result
end

# EmbeddedResource conversion
function content2dict(content::EmbeddedResource)
    result = LittleDict{String,Any}(
        "type" => "resource",
        "resource" => content.resource
    )
    # Add optional fields if present
    !isnothing(content.annotations) && (result["annotations"] = content.annotations)
    !isnothing(content._meta) && (result["_meta"] = content._meta)
    return result
end

# ResourceLink conversion (new in MCP protocol 2025-06-18)
function content2dict(content::ResourceLink)
    result = LittleDict{String,Any}(
        "type" => "resource_link",
        "uri" => content.uri,
        "name" => content.name
    )

    # Add optional fields if present
    !isnothing(content.description) && (result["description"] = content.description)
    !isnothing(content.mime_type) && (result["mimeType"] = content.mime_type)
    !isnothing(content.size) && (result["size"] = content.size)
    !isnothing(content.title) && (result["title"] = content.title)
    !isnothing(content.annotations) && (result["annotations"] = content.annotations)
    !isnothing(content._meta) && (result["_meta"] = content._meta)

    return result
end

# Generic fallback for unknown content types
function content2dict(content::Content)
    throw(ArgumentError("Unsupported content type: $(typeof(content))"))
end

# Let `Content` objects be placed directly into fields/collections typed
# `Dict{String,Any}` — notably `CallToolResult.content::Vector{Dict{String,Any}}`. Tool
# handlers (and the docs) construct
# `CallToolResult(content = [TextContent(...)], is_error = true)`; without this method the
# per-element field conversion throws `MethodError(convert, Dict{String,Any}, TextContent)`.
# Routing through `content2dict` makes the wire shape identical to the auto-wrap path.
Base.convert(::Type{Dict{String,Any}}, content::Content) = Dict{String,Any}(content2dict(content))


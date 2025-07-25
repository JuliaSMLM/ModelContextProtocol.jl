# src/features/tools.jl

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
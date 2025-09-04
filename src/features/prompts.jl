# src/features/prompts.jl


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

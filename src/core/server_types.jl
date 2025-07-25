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

"""
    ServerError(message::String) <: Exception

Exception type for MCP server-specific errors.

# Fields
- `message::String`: The error message describing what went wrong
"""
struct ServerError <: Exception
    message::String
end

"""
    ServerConfig(; name::String, version::String="1.0.0", 
               description::String="", capabilities::Vector{Capability}=Capability[],
               instructions::String="")

Define configuration settings for an MCP server instance.

# Fields
- `name::String`: The server name shown to clients
- `version::String`: Server version string
- `description::String`: Human-readable server description
- `capabilities::Vector{Capability}`: Protocol capabilities supported by the server
- `instructions::String`: Usage instructions for clients
"""
Base.@kwdef struct ServerConfig
    name::String
    version::String = "2024-11-05"
    description::String = ""
    capabilities::Vector{Capability} = Capability[]
    instructions::String = ""
end

"""
    Server(config::ServerConfig; transport::Union{Transport,Nothing}=nothing)

Represent a running MCP server instance that manages resources, tools, and prompts.

# Fields
- `config::ServerConfig`: Server configuration settings
- `transport::Union{Transport,Nothing}`: Transport implementation for client-server communication
- `resources::Vector{Resource}`: Available resources
- `tools::Vector{Tool}`: Available tools
- `prompts::Vector{MCPPrompt}`: Available prompts
- `resource_templates::Vector{ResourceTemplate}`: Available resource templates
- `subscriptions::DefaultDict{String,Vector{Subscription}}`: Resource subscription registry
- `progress_trackers::Dict{Union{String,Int},Progress}`: Progress tracking for operations
- `active::Bool`: Whether the server is currently active

# Constructor
- `Server(config::ServerConfig; transport=nothing)`: Creates a new server with the specified configuration
"""
mutable struct Server
    config::ServerConfig
    transport::Union{Transport,Nothing}
    resources::Vector{Resource}
    tools::Vector{Tool}
    prompts::Vector{MCPPrompt}
    resource_templates::Vector{ResourceTemplate}
    subscriptions::DefaultDict{String,Vector{Subscription}}
    progress_trackers::Dict{Union{String,Int}, Progress}
    active::Bool
    
    function Server(config::ServerConfig; transport::Union{Transport,Nothing}=nothing)
        new(
            config,
            transport,
            Resource[],
            Tool[],
            MCPPrompt[],
            ResourceTemplate[],
            DefaultDict{String,Vector{Subscription}}(() -> Subscription[]),
            Dict{Union{String,Int}, Progress}(),
            false
        )
    end
end

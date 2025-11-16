# src/server_types.jl
# Server type definition (depends on Transport from transports/base.jl)

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

# Pretty printing
Base.show(io::IO, server::Server) = print(io, "MCP Server($(server.config.name), $(server.active ? "active" : "inactive"))")
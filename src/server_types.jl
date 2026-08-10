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
- `tasks::TaskStore`: Registry of server-side tasks (MCP Tasks, experimental)
- `listen_subscriptions::SubscriptionRegistry`: Active modern-era `subscriptions/listen` streams
- `active::Bool`: Whether the server is currently active
- `task_notification_queue::Union{Channel{Any},Nothing}`: `notifications/tasks`
  dispatch FIFO (set by `install_task_notifications!`, closed by `stop!`)
- `tool_header_paths::Dict{String,Vector{Tuple{Vector{String},String}}}`: per-tool
  SEP-2243 mirror tables — derived from the normalized schema by
  `validate_tool_headers` and persisted by `register!`, read by the
  `handle_modern_request` preflight

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
    tasks::TaskStore
    listen_subscriptions::SubscriptionRegistry
    mrtr_state_key::Vector{UInt8}  # HMAC key for MRTR requestState tokens (ephemeral, per-server)
    active::Bool
    task_notification_queue::Union{Channel{Any},Nothing}  # notifications/tasks dispatch FIFO (see install_task_notifications!); closed by stop!
    tool_header_paths::Dict{String,Vector{Tuple{Vector{String},String}}}  # per-tool SEP-2243 mirror tables (validate_tool_headers, persisted by register!)
    legacy_state::Union{ServerState,Nothing}  # the running loop's session state (set by start!) — how notify_* reach the legacy session's wire_subscriptions

    function Server(config::ServerConfig; transport::Union{Transport,Nothing}=nothing,
                    mrtr_state_key::Union{Vector{UInt8},Nothing}=nothing)
        # The MRTR requestState signing key: random-per-server by default (safe for
        # a single instance — a restart just invalidates in-flight retries), or a
        # deployment-shared key so retries survive routing across replicas
        if mrtr_state_key !== nothing && length(mrtr_state_key) < 32
            throw(ArgumentError("mrtr_state_key must be at least 32 bytes"))
        end
        new(
            config,
            transport,
            Resource[],
            Tool[],
            MCPPrompt[],
            ResourceTemplate[],
            DefaultDict{String,Vector{Subscription}}(() -> Subscription[]),
            Dict{Union{String,Int}, Progress}(),
            TaskStore(),
            SubscriptionRegistry(),
            something(mrtr_state_key, rand(RandomDevice(), UInt8, 32)),
            false,
            nothing,
            Dict{String,Vector{Tuple{Vector{String},String}}}(),
            nothing
        )
    end
end

# Pretty printing
Base.show(io::IO, server::Server) = print(io, "MCP Server($(server.config.name), $(server.active ? "active" : "inactive"))")
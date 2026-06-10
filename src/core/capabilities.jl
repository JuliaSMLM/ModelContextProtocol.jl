"""
    ResourceCapability(; list_changed::Bool=false, subscribe::Bool=false)

Configure resource-related capabilities for an MCP server.

# Fields
- `list_changed::Bool`: Whether server supports notifications when resource listings change.
- `subscribe::Bool`: Whether server supports subscriptions to resource updates.
"""
Base.@kwdef struct ResourceCapability <: Capability
    list_changed::Bool = false
    subscribe::Bool = false
end

"""
    ToolCapability(; list_changed::Bool=false)

Configure tool-related capabilities for an MCP server.

# Fields
- `list_changed::Bool`: Whether server supports notifications when tool listings change.
"""
Base.@kwdef struct ToolCapability <: Capability
    list_changed::Bool = false
end

"""
    PromptCapability(; list_changed::Bool=false)

Configure prompt-related capabilities for an MCP server.

# Fields
- `list_changed::Bool`: Whether server supports notifications when prompt listings change.
"""
Base.@kwdef struct PromptCapability <: Capability
    list_changed::Bool = false
end

"""
    LoggingCapability(; levels::Vector{String}=["info", "warn", "error"])

Configure logging-related capabilities for an MCP server.

# Fields
- `levels::Vector{String}`: Supported logging levels.
"""
Base.@kwdef struct LoggingCapability <: Capability
    levels::Vector{String} = ["info", "warn", "error"]
end

"""
    TaskCapability(; list::Bool=true, cancel::Bool=true)

Configure MCP Tasks support (SEP-1686, experimental): task-augmented `tools/call`
plus the `tasks/get`, `tasks/result`, and optionally `tasks/list`/`tasks/cancel`
operations. Only advertised to clients that negotiated protocol 2025-11-25 or later.

# Fields
- `list::Bool`: Whether `tasks/list` is offered. Note: on an HTTP transport without
  authentication the server cannot identify requestors, so `list` is withheld from the
  advertised capability regardless of this setting (per the spec's security guidance).
- `cancel::Bool`: Whether `tasks/cancel` is offered.
"""
Base.@kwdef struct TaskCapability <: Capability
    list::Bool = true
    cancel::Bool = true
end

"""
    to_protocol_format(cap::Capability) -> Dict{String,Any}

Convert an MCP capability to the JSON format expected by the MCP protocol.

# Arguments
- `cap::Capability`: The capability to convert.

# Returns
- `Dict{String,Any}`: Protocol-formatted capability dictionary.
"""
function to_protocol_format(cap::ResourceCapability)
    LittleDict{String,Any}(
        "listChanged" => cap.list_changed,
        "subscribe" => cap.subscribe
    )
end

function to_protocol_format(cap::ToolCapability)
    LittleDict{String,Any}(
        "listChanged" => cap.list_changed
    )
end

function to_protocol_format(cap::PromptCapability)
    LittleDict{String,Any}(
        "listChanged" => cap.list_changed
    )
end

function to_protocol_format(cap::LoggingCapability)
    LittleDict{String,Any}()  # Logging capability just needs to be present
end

function to_protocol_format(cap::TaskCapability)
    d = LittleDict{String,Any}()
    cap.list && (d["list"] = LittleDict{String,Any}())
    cap.cancel && (d["cancel"] = LittleDict{String,Any}())
    d["requests"] = LittleDict{String,Any}(
        "tools" => LittleDict{String,Any}("call" => LittleDict{String,Any}())
    )
    d
end

"""
    CapabilityResponse(; 
        listChanged::Bool=false, 
        subscribe::Union{Bool,Nothing}=nothing, 
        tools::Union{Dict{String,Any},Nothing}=nothing, 
        resources::Union{Vector{Dict{String,Any}},Nothing}=nothing)

Define response structure for capabilities including tool and resource listings.

# Fields
- `listChanged::Bool`: Whether listings can change during server lifetime.
- `subscribe::Union{Bool,Nothing}`: Whether subscriptions are supported.
- `tools::Union{Dict{String,Any},Nothing}`: Tool definitions by name.
- `resources::Union{Vector{Dict{String,Any}},Nothing}`: Available resource listings.
"""
Base.@kwdef struct CapabilityResponse
    listChanged::Bool = false
    subscribe::Union{Bool,Nothing} = nothing
    tools::Union{Dict{String,Any},Nothing} = nothing
    resources::Union{Vector{Dict{String,Any}},Nothing} = nothing
end

"""
    capabilities_to_protocol(capabilities::Vector{Capability}, server::Server) -> Dict{String,Any}

Convert server capabilities to the initialization response format required by the MCP protocol.

# Arguments
- `capabilities::Vector{Capability}`: List of server capabilities.
- `server::Server`: The server containing tools and resources.

# Returns
- `Dict{String,Any}`: Protocol-formatted capabilities dictionary including available tools and resources.
"""
function capabilities_to_protocol(capabilities::Vector{Capability}, server::Server)::Dict{String,Any}
    result = LittleDict{String,Any}()
    
    # First add base capability flags
    for cap in capabilities
        if cap isa ResourceCapability
            result["resources"] = LittleDict{String,Any}(
                "listChanged" => cap.list_changed,
                "subscribe" => cap.subscribe
            )
        elseif cap isa ToolCapability
            result["tools"] = LittleDict{String,Any}(
                "listChanged" => cap.list_changed
            )
        elseif cap isa PromptCapability
            result["prompts"] = LittleDict{String,Any}(
                "listChanged" => cap.list_changed
            )
        elseif cap isa LoggingCapability
            result["logging"] = LittleDict{String,Any}()
        elseif cap isa TaskCapability
            tasks = to_protocol_format(cap)
            # Security guidance (spec): receivers that cannot identify requestors
            # should not offer tasks/list — on HTTP without auth, task metadata
            # would be exposed to any requestor. stdio is inherently single-user.
            if server.transport isa HttpTransport && server.transport.auth === nothing
                delete!(tasks, "list")
            end
            result["tasks"] = tasks
        end
    end
    
    # Note: Tools are NOT included in the initialization response per MCP spec
    # They should only be returned via the tools/list request

    # Add available resources array
    if haskey(result, "resources") && !isempty(server.resources)
        result["resources"]["resources"] = map(server.resources) do resource
            LittleDict{String,Any}(
                "uri" => string(resource.uri),
                "name" => resource.name,
                "mimeType" => resource.mime_type,
                "description" => resource.description
            )
        end
    end
    
    result
end

"""
    merge_capabilities(base::Vector{Capability}, override::Vector{Capability}) -> Vector{Capability}

Merge two sets of capabilities, with the override set taking precedence.

# Arguments
- `base::Vector{Capability}`: Base set of capabilities.
- `override::Vector{Capability}`: Override capabilities that take precedence.

# Returns
- `Vector{Capability}`: Merged set of capabilities.
"""
function merge_capabilities(base::Vector{Capability}, override::Vector{Capability})::Vector{Capability}
    result = copy(base)
    
    for cap in override
        # Find matching capability type
        idx = findfirst(x -> typeof(x) == typeof(cap), result)
        if isnothing(idx)
            push!(result, cap)
        else
            result[idx] = cap
        end
    end
    
    result
end

"""
    create_init_response(server::Server, protocol_version::String) -> InitializeResult

Create the initialization response for an MCP server.

# Arguments
- `server::Server`: The server to create the response for.
- `protocol_version::String`: MCP protocol version string.

# Returns
- `InitializeResult`: Initialization response including server capabilities and info.
"""
function create_init_response(server::Server, protocol_version::String)::InitializeResult
    InitializeResult(
        serverInfo = Dict(
            "name" => server.config.name,
            "version" => server.config.version
        ),
        capabilities = capabilities_to_protocol(server.config.capabilities, server),
        protocolVersion = protocol_version,
        instructions = server.config.instructions
    )
end
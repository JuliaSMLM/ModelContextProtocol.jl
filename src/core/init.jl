# src/core/init.jl

"""
    normalize_path(path::String) -> String

Convert paths to absolute form, resolving relative paths against the project root.

# Arguments
- `path::String`: The path to normalize

# Returns
- `String`: Absolute, normalized path with all symbolic links resolved
"""
function normalize_path(path::String)
    if isnothing(path)
        return nothing
    end
    
    # Convert to absolute path
    if !isabspath(path)
        # Relative paths should be relative to project root
        path = joinpath(dirname(dirname(@__DIR__)), path)
    end
    
    # Normalize the path (resolve .., ., and symlinks)
    return abspath(path)
end

"""
    scan_mcp_components(dir::String) -> Dict{Symbol,Vector}

Scan a directory recursively for MCP component definitions (tools, resources, prompts).

# Arguments
- `dir::String`: Directory path to scan for component definitions

# Returns
- `Dict{Symbol,Vector}`: Dictionary of found components grouped by type
"""
function scan_mcp_components(dir::String)
    components = Dict(
        :tools => MCPTool[],
        :resources => MCPResource[],
        :prompts => MCPPrompt[]
    )
    
    for (root, _, files) in walkdir(dir)
        for file in files
            endswith(file, ".jl") || continue
            
            path = joinpath(root, file)
            module_name = Symbol("TempModule_", hash(path))
            
            try
                # Create temporary module to evaluate file
                eval(Meta.parse("module $(module_name) using ModelContextProtocol; include(\"$path\") end"))
                
                # Extract components
                mod = getfield(Main, module_name)
                for name in names(mod, all=true)
                    obj = getfield(mod, name)
                    if obj isa MCPTool
                        push!(components[:tools], obj)
                    elseif obj isa MCPResource
                        push!(components[:resources], obj)
                    elseif obj isa MCPPrompt
                        push!(components[:prompts], obj)
                    end
                end
            catch e
                @warn "Error processing $path: $e"
            end
        end
    end
    return components
end

# src/core/server.jl

"""
    auto_register!(server::Server, dir::AbstractString) -> Server

Automatically register MCP components found in the specified directory structure.

# Arguments
- `server::Server`: The server to register components with
- `dir::AbstractString`: Root directory containing component subdirectories

# Directory Structure
- `dir/tools/`: Contains tool definition files
- `dir/resources/`: Contains resource definition files
- `dir/prompts/`: Contains prompt definition files

Each subdirectory is optional. Files should be .jl files containing component definitions.

# Component File Format
Component files must have the tool/resource/prompt as the **last expression** in the file.
The return value of `include()` is used to obtain the component.

Example:
```julia
# tools/my_tool.jl
julia_version_tool = MCPTool(
    name = "julia_version",
    description = "Get Julia version",
    handler = params -> Dict("version" => string(VERSION))
)  # ← This must be the last expression
```

# Returns
- `Server`: The updated server instance for method chaining
"""
function auto_register!(server::Server, dir::AbstractString)
    component_dirs = [
        ("tools", MCPTool),
        ("resources", MCPResource),
        ("prompts", MCPPrompt)
    ]
    
    for (subdir, type) in component_dirs
        component_dir = joinpath(dir, subdir)
        if isdir(component_dir)
            for file in readdir(component_dir, join=true)
                if endswith(file, ".jl")
                    try
                        # Create a new module with ModelContextProtocol already imported
                        mod = Module()
                        Core.eval(mod, :(using ModelContextProtocol))

                        # Include returns the last expression in the file
                        # Component files should have the tool/resource/prompt as the last expression
                        component = Base.include(mod, file)

                        # Register if it's the expected type
                        if component isa type
                            register!(server, component)
                            @info "Registered $type from $file"
                        else
                            @warn "File $file did not return a $type (got $(typeof(component)))"
                        end
                    catch e
                        @warn "Error processing $file" exception=e stack=stacktrace(catch_backtrace())
                    end
                end
            end
        end
    end
    
    return server
end


"""
    default_capabilities() -> Vector{Capability}

Create the default set of server capabilities for an MCP server.

# Returns
- `Vector{Capability}`: Default capabilities including resources, tools, and prompts
"""
function default_capabilities()
    [
        ResourceCapability(list_changed=true, subscribe=true),
        ToolCapability(list_changed=true),
        PromptCapability(list_changed=true)  # Added prompt capability
    ]
end

"""
    mcp_server(; name::String, version::String="1.0.0", 
             tools::Union{Vector{MCPTool},MCPTool,Nothing}=nothing,
             resources::Union{Vector{MCPResource},MCPResource,Nothing}=nothing, 
             prompts::Union{Vector{MCPPrompt},MCPPrompt,Nothing}=nothing,
             description::String="", 
             capabilities::Vector{Capability}=default_capabilities(),
             auto_register_dir::Union{String,Nothing}=nothing) -> Server

Primary entry point for creating and configuring a Model Context Protocol (MCP) server.

# Arguments
- `name::String`: Unique identifier for the server instance 
- `version::String`: Your server implementation version (defaults to "1.0.0") - YOUR server's version, not the MCP protocol version
- `tools`: Tools to expose to the model
- `resources`: Resources available to the model
- `prompts`: Predefined prompts for the model
- `description::String`: Optional server description
- `capabilities::Vector{Capability}`: Server capability configuration
- `auto_register_dir`: Directory to auto-register components from

# Returns
- `Server`: A configured server instance ready to handle MCP client connections

# Example
```julia
server = mcp_server(
    name = "my-server",
    version = "1.0.0",  # Your server version
    description = "Demo server with time tool",
    tools = MCPTool(
        name = "get_time",
        description = "Get current time",
        parameters = [],
        handler = args -> Dates.format(now(), "HH:MM:SS")
    )
)
start!(server)
```
"""
function mcp_server(;
    name::String,
    version::String = "1.0.0",  # Default server version for convenience 
    tools::Union{Vector{MCPTool}, MCPTool, Nothing} = nothing,
    resources::Union{Vector{MCPResource}, MCPResource, Nothing} = nothing,
    prompts::Union{Vector{MCPPrompt}, MCPPrompt, Nothing} = nothing,  # Added prompts parameter
    description::String = "",
    capabilities::Vector{Capability} = default_capabilities(),
    auto_register_dir::Union{String, Nothing} = nothing  # Added auto_register_dir parameter
)
    # Create server config
    config = ServerConfig(
        name = name,
        version = version,
        description = description,
        capabilities = capabilities
    )
    
    # Create server
    server = Server(config)
    
    # Register tools if provided
    if !isnothing(tools)
        foreach(t -> register!(server, t), tools isa Vector ? tools : [tools])
    end
    
    # Register resources if provided
    if !isnothing(resources)
        foreach(r -> register!(server, r), resources isa Vector ? resources : [resources])
    end
    
    # Register prompts if provided
    if !isnothing(prompts)
        foreach(p -> register!(server, p), prompts isa Vector ? prompts : [prompts])
    end
    
    # Auto-register components if directory provided
    if !isnothing(auto_register_dir)
        normalized_path = normalize_path(auto_register_dir)
        @info "Auto-registering components from $normalized_path"
        auto_register!(server, normalized_path)
    end
    
    return server
end
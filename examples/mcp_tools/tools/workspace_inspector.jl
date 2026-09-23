using JSON

"""
Get formatted information about variables in Main.storage
"""
function inspect_workspace()
    # Collect variable information from Main.storage
    vars = Dict{String, Any}()
    summary = Dict{String, Any}(
        "total_vars" => 0,
        "total_memory" => 0
    )

    for (name, var) in Main.storage
        # Get variable info
        var_size = try
            size(var)
        catch
            nothing
        end

        mem_size = try
            Base.summarysize(var)
        catch
            0
        end

        # Add to vars dict
        vars[string(name)] = Dict{String, Any}(
            "type" => string(typeof(var)),
            "size" => isnothing(var_size) ? nothing : collect(var_size),
            "memory_bytes" => mem_size
        )

        # Update summary
        summary["total_vars"] += 1
        summary["total_memory"] += mem_size
    end

    return Dict{String, Any}(
        "variables" => vars,
        "summary" => summary
    )
end

# Define the MCPTool
workspace_inspector_tool = MCPTool(
    name = "inspect_workspace",
    description = "Get information about variables in the Main.storage workspace.",
    parameters = [],
    handler = function(args)
        try
            result = inspect_workspace()
            # Return as TextContent but let the handler serialization handle the Dict
            return TextContent(
                type = "text",
                text = JSON.json(result)  # Need JSON for proper Dict serialization
            )
        catch e
            return TextContent(
                type = "text",
                text = JSON.json(Dict(
                    "error" => true,
                    "message" => "Error inspecting workspace: $e"
                ))
            )
        end
    end,
    return_type = TextContent
)

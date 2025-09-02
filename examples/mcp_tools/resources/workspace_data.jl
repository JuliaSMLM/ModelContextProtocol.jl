# Simple workspace data resource
using ModelContextProtocol
using URIs

workspace_resource = MCPResource(
    uri = URI("workspace://data/summary"),
    name = "Workspace Summary",
    description = "Returns summary of workspace data",
    mime_type = "application/json",
    data_provider = function()
        storage = isdefined(Main, :storage) ? Main.storage : Dict{String,Any}()
        return Dict(
            "storage_count" => length(storage),
            "storage_keys" => collect(keys(storage))
        )
    end
)
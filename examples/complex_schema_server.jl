#!/usr/bin/env julia

# Example MCP server demonstrating complex input_schema support
# Shows arrays, enums, nested objects, and other advanced JSON Schema features

using ModelContextProtocol

# Tool with array parameter (e.g., multiple tags)
tag_search_tool = MCPTool(
    name = "search_by_tags",
    description = "Search items by multiple tags",
    input_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "tags" => Dict{String,Any}(
                "type" => "array",
                "items" => Dict{String,Any}("type" => "string"),
                "description" => "List of tags to search for",
                "minItems" => 1
            ),
            "match_all" => Dict{String,Any}(
                "type" => "boolean",
                "description" => "If true, require all tags to match",
                "default" => false
            )
        ),
        "required" => ["tags"]
    ),
    handler = function(params)
        tags = get(params, "tags", String[])
        match_all = get(params, "match_all", false)
        mode = match_all ? "ALL" : "ANY"
        TextContent(text = "Searching for items with $mode of tags: $(join(tags, ", "))")
    end
)

# Tool with enum parameter (restricted values)
sort_tool = MCPTool(
    name = "sort_results",
    description = "Sort results by specified field and order",
    input_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "field" => Dict{String,Any}(
                "type" => "string",
                "enum" => ["name", "date", "relevance", "size"],
                "description" => "Field to sort by"
            ),
            "order" => Dict{String,Any}(
                "type" => "string",
                "enum" => ["asc", "desc"],
                "description" => "Sort order",
                "default" => "asc"
            )
        ),
        "required" => ["field"]
    ),
    handler = function(params)
        field = get(params, "field", "name")
        order = get(params, "order", "asc")
        TextContent(text = "Sorting by '$field' in $order order")
    end
)

# Tool with nested object parameter
filter_tool = MCPTool(
    name = "advanced_filter",
    description = "Filter data with complex criteria",
    input_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "query" => Dict{String,Any}(
                "type" => "string",
                "description" => "Search query"
            ),
            "filters" => Dict{String,Any}(
                "type" => "object",
                "description" => "Filter criteria",
                "properties" => Dict{String,Any}(
                    "date_range" => Dict{String,Any}(
                        "type" => "object",
                        "properties" => Dict{String,Any}(
                            "start" => Dict{String,Any}("type" => "string", "format" => "date"),
                            "end" => Dict{String,Any}("type" => "string", "format" => "date")
                        )
                    ),
                    "categories" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string")
                    ),
                    "min_score" => Dict{String,Any}(
                        "type" => "number",
                        "minimum" => 0,
                        "maximum" => 100
                    )
                )
            ),
            "options" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "limit" => Dict{String,Any}(
                        "type" => "integer",
                        "default" => 10,
                        "minimum" => 1,
                        "maximum" => 100
                    ),
                    "offset" => Dict{String,Any}(
                        "type" => "integer",
                        "default" => 0,
                        "minimum" => 0
                    ),
                    "include_metadata" => Dict{String,Any}(
                        "type" => "boolean",
                        "default" => true
                    )
                )
            )
        ),
        "required" => ["query"]
    ),
    handler = function(params)
        query = get(params, "query", "")
        filters = get(params, "filters", Dict())
        options = get(params, "options", Dict())

        limit = get(options, "limit", 10)
        offset = get(options, "offset", 0)

        result = """
        Advanced filter applied:
        - Query: "$query"
        - Filters: $(isempty(filters) ? "none" : string(filters))
        - Limit: $limit, Offset: $offset
        """
        TextContent(text = result)
    end
)

# Scientific example: localization fitting parameters
localization_tool = MCPTool(
    name = "fit_localizations",
    description = "Fit single molecule localizations with configurable model",
    input_schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "roi_data" => Dict{String,Any}(
                "type" => "array",
                "description" => "Array of ROI identifiers to process",
                "items" => Dict{String,Any}("type" => "integer")
            ),
            "model" => Dict{String,Any}(
                "type" => "string",
                "enum" => ["gaussian_2d", "gaussian_3d", "airy_2d", "spline"],
                "description" => "PSF model for fitting"
            ),
            "parameters" => Dict{String,Any}(
                "type" => "object",
                "description" => "Model-specific fitting parameters",
                "properties" => Dict{String,Any}(
                    "pixel_size" => Dict{String,Any}(
                        "type" => "number",
                        "description" => "Pixel size in nm",
                        "default" => 100.0
                    ),
                    "max_iterations" => Dict{String,Any}(
                        "type" => "integer",
                        "default" => 100,
                        "minimum" => 1
                    ),
                    "convergence_threshold" => Dict{String,Any}(
                        "type" => "number",
                        "default" => 1e-6
                    ),
                    "background_model" => Dict{String,Any}(
                        "type" => "string",
                        "enum" => ["constant", "linear", "none"],
                        "default" => "constant"
                    )
                )
            )
        ),
        "required" => ["roi_data", "model"]
    ),
    handler = function(params)
        rois = get(params, "roi_data", Int[])
        model = get(params, "model", "gaussian_2d")
        fit_params = get(params, "parameters", Dict())

        pixel_size = get(fit_params, "pixel_size", 100.0)
        bg_model = get(fit_params, "background_model", "constant")

        result = """
        Fitting $(length(rois)) ROIs:
        - Model: $model
        - Pixel size: $(pixel_size) nm
        - Background: $bg_model
        """
        TextContent(text = result)
    end
)

# Create and start server
server = mcp_server(
    name = "complex-schema-server",
    version = "1.0.0",
    description = "Demonstrates complex input_schema support for tools",
    tools = [tag_search_tool, sort_tool, filter_tool, localization_tool]
)

start!(server)

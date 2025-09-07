#!/usr/bin/env julia

# Example demonstrating a tool that returns multiple content items

using ModelContextProtocol
using JSON3

# Create a tool that returns mixed content types
analysis_tool = MCPTool(
    name = "analyze_data",
    description = "Analyze data and return both text summary and visualization",
    parameters = [
        ToolParameter(
            name = "data",
            type = "string", 
            description = "JSON data to analyze",
            required = true
        )
    ],
    handler = function (params)
        # Parse the input data
        data = JSON3.read(params["data"])
        
        # Create a text summary
        summary = TextContent(
            text = "Data Analysis Summary:\n- Total items: $(length(data))\n- Keys: $(join(keys(first(data)), ", "))"
        )
        
        # Create a mock chart (in real usage, this would be actual chart data)
        chart_data = Vector{UInt8}([0x89, 0x50, 0x4E, 0x47])  # PNG header
        chart = ImageContent(
            data = chart_data,
            mime_type = "image/png",
            annotations = Dict("title" => "Data Visualization")
        )
        
        # Return multiple content items
        return [summary, chart]
    end,
    return_type = Vector{Content}  # Specify we're returning a vector
)

# Create another tool that dynamically decides what to return
flexible_tool = MCPTool(
    name = "flexible_response",
    description = "Returns different content based on input",
    parameters = [
        ToolParameter(
            name = "format",
            type = "string",
            description = "Output format: 'text', 'image', 'both', or 'resource'",
            required = true
        )
    ],
    handler = function(params)
        format = params["format"]
        
        if format == "text"
            return TextContent(text = "This is a text response")
        elseif format == "image"
            return ImageContent(
                data = Vector{UInt8}([0xFF, 0xD8, 0xFF]),  # JPEG header
                mime_type = "image/jpeg"
            )
        elseif format == "both"
            return [
                TextContent(text = "Here's some text"),
                ImageContent(
                    data = Vector{UInt8}([0x47, 0x49, 0x46]),  # GIF header
                    mime_type = "image/gif"
                )
            ]
        elseif format == "resource"
            return [
                TextContent(text = "Resource data follows:"),
                EmbeddedResource(
                    resource = TextResourceContents(
                        uri = "data://example",
                        text = "Embedded resource content",
                        mime_type = "text/plain"
                    )
                )
            ]
        else
            return TextContent(text = "Unknown format requested")
        end
    end,
    return_type = Union{Content, Vector{Content}}  # Can return either
)

# Create server with the tools
server = mcp_server(
    name = "multi-content-server",
    version = "1.0.0", 
    description = "Server demonstrating multiple content returns",
    tools = [analysis_tool, flexible_tool]
)

# Start the server (stdio transport by default)
# Note: Don't print to stdout in stdio mode as it interferes with JSON-RPC communication
start!(server)
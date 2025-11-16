#!/usr/bin/env julia

# stdio MCP server example with time-related tools

using ModelContextProtocol
using Dates

# Define a tool that returns current time
time_tool = MCPTool(
    name = "current_time",
    description = "Get Current Date and Time",
    parameters = [],
    handler = params -> TextContent(text = "Current time: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
)

# Define a resource 
birthday_resource = MCPResource(
    uri = "character-info://harry-potter/birthday",
    name = "Harry Potter's Birthday",  
    description = "Returns Harry Potter's birthday",
    data_provider = () -> Dict("birthday" => "July 31")
)

# Define prompts
movie_info_prompt = MCPPrompt(
    name = "movie_analysis",
    description = "Get information about movies by genre",
    arguments = [
        PromptArgument(
            name = "genre",
            description = "Movie genre (e.g., science fiction, horror, drama)",
            required = true
        ),
        PromptArgument(
            name = "year",
            description = "Specific year to analyze (e.g., 1992)",
            required = false
        )
    ],
    messages = [
        PromptMessage(
            content = TextContent(
                type = "text",
                text = "What are some notable {genre} movies{?year? from {year}} that influenced the genre? Analyze their impact on filmmaking."
            )
        )
    ]
)

# Simple prompt without required arguments
greeting_prompt = MCPPrompt(
    name = "greeting",
    description = "Generate a friendly greeting",
    arguments = [],
    messages = [
        PromptMessage(
            content = TextContent(
                type = "text",
                text = "Generate a friendly and welcoming greeting message."
            )
        )
    ]
)

# Create and start server with all components
server = mcp_server(
    name = "time-movie-server",
    version = "1.0.0",  # Example server version
    description = "Time formatting and movie analysis service",
    tools = time_tool,
    resources = birthday_resource,
    prompts = [movie_info_prompt, greeting_prompt]
)

# Start the server
start!(server)
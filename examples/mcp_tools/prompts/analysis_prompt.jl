# Simple analysis prompt example
using ModelContextProtocol

analysis_prompt = MCPPrompt(
    name = "analyze_code",
    description = "Analyze Julia code for improvements",
    arguments = [
        PromptArgument(
            name = "code",
            description = "Julia code to analyze",
            required = true
        )
    ],
    messages = [
        PromptMessage(
            role = ModelContextProtocol.user,  # Use the Role enum
            content = TextContent(
                text = "Please analyze this Julia code and suggest improvements:\n\n{code}"
            )
        )
    ]
)
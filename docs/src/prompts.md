# MCP Prompts

Prompts are template-based messages that language models can use. Each prompt has a name, description, arguments, and message templates.

## Prompt Structure

Every prompt in ModelContextProtocol.jl is represented by the `MCPPrompt` struct:

- `name`: Unique identifier for the prompt
- `description`: Human-readable explanation of the prompt's purpose
- `arguments`: List of parameters the prompt accepts
- `messages`: Template messages with placeholders for arguments

## Creating Prompts

Here's how to create a basic prompt:

Note: The `role` field uses the `Role` enum with values `user` and `assistant`. You may need to import these:
```julia
import ModelContextProtocol: user, assistant
```

```julia
greeting_prompt = MCPPrompt(
    name = "greeting",
    description = "Personalized greeting message",
    arguments = [
        PromptArgument(
            name = "name",
            description = "User's name",
            required = true
        ),
        PromptArgument(
            name = "time_of_day",
            description = "Morning, afternoon, or evening",
            required = false
        )
    ],
    messages = [
        PromptMessage(
            role = user,
            content = TextContent(
                text = "Hello! {?time_of_day?Good {time_of_day}}! My name is {name}."
            )
        )
    ]
)
```

## Arguments

Prompt arguments are defined using the `PromptArgument` struct:

- `name`: Parameter identifier
- `description`: Explanation of the parameter
- `required`: Whether the argument must be provided (default: false)

## Template Syntax

Prompt templates support parameter substitution and conditional blocks:

- Basic substitution: `{parameter_name}`
- Conditional blocks: `{?parameter_name?content if parameter exists}`

## Registering Prompts

Prompts can be registered with a server in two ways:

1. During server creation:
```julia
server = mcp_server(
    name = "my-server",
    prompts = my_prompt  # Single prompt or vector of prompts
)
```

2. After server creation:
```julia
register!(server, my_prompt)
```

## Directory-Based Organization

Prompts can be organized in directory structures and auto-registered:

```
my_server/
└── prompts/
    ├── greeting.jl
    └── faq.jl
```

Each file should export one or more `MCPPrompt` instances:

```julia
# greeting.jl
using ModelContextProtocol

greeting_prompt = MCPPrompt(
    name = "greeting",
    description = "Personalized greeting message",
    arguments = [
        PromptArgument(name = "name", description = "User's name", required = true)
    ],
    messages = [
        PromptMessage(
            role = user,
            content = TextContent(text = "Hello! My name is {name}.")
        )
    ]
)
```

Then auto-register from the directory:

```julia
server = mcp_server(
    name = "my-server",
    auto_register_dir = "my_server"
)
```

## Advanced Examples

### Multi-Message Conversation Prompt

```julia
conversation_prompt = MCPPrompt(
    name = "code_review",
    description = "Code review conversation template",
    arguments = [
        PromptArgument(
            name = "language",
            description = "Programming language",
            required = true
        ),
        PromptArgument(
            name = "code",
            description = "Code to review",
            required = true
        ),
        PromptArgument(
            name = "focus_area",
            description = "Specific area to focus on",
            required = false
        )
    ],
    messages = [
        PromptMessage(
            role = user,
            content = TextContent(
                text = "Please review this {language} code:{?focus_area? Focus on {focus_area}.}"
            )
        ),
        PromptMessage(
            role = user,
            content = TextContent(text = "```{language}\n{code}\n```")
        ),
        PromptMessage(
            role = assistant,
            content = TextContent(
                text = "I'll analyze this {language} code{?focus_area? with focus on {focus_area}}."
            )
        )
    ]
)
```

### Prompt with Image Content

```julia
visual_prompt = MCPPrompt(
    name = "analyze_diagram",
    description = "Analyze a diagram or chart",
    arguments = [
        PromptArgument(name = "image_path", description = "Path to image", required = true),
        PromptArgument(name = "question", description = "Question about the image", required = false)
    ],
    messages = [
        PromptMessage(
            role = user,
            content = TextContent(
                text = "Please analyze this diagram{?question?: {question}}"
            )
        ),
        # Note: In practice, you'd load the actual image data
        PromptMessage(
            role = user,
            content = ImageContent(
                data = UInt8[],  # Placeholder for image bytes
                mime_type = "image/png"
            )
        )
    ]
)
```
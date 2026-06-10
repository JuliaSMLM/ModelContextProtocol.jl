# Documentation Guidelines for docs/

This directory contains the ModelContextProtocol.jl package documentation using Documenter.jl. Follow these conventions when creating or updating documentation.

## Directory Structure

```
docs/
├── Project.toml             # Documentation-specific dependencies
├── make.jl                  # Build configuration
├── src/                     # Markdown source files
│   ├── index.md             # Home page
│   ├── examples.md          # Worked examples
│   ├── tools.md             # User guide: tools
│   ├── resources.md         # User guide: resources
│   ├── prompts.md           # User guide: prompts
│   ├── transports.md        # User guide: transports
│   ├── auto-registration.md # User guide: auto-registration
│   ├── claude.md            # Integration: Claude Desktop
│   └── api.md               # API reference
└── build/                   # Generated documentation (gitignored)
```

## Setting Up Documentation

### docs/Project.toml
The documentation environment includes:
```toml
[deps]
Documenter = "e30172f5-a6a5-5a46-863b-614d45cd2de4"
ModelContextProtocol = "..."  # Package UUID
JSON3 = "..."  # For examples
HTTP = "..."   # For HTTP examples
```

### docs/make.jl Structure

Current configuration (see `docs/make.jl` for the authoritative version):
```julia
using Documenter
using ModelContextProtocol

# Set up doctests
DocMeta.setdocmeta!(ModelContextProtocol, :DocTestSetup,
    :(using ModelContextProtocol); recursive=true)

makedocs(;
    modules = [ModelContextProtocol],
    sitename = "ModelContextProtocol.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://JuliaSMLM.github.io/ModelContextProtocol.jl",
        size_threshold_ignore = ["api.md"],  # api.md aggregates every docstring
    ),
    pages = [
        "Home" => "index.md",
        "Examples" => "examples.md",
        "User Guide" => [
            "Tools" => "tools.md",
            "Resources" => "resources.md",
            "Prompts" => "prompts.md",
            "Transports" => "transports.md",
            "Auto-Registration" => "auto-registration.md",
        ],
        "Integration" => [
            "Claude Desktop" => "claude.md",
        ],
        "API Reference" => "api.md",
    ],
    doctest = true,
    linkcheck = true,
    warnonly = true,
    checkdocs = :exports,
)

# Deploy docs (from CI)
deploydocs(;
    repo = "github.com/JuliaSMLM/ModelContextProtocol.jl",
    devbranch = "main",
    push_preview = true,
)
```

## Creating Documentation Pages

### Home Page (index.md)
```markdown
# ModelContextProtocol.jl

Julia implementation of the Model Context Protocol (MCP) for seamless LLM-application integration.

## Features
- MCP 2025-11-25 protocol support with per-client version negotiation
- stdio and Streamable HTTP (+SSE) transports
- Tools, Resources, and Prompts
- Multi-content returns
- Session management

## Installation

```julia
using Pkg
Pkg.add("ModelContextProtocol")
```

## Quick Start

```julia
using ModelContextProtocol

# Create a simple MCP server with a tool
server = mcp_server(
    name = "my-server",
    version = "1.0.0",
    tools = MCPTool(
        name = "hello",
        description = "Say hello",
        parameters = [],
        handler = p -> TextContent(text = "Hello!")
    )
)

# Start server (stdio by default; blocks)
start!(server)
```
```

### User Guide (guide.md)

Structure for comprehensive guide:
```markdown
# User Guide

## Creating an MCP Server

### Basic Server Setup
```@example
using ModelContextProtocol

server = mcp_server(
    name = "example-server",
    version = "1.0.0"
)
```

### Adding Tools
Tools handle executable operations...

### Adding Resources
Resources provide data access...

### Adding Prompts
Prompts generate conversation starters...

## Transport Options

### stdio Transport (Default)
For integration with Claude Desktop and CLI tools...

### HTTP Transport
For web-based integrations...

## Testing Your Server

### With MCP Inspector
```bash
npx @modelcontextprotocol/inspector --cli julia server.jl --method tools/list
```

### With curl
```bash
curl -X POST http://127.0.0.1:3000/ ...
```
```

### Protocol Documentation (protocol.md)
```markdown
# MCP Protocol Details

## Protocol Version
ModelContextProtocol.jl targets MCP specification version `2025-11-25`, negotiating
per client down through `2025-06-18` and `2025-03-26` to `2024-11-05`.

## JSON-RPC 2.0
All communication uses JSON-RPC 2.0...

## Message Types
- Initialize
- Tools (list, call)
- Resources (list, read, subscribe)
- Prompts (list, get)

## Content Types
- TextContent
- ImageContent (base64)
- EmbeddedResource
- ResourceLink

## Transport Specifications
### stdio
Standard input/output communication...

### HTTP/SSE
Streamable HTTP with Server-Sent Events...
```

### API Reference (api.md)

For ModelContextProtocol.jl:
```markdown
# API Reference

## Public API

### Server Types
```@docs
ModelContextProtocol.Server
ModelContextProtocol.MCPTool
ModelContextProtocol.MCPResource
ModelContextProtocol.MCPPrompt
```

### Content Types
```@docs
ModelContextProtocol.TextContent
ModelContextProtocol.ImageContent
ModelContextProtocol.EmbeddedResource
ModelContextProtocol.ResourceLink
```

### Transport Types
```@docs
ModelContextProtocol.StdioTransport
ModelContextProtocol.HttpTransport
```

### Functions
```@docs
ModelContextProtocol.mcp_server
ModelContextProtocol.register!
ModelContextProtocol.start!
ModelContextProtocol.stop!
```

## Internal API

```@autodocs
Modules = [ModelContextProtocol]
Public = false
```
```

## Writing Documentation

### Code Examples

#### For MCP Servers:
```markdown
```@example server
using ModelContextProtocol

# Create server with components
server = mcp_server(
    name = "docs-example",
    version = "1.0.0",
    tools = MCPTool(
        name = "example",
        description = "Example tool",
        parameters = [],
        handler = p -> TextContent(text = "Example output")
    )
)

# Attach an HTTP transport (stdio is the default when none is set)
server.transport = HttpTransport(host="127.0.0.1", port=3000)

server  # Display server info
```
```

#### For Protocol Examples:
```markdown
```@example protocol
using ModelContextProtocol
using JSON3

# Show JSON-RPC message structure
request = Dict(
    "jsonrpc" => "2.0",
    "method" => "tools/list",
    "params" => Dict(),
    "id" => 1
)

JSON3.pretty(request)
```
```

### Doctests in Docstrings

Add verified examples to docstrings:
```julia
"""
    register!(server::Server, tool::MCPTool)

Add a tool to the MCP server.

# Examples
```jldoctest
julia> server = mcp_server(name="test", version="1.0.0");

julia> tool = MCPTool(name="test", description="demo", parameters=[],
                      handler=p->TextContent(text="ok"));

julia> register!(server, tool);

julia> length(server.tools)
1
```
"""
```

### Best Practices

1. **Examples**:
   - Use `@example` blocks for complex demonstrations
   - Name blocks to share state between examples
   - Hide setup code with `# hide` comments

2. **Cross-references**:
   - Link to types: `[`Server`](@ref ModelContextProtocol.Server)`
   - Link to functions: `[`register!`](@ref)`
   - Link to sections: `[User Guide](@ref)`

3. **Protocol Details**:
   - State the latest protocol version (`2025-11-25`) and that it is negotiated per client
   - Show JSON examples for protocol messages
   - Include curl commands for testing

4. **Code Style**:
   - Use single backticks for inline code: `Server`
   - Use triple backticks for code blocks
   - Specify language for syntax highlighting

## Building Documentation

### Local Build
```bash
cd docs
julia --project=. make.jl
```

Documentation will be in `docs/build/`.

### Local Development with Live Reload
```julia
using LiveServer
cd("docs")
servedocs()  # Opens browser with live reload
```

### CI Integration
Documentation builds and deploys via GitHub Actions:
- Builds on PRs (without deployment)
- Deploys to gh-pages when merging to main

## Common Documentation Tasks

### Adding a New Example
1. Create example in `docs/src/examples/`
2. Add to pages in `make.jl`
3. Test locally with `servedocs()`

### Updating API Docs
1. Update docstrings in source code
2. Rebuild docs to verify rendering
3. Check cross-references work

### Adding Protocol Updates
1. Update `protocol.md` with new features
2. Add examples showing new protocol usage
3. Update version information if needed

## Troubleshooting

- **Missing docstrings**: Add docstrings or set `checkdocs = :none`
- **Broken doctests**: Update examples or use `doctest = false`
- **Build failures**: Check docs/Project.toml dependencies
- **Cross-references not working**: Ensure proper `@ref` syntax
- **Examples not running**: Verify all required packages in docs/Project.toml

## Documentation Standards

### For MCP-Specific Docs
- Specify the latest protocol version (`2025-11-25`) and the negotiation floor (`2024-11-05`)
- Include both stdio and HTTP examples
- Show Inspector CLI and curl testing methods
- Document session management for HTTP
- Explain Accept header requirements

### Style Guidelines
- Use present tense for descriptions
- Keep examples practical and runnable
- Include error handling in examples
- Link to example files in `examples/`
- Provide troubleshooting sections
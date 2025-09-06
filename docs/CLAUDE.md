# Documentation Guidelines for docs/

This directory contains the ModelContextProtocol.jl package documentation using Documenter.jl. Follow these conventions when creating or updating documentation.

## Directory Structure

```
docs/
├── Project.toml      # Documentation-specific dependencies
├── make.jl          # Build configuration
├── src/             # Markdown source files
│   ├── index.md     # Home page
│   ├── api.md       # API reference
│   ├── guide.md     # User guide
│   └── protocol.md  # MCP protocol details
└── build/           # Generated documentation (gitignored)
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

Current configuration:
```julia
using Documenter
using ModelContextProtocol

# Set up doctests
DocMeta.setdocmeta!(ModelContextProtocol, :DocTestSetup, 
    :(using ModelContextProtocol); recursive=true)

makedocs(
    sitename = "ModelContextProtocol.jl",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://juliasmlm.github.io/ModelContextProtocol.jl/stable/",
    ),
    modules = [ModelContextProtocol],
    pages = [
        "Home" => "index.md",
        "User Guide" => "guide.md",
        "Protocol" => "protocol.md",
        "API Reference" => "api.md",
    ],
)

# Deploy docs (from CI)
deploydocs(
    repo = "github.com/JuliaSMLM/ModelContextProtocol.jl.git",
    devbranch = "main",
)
```

## Creating Documentation Pages

### Home Page (index.md)
```markdown
# ModelContextProtocol.jl

Julia implementation of the Model Context Protocol (MCP) for seamless LLM-application integration.

## Features
- Full MCP 2025-06-18 protocol support
- stdio and HTTP/SSE transports
- Tools, Resources, and Prompts
- Multi-content returns
- Session management

## Installation

```julia
using Pkg
Pkg.add("ModelContextProtocol")
```

## Quick Start

```@example
using ModelContextProtocol

# Create a simple MCP server
server = Server("my-server", "1.0.0")

# Add a tool
add_tool!(server, MCPTool(
    name = "hello",
    handler = p -> TextContent(text = "Hello!")
))

# Start server (stdio by default)
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

server = Server(
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
ModelContextProtocol.jl implements MCP specification version `2025-06-18`.

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
ModelContextProtocol.add_tool!
ModelContextProtocol.add_resource!
ModelContextProtocol.add_prompt!
ModelContextProtocol.start!
ModelContextProtocol.register_directory!
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

# Create server with HTTP transport
transport = HttpTransport(host="127.0.0.1", port=3000)
server = Server("docs-example", "1.0.0", transport=transport)

# Add components
add_tool!(server, MCPTool(
    name = "example",
    handler = p -> TextContent(text = "Example output")
))

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
    add_tool!(server::Server, tool::MCPTool)

Add a tool to the MCP server.

# Examples
```jldoctest
julia> server = Server("test", "1.0.0");

julia> tool = MCPTool(name="test", handler=p->TextContent(text="ok"));

julia> add_tool!(server, tool);

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
   - Link to functions: `[`add_tool!`](@ref)`
   - Link to sections: `[User Guide](@ref)`

3. **Protocol Details**:
   - Always mention protocol version `2025-06-18`
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
- Always specify protocol version `2025-06-18`
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
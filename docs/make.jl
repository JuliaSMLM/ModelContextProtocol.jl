using Documenter
using ModelContextProtocol

# Set up DocMeta for all files
DocMeta.setdocmeta!(ModelContextProtocol, :DocTestSetup, :(using ModelContextProtocol); recursive=true)

makedocs(
    modules = [ModelContextProtocol],
    authors = "JuliaSMLM Team",
    repo = "https://github.com/JuliaSMLM/ModelContextProtocol.jl/blob/{commit}{path}#{line}",
    sitename = "ModelContextProtocol.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://JuliaSMLM.github.io/ModelContextProtocol.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Tools" => "tools.md",
        "Resources" => "resources.md",
        "Prompts" => "prompts.md",
        "Transports" => "transports.md",
        "Claude Integration" => "claude.md",
        "API Reference" => "api.md"
    ],
    doctest = true,
    linkcheck = true,
    warnonly = true
)

deploydocs(;
    repo = "github.com/JuliaSMLM/ModelContextProtocol.jl",
    devbranch = "main",
    push_preview = true
)
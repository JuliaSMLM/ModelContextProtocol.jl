using Test

# Cross-language MCP integration: a real external Python process (the official `mcp`
# SDK) drives a local Julia MCP server over stdio. The Python client is
# `mcp_client_check.py`; the server is `integration_server.jl`. This wrapper spawns the
# client as a subprocess and asserts a clean exit. No PythonCall / CondaPkg — the only
# requirement is a `python3` on PATH with the `mcp` package importable, so the suite
# auto-skips (loudly) rather than silently passing when that prerequisite is missing.

@testset "Python-SDK cross-language integration" begin
    py = let p = Sys.which("python3")
        (p !== nothing && success(`$p -c "import mcp"`)) ? p : nothing
    end

    if py === nothing
        @info "Skipping Python-SDK integration: no python3 with the `mcp` package " *
              "(install: pip install -r requirements.txt)"
        @test_skip "python3 + mcp required"
    else
        client = joinpath(@__DIR__, "mcp_client_check.py")
        server = joinpath(@__DIR__, "integration_server.jl")
        julia_exe = Base.julia_cmd().exec[1]
        # The Python client spawns the Julia server itself (via StdioServerParameters),
        # so we hand it the julia command + the server script.
        proc = run(pipeline(ignorestatus(`$py $client $julia_exe $server`);
                            stdout = stdout, stderr = stderr))
        @test proc.exitcode == 0
    end
end

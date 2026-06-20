using Test

# External cross-language integration tests. These spawn real subprocesses (a Julia MCP
# server and, for the Python suite, an external `python3` running the official `mcp`
# SDK), so they live outside the package's unit suite (`Pkg.test()`). Each included file
# gates itself and skips cleanly when its prerequisites are absent.
@testset "External Integration Tests" begin
    include("test_basic_stdio.jl")     # Julia-only stdio smoke test
    include("test_python_client.jl")   # Python `mcp` SDK <-> Julia server (auto-skips without python3+mcp)
end

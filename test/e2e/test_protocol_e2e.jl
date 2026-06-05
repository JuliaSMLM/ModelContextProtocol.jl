# test/e2e/test_protocol_e2e.jl
#
# End-to-end protocol tests. Unlike the in-process transport tests, these spawn
# the SHIPPED example servers as real OS subprocesses and drive the MCP
# `initialize` handshake exactly as an external client would (stdio pipe / HTTP).
# This catches process-level and example-level regressions that in-process tests
# structurally cannot — e.g. an example server hardcoding a protocol version.
#
# Gated by `RUN_E2E` in runtests.jl: runs locally by default, skipped on CI
# (each spawned server pays full JIT startup). Force either way with the
# MCP_TEST_E2E environment variable. No `using` here by convention — runtests.jl
# provides Test, ModelContextProtocol, JSON3, and HTTP.

const _E2E_REPO  = pkgdir(ModelContextProtocol)
const _E2E_JULIA = Base.julia_cmd()

# Build an initialize request for a client claiming protocol version `v`.
_e2e_init(v) = string(
    """{"jsonrpc":"2.0","method":"initialize",""",
    """"params":{"protocolVersion":"$(v)","capabilities":{},""",
    """"clientInfo":{"name":"e2e","version":"1.0"}},"id":1}""",
)

# (client-requested version => version the server must negotiate to in the response body)
const _E2E_CASES = [
    "2025-11-25" => "2025-11-25",             # latest, echoed back
    "2025-06-18" => "2025-06-18",             # supported older, echoed (backward compat)
    "1999-01-01" => LATEST_PROTOCOL_VERSION,  # unknown -> fall back to latest
]

# True if something is already serving HTTP at `url` (so we can spawn / skip cleanly).
function _e2e_http_alive(url)
    try
        HTTP.get(url; status_exception=false, retry=false, connect_timeout=1, readtimeout=2)
        return true
    catch
        return false
    end
end

@testset "E2E protocol (real subprocesses)" begin

    @testset "stdio negotiation — examples/time_server.jl" begin
        script = joinpath(_E2E_REPO, "examples", "time_server.jl")
        @test isfile(script)
        for (requested, expected) in _E2E_CASES
            out = read(pipeline(`$(_E2E_JULIA) --project=$(_E2E_REPO) $(script)`;
                                stdin = IOBuffer(_e2e_init(requested) * "\n"),
                                stderr = devnull), String)
            resp = nothing
            for line in split(out, '\n')
                if occursin("\"protocolVersion\"", line)
                    resp = JSON3.read(line)
                    break
                end
            end
            @test resp !== nothing
            if resp !== nothing
                @test resp.result.protocolVersion == expected
            end
        end
    end

    @testset "Streamable HTTP negotiation — examples/simple_http_server.jl" begin
        port = 3000
        url  = "http://127.0.0.1:$(port)/"
        if _e2e_http_alive(url)
            @warn "Port $(port) is already serving HTTP; skipping HTTP e2e test"
        else
            script = joinpath(_E2E_REPO, "examples", "simple_http_server.jl")
            @test isfile(script)
            proc = run(pipeline(`$(_E2E_JULIA) --project=$(_E2E_REPO) $(script)`;
                                stdout = devnull, stderr = devnull); wait = false)
            try
                ready = false
                for _ in 1:90
                    if _e2e_http_alive(url)
                        ready = true
                        break
                    end
                    sleep(1)
                end
                @test ready
                if ready
                    # Health check (plain GET) reports a version we actually support
                    health = JSON3.read(String(HTTP.get(url; status_exception=false).body))
                    @test String(health.protocol_version) in SUPPORTED_PROTOCOL_VERSIONS

                    hdrs = ["Content-Type" => "application/json",
                            "Accept" => "application/json, text/event-stream"]
                    session = ""
                    for (requested, expected) in _E2E_CASES
                        r = HTTP.post(url, hdrs, _e2e_init(requested); status_exception=false)
                        @test r.status == 200
                        @test JSON3.read(String(r.body)).result.protocolVersion == expected
                        if isempty(session)
                            session = HTTP.header(r, "Mcp-Session-Id", "")
                        end
                    end

                    # Sanity: the server actually serves tools end-to-end over the wire
                    lhdrs = isempty(session) ? hdrs : vcat(hdrs, ["Mcp-Session-Id" => session])
                    tools = JSON3.read(String(HTTP.post(url, lhdrs,
                        """{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}""";
                        status_exception=false).body))
                    @test haskey(tools.result, :tools)
                end
            finally
                kill(proc)
                try
                    wait(proc)
                catch
                end
            end
        end
    end

end

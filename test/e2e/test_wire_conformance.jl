# test/e2e/test_wire_conformance.jl
#
# Wire-format conformance against a REAL server subprocess (the fixture in
# fixtures/wire_demo_server.jl), over both transports. In-process handler tests
# can't see what a client actually receives — serialized bodies and HTTP
# headers — so spec-shape regressions (e.g. ResourceLink once emitting
# non-spec {"type":"link","href":...}, or prompts/get leaking raw struct
# fields) only show up here. Gated by RUN_E2E like the other e2e tests; no
# `using` here by convention (runtests.jl provides Test, ModelContextProtocol,
# JSON3, HTTP, Base64).

const _WIRE_FIXTURE = joinpath(_E2E_REPO, "test", "e2e", "fixtures", "wire_demo_server.jl")

const _WIRE_REQUESTS = [
    """{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"wire-e2e","version":"1.0"}},"id":1}""",
    """{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}""",
    """{"jsonrpc":"2.0","method":"tools/call","params":{"name":"analyze_image","arguments":{"dataset":"run42"}},"id":3}""",
    """{"jsonrpc":"2.0","method":"tools/call","params":{"name":"get_stats","arguments":{}},"id":4}""",
    """{"jsonrpc":"2.0","method":"prompts/get","params":{"name":"media_demo"},"id":5}""",
    """{"jsonrpc":"2.0","method":"resources/list","params":{},"id":6}""",
]

# Shared assertions on the six responses (Dict id => parsed JSON3 object),
# used by both the stdio and HTTP passes.
function _wire_assert(resp)
    # 1: initialize — negotiated version + serverInfo.description
    @test resp[1].result.protocolVersion == "2025-06-18"
    @test resp[1].result.serverInfo.description == "Wire conformance demo server"

    # 2: tools/list — generated schema declares 2020-12; _meta and outputSchema emitted
    tools = Dict(String(t.name) => t for t in resp[2].result.tools)
    @test tools["analyze_image"].inputSchema["\$schema"] == "https://json-schema.org/draft/2020-12/schema"
    @test tools["analyze_image"]._meta["lab/origin"] == "wire-demo"
    @test tools["get_stats"].outputSchema["type"] == "object"

    # 3: multi-content call — spec audio + resource_link shapes
    content = resp[3].result.content
    @test [String(c.type) for c in content] == ["text", "audio", "resource_link"]
    @test content[2].mimeType == "audio/wav"
    @test content[2].data == base64encode(UInt8[0x52, 0x49, 0x46, 0x46])
    @test content[3].uri == "file:///results/run42/overlay.png"
    @test content[3].name == "overlay.png"
    @test content[3].size == 123456
    @test !haskey(content[3], :href)             # the old non-spec key
    @test resp[3].result.isError == false        # spec key, not is_error
    @test !haskey(resp[3].result, :is_error)

    # 4: structured output — structuredContent + result _meta
    @test resp[4].result.structuredContent.count == 42
    @test resp[4].result._meta.trace == "abc123"

    # 5: prompts/get — works WITHOUT arguments; media in spec wire format
    msgs = resp[5].result.messages
    @test [String(m.role) for m in msgs] == ["user", "user", "user", "user"]
    @test [String(m.content.type) for m in msgs] == ["text", "image", "audio", "resource_link"]
    for m in msgs
        @test !haskey(m.content, :mime_type)     # no raw Julia field names on the wire
    end
    @test msgs[3].content.mimeType == "audio/wav"
    @test msgs[3].content.data == base64encode(UInt8[0x52, 0x49, 0x46, 0x46])
    @test msgs[4].content.uri == "file:///d/raw.tif"

    # 6: resources/list — _meta emitted
    @test resp[6].result.resources[1]._meta["lab/resource"] == 1
end

@testset "E2E wire conformance (real subprocesses)" begin

    @testset "stdio" begin
        @test isfile(_WIRE_FIXTURE)
        out = read(pipeline(`$(_E2E_JULIA) --project=$(_E2E_REPO) $(_WIRE_FIXTURE)`;
                            stdin = IOBuffer(join(_WIRE_REQUESTS, "\n") * "\n"),
                            stderr = devnull), String)
        resp = Dict{Int,Any}()
        for line in split(out, '\n')
            startswith(line, "{") || continue
            msg = JSON3.read(line)
            haskey(msg, :id) && (resp[msg.id] = msg)
        end
        @test length(resp) == 6
        length(resp) == 6 && _wire_assert(resp)
    end

    @testset "stdio logging/setLevel takes effect live" begin
        # setLevel "debug" must actually enable the request-lifecycle @debug lines on a
        # REAL server (the global-logger LogState caches min_enabled_level at install
        # time — an in-process field mutation can pass unit tests while doing nothing
        # live, which is exactly what happened the first time)
        reqs = [
            """{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"lvl","version":"1"}},"id":1}""",
            """{"jsonrpc":"2.0","method":"logging/setLevel","params":{"level":"debug"},"id":2}""",
            """{"jsonrpc":"2.0","method":"ping","id":3}""",
            """{"jsonrpc":"2.0","method":"logging/setLevel","params":{"level":"bogus"},"id":4}""",
        ]
        errbuf = IOBuffer()
        out = read(pipeline(`$(_E2E_JULIA) --project=$(_E2E_REPO) $(_WIRE_FIXTURE)`;
                            stdin = IOBuffer(join(reqs, "\n") * "\n"),
                            stderr = errbuf), String)
        resp = Dict{Int,Any}()
        for line in split(out, '\n')
            startswith(line, "{") || continue
            msg = JSON3.read(line)
            haskey(msg, :id) && (resp[msg.id] = msg)
        end
        @test haskey(resp[2], :result)                       # setLevel accepted
        @test resp[4].error.code == -32602                   # invalid level rejected
        stderr_text = String(take!(errbuf))
        @test occursin("request completed", stderr_text)     # lifecycle lines now flowing
        @test occursin("notifications/message", stderr_text) # in MCP log format
    end

    @testset "Streamable HTTP" begin
        port = 8772
        url = "http://127.0.0.1:$(port)/"
        if _e2e_http_alive(url)
            @warn "Port $(port) is already serving HTTP; skipping HTTP wire-conformance test"
        else
            proc = run(pipeline(addenv(`$(_E2E_JULIA) --project=$(_E2E_REPO) $(_WIRE_FIXTURE) http`,
                                       "DEMO_PORT" => string(port));
                                stdout = devnull, stderr = devnull); wait = false)
            try
                ready = false
                for _ in 1:90
                    _e2e_http_alive(url) && (ready = true; break)
                    sleep(1)
                end
                @test ready
                if ready
                    hdrs = ["Content-Type" => "application/json",
                            "Accept" => "application/json, text/event-stream"]
                    resp = Dict{Int,Any}()
                    session = ""
                    versions = String[]
                    for req in _WIRE_REQUESTS
                        h = isempty(session) ? hdrs : vcat(hdrs, ["Mcp-Session-Id" => session])
                        r = HTTP.post(url, h, req; status_exception = false)
                        @test r.status == 200
                        push!(versions, HTTP.header(r, "MCP-Protocol-Version", ""))
                        isempty(session) && (session = HTTP.header(r, "Mcp-Session-Id", ""))
                        msg = JSON3.read(String(r.body))
                        haskey(msg, :id) && (resp[msg.id] = msg)
                    end
                    # The response HEADER echoes the NEGOTIATED version on every
                    # response (client asked 2025-06-18; transport default is latest)
                    @test all(==("2025-06-18"), versions)
                    @test length(resp) == 6
                    length(resp) == 6 && _wire_assert(resp)
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

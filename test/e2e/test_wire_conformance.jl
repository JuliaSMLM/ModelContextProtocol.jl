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
    """{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"demo://logo"},"id":7}""",
    """{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"demo://readme"},"id":8}""",
    """{"jsonrpc":"2.0","method":"resources/templates/list","params":{},"id":9}""",
    """{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"demo://artifact/ab12"},"id":10}""",
]

# Shared assertions on the ten responses (Dict id => parsed JSON3 object),
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
    # this session negotiated 2025-06-18, so tasks metadata must be withheld
    @test !haskey(tools["count_slow"], :execution)
    @test !haskey(resp[1].result.capabilities, :tasks)

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

    # 7: binary resource served as base64 blob contents (BlobResourceContents return)
    blob_c = resp[7].result.contents[1]
    @test blob_c.uri == "demo://logo"
    @test blob_c.blob == base64encode(UInt8[0x89, 0x50, 0x4E, 0x47])
    @test blob_c.mimeType == "image/png"
    @test !haskey(blob_c, :text)

    # 8: String provider data is the text verbatim (not JSON-quoted)
    @test resp[8].result.contents[1].text == "plain, not JSON-quoted"
    @test resp[8].result.contents[1].mimeType == "text/plain"

    # 9: resources/templates/list — spec wire keys
    t = only(resp[9].result.resourceTemplates)
    @test t.uriTemplate == "demo://artifact/{id}"
    @test t.name == "artifact"
    @test t.mimeType == "image/png"

    # 10: templated read — provider received the uri + extracted {id}
    art = resp[10].result.contents[1]
    @test art.uri == "demo://artifact/ab12"
    @test art.blob == base64encode(vcat(UInt8[0x89, 0x50, 0x4E, 0x47], Vector{UInt8}("ab12")))
    @test art.mimeType == "image/png"
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
        @test length(resp) == 10
        length(resp) == 10 && _wire_assert(resp)
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
                    @test length(resp) == 10
                    length(resp) == 10 && _wire_assert(resp)
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

    # MCP Tasks (SEP-1686, experimental). The task flow is inherently interactive —
    # the taskId comes from the create response — so it can't ride the static
    # request list above. stdio pass drives the fixture through pipes; the response
    # to a blocking tasks/result arrives out-of-loop, interleaved with the optional
    # status notifications, so frames are read until the awaited id shows up.
    @testset "tasks over stdio (interactive)" begin
        proc = open(pipeline(`$(_E2E_JULIA) --project=$(_E2E_REPO) $(_WIRE_FIXTURE)`;
                             stderr = devnull), "r+")
        notes = Any[]
        function _task_rpc(req, id)
            write(proc, req * "\n")
            Base.flush(proc)  # Base-qualified: the package exports flush(::Transport)
            while true
                line = readline(proc)
                startswith(line, "{") || continue
                msg = JSON3.read(line)
                haskey(msg, :id) && msg.id == id && return msg
                push!(notes, msg)
            end
        end
        try
            init = _task_rpc("""{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tasks-e2e","version":"1.0"}},"id":1}""", 1)
            tasks_cap = init.result.capabilities.tasks
            @test haskey(tasks_cap.requests.tools, :call)
            @test haskey(tasks_cap, :list)               # stdio is single-user: list offered
            @test haskey(tasks_cap, :cancel)

            list = _task_rpc("""{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}""", 2)
            tools = Dict(String(t.name) => t for t in list.result.tools)
            @test tools["count_slow"].execution.taskSupport == "optional"

            create = _task_rpc("""{"jsonrpc":"2.0","method":"tools/call","params":{"name":"count_slow","arguments":{},"task":{"ttl":120000}},"id":3}""", 3)
            task = create.result.task
            @test task.status == "working"
            @test task.ttl == 120000
            @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", String(task.createdAt))
            @test haskey(task, :pollInterval)
            @test !haskey(create.result, :content)       # CreateTaskResult carries no tool output
            tid = String(task.taskId)

            # blocks until the task completes, then returns exactly the CallToolResult
            res = _task_rpc("""{"jsonrpc":"2.0","method":"tasks/result","params":{"taskId":"$tid"},"id":4}""", 4)
            @test res.result.content[1].text == "counted"
            @test res.result.isError == false
            @test res.result._meta["io.modelcontextprotocol/related-task"]["taskId"] == tid

            got = _task_rpc("""{"jsonrpc":"2.0","method":"tasks/get","params":{"taskId":"$tid"},"id":5}""", 5)
            @test got.result.taskId == tid               # Task flattened into the result
            @test got.result.status == "completed"

            lst = _task_rpc("""{"jsonrpc":"2.0","method":"tasks/list","params":{},"id":6}""", 6)
            @test any(t -> t.taskId == tid, lst.result.tasks)

            # cancellation: the status notification is written before the response
            create2 = _task_rpc("""{"jsonrpc":"2.0","method":"tools/call","params":{"name":"count_slow","arguments":{},"task":{}},"id":7}""", 7)
            tid2 = String(create2.result.task.taskId)
            cancel = _task_rpc("""{"jsonrpc":"2.0","method":"tasks/cancel","params":{"taskId":"$tid2"},"id":8}""", 8)
            @test cancel.result.status == "cancelled"
            @test any(n -> haskey(n, :method) && n.method == "notifications/tasks/status" &&
                           n.params.taskId == tid2 && n.params.status == "cancelled", notes)

            again = _task_rpc("""{"jsonrpc":"2.0","method":"tasks/cancel","params":{"taskId":"$tid2"},"id":9}""", 9)
            @test again.error.code == -32602
        finally
            kill(proc)
            try
                wait(proc)
            catch
            end
        end
    end

    @testset "tasks over Streamable HTTP" begin
        port = 8773
        url = "http://127.0.0.1:$(port)/"
        if _e2e_http_alive(url)
            @warn "Port $(port) is already serving HTTP; skipping HTTP tasks e2e test"
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
                    session = ""
                    function post(req)
                        h = isempty(session) ? hdrs : vcat(hdrs, ["Mcp-Session-Id" => session])
                        r = HTTP.post(url, h, req; status_exception = false)
                        @test r.status == 200
                        isempty(session) && (session = HTTP.header(r, "Mcp-Session-Id", ""))
                        (JSON3.read(String(r.body)), HTTP.header(r, "MCP-Protocol-Version", ""))
                    end

                    init, ver = post("""{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tasks-e2e","version":"1.0"}},"id":1}""")
                    @test ver == "2025-11-25"
                    tasks_cap = init.result.capabilities.tasks
                    @test haskey(tasks_cap.requests.tools, :call)
                    # unauthenticated HTTP cannot identify requestors: list withheld
                    @test !haskey(tasks_cap, :list)
                    @test haskey(tasks_cap, :cancel)

                    create, _ = post("""{"jsonrpc":"2.0","method":"tools/call","params":{"name":"count_slow","arguments":{},"task":{"ttl":120000}},"id":2}""")
                    @test create.result.task.status == "working"
                    tid = String(create.result.task.taskId)

                    # the POST stays open until the task turns terminal (blocking semantics)
                    res, _ = post("""{"jsonrpc":"2.0","method":"tasks/result","params":{"taskId":"$tid"},"id":3}""")
                    @test res.result.content[1].text == "counted"
                    @test res.result._meta["io.modelcontextprotocol/related-task"]["taskId"] == tid

                    got, _ = post("""{"jsonrpc":"2.0","method":"tasks/get","params":{"taskId":"$tid"},"id":4}""")
                    @test got.result.status == "completed"

                    # tasks/list is not offered on unauthenticated HTTP
                    lst, _ = post("""{"jsonrpc":"2.0","method":"tasks/list","params":{},"id":5}""")
                    @test lst.error.code == -32601
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

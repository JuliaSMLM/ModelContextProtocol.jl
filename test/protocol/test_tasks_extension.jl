# test/protocol/test_tasks_extension.jl
#
# The MCP Tasks extension (io.modelcontextprotocol/tasks, SEP-2663): server-directed
# task creation from modern-era tools/call via task_detach(ctx), the tasks/get /
# tasks/update / tasks/cancel surface, capability gating (-32021), wire-field shapes
# (ttlMs / pollIntervalMs), and era isolation against the legacy SEP-1686 tasks.
# In-process over a StdioTransport whose output is an IOBuffer (the detached call's
# responses are delivered out-of-loop and land there).
# No `using` here by convention — runtests.jl provides the imports.

# Wait until f() is true, with a generous timeout for slow CI machines.
function _ext_wait_for(f; timeout=15.0, interval=0.05)
    deadline = time() + timeout
    while time() < deadline
        f() && return true
        sleep(interval)
    end
    f()
end

const _EXT_CAPS = Dict{String,Any}(
    "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))

_ext_meta(; caps=_EXT_CAPS) = Dict{String,Any}(
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => caps,
)

function _ext_test_server(; tools=MCPTool[])
    server = mcp_server(name="tasks-ext-test", version="0.0.1", tools=tools)
    buf = IOBuffer()
    server.transport = StdioTransport(input=IOBuffer(), output=buf)
    (server, ServerState(), buf)
end

# One request/response round-trip; nothing when the call deferred its response.
function _ext_rpc(server, state, msg)
    r = process_message(server, state, JSON3.write(msg))
    task_local_storage(:mcp_suppress_log_notifications, false)
    r === nothing ? nothing : JSON3.read(r)
end

# Drain JSON lines delivered out-of-loop (deferred responses).
_ext_oob(buf::IOBuffer) = [JSON3.read(l) for l in split(String(take!(buf)), '\n') if startswith(l, "{")]

# Deliver a deferred tools/call and wait for its out-of-loop response by id.
function _ext_deferred_response(buf, id)
    lines = []
    _ext_wait_for(() -> (append!(lines, _ext_oob(buf)); any(m -> get(m, "id", nothing) == id, lines)))
    first(m for m in lines if get(m, "id", nothing) == id)
end

_ext_call(server, state, name; caps=_EXT_CAPS, id=1, extra=Dict{String,Any}()) =
    _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => id, "method" => "tools/call",
        "params" => merge(Dict{String,Any}("name" => name, "arguments" => Dict{String,Any}(),
                                           "_meta" => _ext_meta(caps=caps)), extra)))
_ext_get(server, state, tid; caps=_EXT_CAPS, id=90) =
    _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => id, "method" => "tasks/get",
        "params" => Dict("taskId" => tid, "_meta" => _ext_meta(caps=caps))))
_ext_cancel(server, state, tid; caps=_EXT_CAPS, id=91) =
    _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => id, "method" => "tasks/cancel",
        "params" => Dict("taskId" => tid, "_meta" => _ext_meta(caps=caps))))
_ext_update(server, state, tid; caps=_EXT_CAPS, id=92, responses=Dict{String,Any}()) =
    _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => id, "method" => "tasks/update",
        "params" => Dict("taskId" => tid, "inputResponses" => responses,
                         "_meta" => _ext_meta(caps=caps))))

_ext_tools() = [
    MCPTool(name="slow", description="d", parameters=[], task_support=:optional,
        handler=(args, ctx) -> begin
            task_detach(ctx)
            for _ in 1:100
                task_cancelled(ctx) && return TextContent(text="aborted")
                sleep(0.05)
            end
            TextContent(text="slow done")
        end),
    MCPTool(name="fast", description="d", parameters=[], task_support=:optional,
        handler=(args, ctx) -> (task_detach(ctx); TextContent(text="fast done"))),
    MCPTool(name="failing", description="d", parameters=[], task_support=:required,
        handler=(args, ctx) -> (task_detach(ctx);
            CallToolResult(content=[Dict{String,Any}("type" => "text", "text" => "tool error")],
                           is_error=true))),
    MCPTool(name="boom", description="d", parameters=[], task_support=:optional,
        handler=(args, ctx) -> (task_detach(ctx); error("kapow"))),
    MCPTool(name="shortcut", description="d", parameters=[], task_support=:optional,
        handler=(args, ctx) -> TextContent(text="sync anyway")),  # never detaches
    MCPTool(name="asker", description="d", parameters=[], task_support=:optional,
        handler=(args, ctx) -> begin
            r = input_responses(ctx)
            haskey(r, "who") || return InputRequired(Dict("who" => elicit_request("Who?")))
            task_detach(ctx)
            TextContent(text="hello $(r["who"])")
        end),
    MCPTool(name="plain", description="d", parameters=[],
        handler=args -> TextContent(text="plain done")),
]

@testset "Tasks extension (SEP-2663)" begin

    @testset "store: era tagging and ext finish semantics" begin
        store = TaskStore()
        legacy = create_task!(store, "tools/call")
        ext = create_task!(store, "tools/call"; era=:ext)
        @test legacy.era === :legacy && ext.era === :ext

        # get_task filters by era both ways (indistinguishable from not-found)
        @test get_task(store, ext.task_id, nothing; era=:ext) === ext
        @test get_task(store, ext.task_id, nothing) === nothing
        @test get_task(store, legacy.task_id, nothing; era=:ext) === nothing

        # ext era: an isError tool result COMPLETES the task ("failed" is reserved
        # for JSON-RPC errors); legacy keeps its is_error -> failed mapping
        bad = CallToolResult(content=Dict{String,Any}[], is_error=true)
        @test finish_task!(store, ext, bad)
        @test ext.status == "completed"
        @test finish_task!(store, legacy, bad)
        @test legacy.status == "failed"

        # ext wire shape: ttlMs/pollIntervalMs, never the legacy keys
        w = lock(store.lock) do
            ModelContextProtocol.ext_task_wire(ext; detailed=true)
        end
        @test w["ttlMs"] == store.default_ttl_ms && w["pollIntervalMs"] == store.poll_interval_ms
        @test !haskey(w, "ttl") && !haskey(w, "pollInterval")
        @test w["result"]["isError"] == true
        @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", w["createdAt"])
    end

    @testset "detached lifecycle: create, poll, cancel" begin
        server, state, buf = _ext_test_server(tools=_ext_tools())

        @test _ext_call(server, state, "slow"; id=11) === nothing  # deferred
        create = _ext_deferred_response(buf, 11)
        result = create["result"]
        @test result["resultType"] == "task"
        @test result["status"] == "working"
        @test !haskey(result, "task")  # flat CreateTaskResult, no nested wrapper
        @test result["ttlMs"] isa Integer && result["pollIntervalMs"] isa Integer
        @test !haskey(result, "ttl") && !haskey(result, "pollInterval")
        @test !haskey(result, "requestState")
        tid = result["taskId"]

        # Strong consistency: the task resolves the moment the client sees it
        g = _ext_get(server, state, tid)
        @test g["result"]["resultType"] == "complete"
        @test g["result"]["status"] == "working"
        @test !haskey(g["result"], "result") && !haskey(g["result"], "error")
        @test !haskey(g["result"], "requestState")

        # Cancel: empty ack (no task envelope), cooperative settle to cancelled
        c = _ext_cancel(server, state, tid)
        @test c["result"]["resultType"] == "complete"
        @test !haskey(c["result"], "taskId") && !haskey(c["result"], "status")
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "cancelled")

        # Terminal cancel is idempotent (-32602 is reserved for unknown ids)
        c2 = _ext_cancel(server, state, tid)
        @test haskey(c2, "result") && c2["result"]["resultType"] == "complete"

        # A discarded outcome never overwrites the cancelled status
        sleep(0.2)
        @test _ext_get(server, state, tid)["result"]["status"] == "cancelled"
    end

    @testset "terminal results inlined on tasks/get" begin
        server, state, buf = _ext_test_server(tools=_ext_tools())

        # completed: result inlined, no resultType inside the nested result
        _ext_call(server, state, "fast"; id=21)
        tid = _ext_deferred_response(buf, 21)["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "completed")
        g = _ext_get(server, state, tid)
        @test g["result"]["result"]["content"][1]["text"] == "fast done"
        @test g["result"]["result"]["isError"] == false
        @test !haskey(g["result"]["result"], "resultType")
        @test !haskey(g["result"]["result"], "_meta")  # no legacy related-task _meta
        @test !haskey(g["result"], "error")

        # tool-level isError -> completed with the result inlined (SEP-2663 delta)
        _ext_call(server, state, "failing"; id=22)
        tid2 = _ext_deferred_response(buf, 22)["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid2)["result"]["status"] == "completed")
        g2 = _ext_get(server, state, tid2)
        @test g2["result"]["result"]["isError"] == true

        # thrown error -> failed with the JSON-RPC error inlined, no result
        _ext_call(server, state, "boom"; id=23)
        tid3 = _ext_deferred_response(buf, 23)["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid3)["result"]["status"] == "failed")
        g3 = _ext_get(server, state, tid3)
        @test g3["result"]["error"]["code"] == -32603
        @test occursin("kapow", g3["result"]["error"]["message"])
        @test !haskey(g3["result"], "result")
    end

    @testset "immediate-result shortcut and sync fall-through" begin
        server, state, buf = _ext_test_server(tools=_ext_tools())

        # Task-capable + declared, but the handler never detaches: ordinary sync
        # result delivered on the captured route (resultType complete, no taskId)
        @test _ext_call(server, state, "shortcut"; id=31) === nothing
        resp = _ext_deferred_response(buf, 31)
        @test resp["result"]["resultType"] == "complete"
        @test resp["result"]["content"][1]["text"] == "sync anyway"
        @test !haskey(resp["result"], "taskId")

        # Without the extension declared, :optional tools run inline and
        # task_detach is a no-op returning false
        sync = _ext_call(server, state, "fast"; caps=Dict{String,Any}(), id=32)
        @test sync !== nothing
        @test sync["result"]["resultType"] == "complete"
        @test sync["result"]["content"][1]["text"] == "fast done"
        @test !haskey(sync["result"], "taskId")

        # The legacy `task` request param neither errors nor promotes
        lp = _ext_call(server, state, "plain"; caps=Dict{String,Any}(), id=33,
                       extra=Dict{String,Any}("task" => Dict{String,Any}("ttl" => 1000)))
        @test lp["result"]["resultType"] == "complete" && !haskey(lp["result"], "taskId")
    end

    @testset "capability gating (-32021)" begin
        server, state, buf = _ext_test_server(tools=_ext_tools())
        nocaps = Dict{String,Any}()

        for resp in (
            _ext_get(server, state, "gate-probe"; caps=nocaps),
            _ext_update(server, state, "gate-probe"; caps=nocaps),
            _ext_cancel(server, state, "gate-probe"; caps=nocaps),
        )
            @test resp["error"]["code"] == -32021
            @test haskey(resp["error"]["data"]["requiredCapabilities"]["extensions"],
                         "io.modelcontextprotocol/tasks")
        end

        # :required tool without the declaration: rejected BEFORE the handler runs
        rr = _ext_call(server, state, "failing"; caps=nocaps, id=41)
        @test rr["error"]["code"] == -32021
        @test haskey(rr["error"]["data"]["requiredCapabilities"]["extensions"],
                     "io.modelcontextprotocol/tasks")

        # Declaration must be an OBJECT value: null/scalar declares nothing
        for bogus in (nothing, true, "yes")
            caps = Dict{String,Any}("extensions" =>
                Dict{String,Any}("io.modelcontextprotocol/tasks" => bogus))
            resp = _ext_get(server, state, "gate-probe"; caps=caps)
            @test resp["error"]["code"] == -32021
        end
    end

    @testset "tasks/update surface and errors" begin
        server, state, buf = _ext_test_server(tools=_ext_tools())
        _ext_call(server, state, "slow"; id=51)
        tid = _ext_deferred_response(buf, 51)["result"]["taskId"]

        # Known task: not-outstanding keys are ignored, empty ack returned
        u = _ext_update(server, state, tid; responses=Dict{String,Any}("stale" => Dict{String,Any}()))
        @test u["result"]["resultType"] == "complete"
        @test !haskey(u["result"], "taskId") && !haskey(u["result"], "status")

        # Unknown ids are -32602 on all three methods
        @test _ext_get(server, state, "nope")["error"]["code"] == -32602
        @test _ext_update(server, state, "nope")["error"]["code"] == -32602
        @test _ext_cancel(server, state, "nope")["error"]["code"] == -32602

        # Missing/mistyped inputResponses fails typed parsing -> -32602
        bad = _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 52,
            "method" => "tasks/update",
            "params" => Dict("taskId" => tid, "_meta" => _ext_meta())))
        @test bad["error"]["code"] == -32602

        _ext_cancel(server, state, tid)
    end

    @testset "removed legacy methods stay -32601" begin
        server, state, _ = _ext_test_server(tools=_ext_tools())
        for method in ("tasks/result", "tasks/list")
            resp = _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 61,
                "method" => method,
                "params" => Dict("taskId" => "x", "_meta" => _ext_meta())))
            @test resp["error"]["code"] == -32601
        end
    end

    @testset "MRTR composition: input round before task creation" begin
        server, state, buf = _ext_test_server(tools=_ext_tools())
        elicit_caps = Dict{String,Any}(
            "elicitation" => Dict{String,Any}(),
            "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))

        # Round 1: InputRequired without detaching -> the MRTR envelope, delivered
        # off-loop, carrying NO taskId (the task is only minted on the final round)
        @test _ext_call(server, state, "asker"; caps=elicit_caps, id=71) === nothing
        r1 = _ext_deferred_response(buf, 71)
        @test r1["result"]["resultType"] == "input_required"
        @test haskey(r1["result"]["inputRequests"], "who")
        @test haskey(r1["result"], "requestState")
        @test !haskey(r1["result"], "taskId")

        # Round 2: retry with the response; the handler detaches -> CreateTaskResult
        # whose eventual result reflects the MRTR-gathered input, end-to-end
        @test _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 72,
            "method" => "tools/call",
            "params" => Dict("name" => "asker", "arguments" => Dict{String,Any}(),
                             "inputResponses" => Dict("who" => Dict("action" => "accept",
                                                                    "content" => Dict("input" => "Luca"))),
                             "requestState" => r1["result"]["requestState"],
                             "_meta" => _ext_meta(caps=elicit_caps)))) === nothing
        r2 = _ext_deferred_response(buf, 72)
        @test r2["result"]["resultType"] == "task"
        @test !haskey(r2["result"], "requestState")  # MRTR state never leaks into the task envelope
        tid = r2["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid; caps=elicit_caps)["result"]["status"] == "completed")
        g = _ext_get(server, state, tid; caps=elicit_caps)
        @test occursin("Luca", g["result"]["result"]["content"][1]["text"])

        # The off-loop MRTR path enforces capabilities like the in-loop one: the
        # tasks extension alone does not declare elicitation -> -32021 naming it
        @test _ext_call(server, state, "asker"; id=73) === nothing
        r3 = _ext_deferred_response(buf, 73)
        @test r3["error"]["code"] == -32021
        @test haskey(r3["error"]["data"]["requiredCapabilities"], "elicitation")
    end

    @testset "era isolation across the task surface" begin
        server, state, buf = _ext_test_server(tools=_ext_tools())
        _ext_call(server, state, "fast"; id=81)
        ext_tid = _ext_deferred_response(buf, 81)["result"]["taskId"]

        # A legacy session cannot see the extension task
        lstate = ServerState()
        _ext_rpc(server, lstate, Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
            "params" => Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict(),
                             "clientInfo" => Dict("name" => "l", "version" => "1"))))
        lresp = _ext_rpc(server, lstate, Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tasks/get",
            "params" => Dict("taskId" => ext_tid)))
        @test lresp["error"]["code"] == -32602

        # And a legacy-created task is invisible to the extension surface
        legacy_record = create_task!(server.tasks, "tools/call")
        eresp = _ext_get(server, state, legacy_record.task_id)
        @test eresp["error"]["code"] == -32602
    end

    @testset "discover advertises the extension" begin
        server, state, _ = _ext_test_server()
        resp = _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 1,
            "method" => "server/discover", "params" => Dict("_meta" => _ext_meta())))
        caps = resp["result"]["capabilities"]
        @test haskey(caps["extensions"], "io.modelcontextprotocol/tasks")
        @test !haskey(caps, "tasks")
    end

    @testset "Mcp-Name routing header mirrors taskId (SEP-2243)" begin
        body = """{"jsonrpc":"2.0","id":1,"method":"tasks/get","params":{"taskId":"abc-123","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"""
        msg = JSON3.read(body)
        mk(headers) = HTTP.Request("POST", "/", headers, body)
        ok_headers = ["MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tasks/get",
                      "Mcp-Name" => "abc-123"]
        @test ModelContextProtocol.modern_header_violation(mk(ok_headers), msg, "2026-07-28") === nothing
        mismatch = ["MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tasks/get",
                    "Mcp-Name" => "other-task"]
        @test ModelContextProtocol.modern_header_violation(mk(mismatch), msg, "2026-07-28") !== nothing
        missing_name = ["MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tasks/get"]
        @test ModelContextProtocol.modern_header_violation(mk(missing_name), msg, "2026-07-28") !== nothing
    end
end

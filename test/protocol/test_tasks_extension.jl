# test/protocol/test_tasks_extension.jl
#
# The MCP Tasks extension (io.modelcontextprotocol/tasks, SEP-2663): server-directed
# task creation from modern-era tools/call via task_detach(ctx), the tasks/get /
# tasks/update / tasks/cancel surface, capability gating (-32021), wire-field shapes
# (ttlMs / pollIntervalMs), and era isolation against the legacy SEP-1686 tasks.
# In-process over a StdioTransport whose output is an IOBuffer (the detached call's
# responses are delivered out-of-loop and land there).
# No `using` here by convention — runtests.jl provides the imports.

# An exception whose own display throws: the worst case for error paths that
# interpolate the exception into a message.
struct _ExtUglyException <: Exception end
Base.show(::IO, ::_ExtUglyException) = throw(_ExtUglyException())

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

    @testset "deferred response survives build failures (Codex r1 B1)" begin
        # A non-detaching handler whose MRTR envelope cannot be built (the
        # requestState cannot encode a Function) must still answer -32603, exactly
        # like the in-loop path — never silence
        bad_state = MCPTool(name="bad_state", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> InputRequired(
                Dict("k" => elicit_request("q")); state=identity))
        server, state, buf = _ext_test_server(tools=[bad_state])
        caps = Dict{String,Any}(
            "elicitation" => Dict{String,Any}(),
            "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))
        @test _ext_call(server, state, "bad_state"; caps=caps, id=101) === nothing
        resp = _ext_deferred_response(buf, 101)
        @test haskey(resp, "error") && resp["error"]["code"] == -32603
    end

    @testset "principal binding: provider + per-request scopes (Codex r1 B2)" begin
        server, _, _ = _ext_test_server(tools=_ext_tools())
        store = server.tasks
        caps = _EXT_CAPS
        user(scopes; provider="prov", subject="alice") =
            AuthenticatedUser(subject=subject, provider=provider, scopes=scopes)
        actx(u) = RequestContext(server=server, request_id=1,
                                 authenticated_user=u, protocol_version="2026-07-28",
                                 client_capabilities=caps)

        # task_detach stamps the provider-qualified principal and the tool scopes
        dctx = actx(user(["mcp:admin"]))
        dctx.detach = ModelContextProtocol.TaskDetachState(server.transport, nothing, ["mcp:admin"])
        @test task_detach(dctx)
        rec = dctx.task
        @test rec.era === :ext
        @test rec.principal == "[\"prov\",\"alice\"]"  # canonical [provider, subject] identity
        @test rec.required_scopes == ["mcp:admin"]

        # Same subject, insufficient scopes -> indistinguishable from not-found
        g = ModelContextProtocol.handle_ext_get_task(actx(user(["mcp:read"])),
            ModelContextProtocol.GetTaskParams(taskId=rec.task_id))
        @test g.error !== nothing && g.error.code == -32602

        # Same subject, wrong provider -> not-found (principal mismatch)
        g2 = ModelContextProtocol.handle_ext_get_task(actx(user(["mcp:admin"]; provider="other")),
            ModelContextProtocol.GetTaskParams(taskId=rec.task_id))
        @test g2.error !== nothing && g2.error.code == -32602

        # Full scopes from the right provider -> authorized
        g3 = ModelContextProtocol.handle_ext_get_task(actx(user(["mcp:admin", "mcp:read"])),
            ModelContextProtocol.GetTaskParams(taskId=rec.task_id))
        @test g3.error === nothing

        # cancel/update enforce the same recheck
        c = ModelContextProtocol.handle_ext_cancel_task(actx(user(["mcp:read"])),
            ModelContextProtocol.CancelTaskParams(taskId=rec.task_id))
        @test c.error !== nothing && c.error.code == -32602
        u = ModelContextProtocol.handle_ext_update_task(actx(user(["mcp:read"])),
            ModelContextProtocol.UpdateTaskParams(taskId=rec.task_id,
                                                  inputResponses=Dict{String,Any}()))
        @test u.error !== nothing && u.error.code == -32602
        cancel_task!(store, rec)
    end

    @testset "principal identity is collision-free end-to-end (Codex r2 B2)" begin
        # Delimiter-style concatenation would collide these two identities; the
        # canonical JSON [provider, subject] encoding cannot
        a = AuthenticatedUser(subject="b\x1fc", provider="a")
        b = AuthenticatedUser(subject="c", provider="a\x1fb")
        @test ModelContextProtocol.principal_identity(a) != ModelContextProtocol.principal_identity(b)

        server, _, _ = _ext_test_server()
        actx(u) = RequestContext(server=server, request_id=1, authenticated_user=u,
                                 protocol_version="2026-07-28", client_capabilities=_EXT_CAPS)
        rec = create_task!(server.tasks, "tools/call"; era=:ext,
                           principal=ModelContextProtocol.principal_identity(a))
        cross = ModelContextProtocol.handle_ext_get_task(actx(b),
            ModelContextProtocol.GetTaskParams(taskId=rec.task_id))
        @test cross.error !== nothing && cross.error.code == -32602
        own = ModelContextProtocol.handle_ext_get_task(actx(a),
            ModelContextProtocol.GetTaskParams(taskId=rec.task_id))
        @test own.error === nothing

        # An MRTR requestState issued to one provider's principal must not verify
        # for a same-subject token from ANOTHER provider (the composition flow
        # would otherwise inherit the first principal's handler state)
        prov_a = AuthenticatedUser(subject="sub", provider="A")
        prov_b = AuthenticatedUser(subject="sub", provider="B")
        token = ModelContextProtocol.issue_request_state(server, "tools/call", "digest",
            ModelContextProtocol.mrtr_principal(prov_a), Dict("k" => 1))
        ok_a, _ = ModelContextProtocol.verify_request_state(server, token, "tools/call",
            "digest", ModelContextProtocol.mrtr_principal(prov_a))
        ok_b, _ = ModelContextProtocol.verify_request_state(server, token, "tools/call",
            "digest", ModelContextProtocol.mrtr_principal(prov_b))
        @test ok_a
        @test !ok_b
        cancel_task!(server.tasks, rec)
    end

    @testset "required_scopes are snapshotted, never aliased (Codex r2 B3)" begin
        server, _, _ = _ext_test_server()
        live = ["mcp:admin"]
        ctx = RequestContext(server=server, request_id=1,
                             protocol_version="2026-07-28", client_capabilities=_EXT_CAPS,
                             detach=ModelContextProtocol.TaskDetachState(server.transport, nothing, live))
        @test task_detach(ctx)
        rec = ctx.task
        empty!(live)  # a later registry mutation must not rewrite the task's requirement
        @test rec.required_scopes == ["mcp:admin"]
        cancel_task!(server.tasks, rec)
    end

    @testset "display-throwing exceptions cannot orphan a task (Codex r4 B1)" begin
        ugly = MCPTool(name="ugly", description="d", parameters=[], task_support=:optional,
            handler=(args, ctx) -> (task_detach(ctx); throw(_ExtUglyException())))
        server, state, buf = _ext_test_server(tools=[ugly])
        @test _ext_call(server, state, "ugly"; id=131) === nothing
        tid = _ext_deferred_response(buf, 131)["result"]["taskId"]
        # The exception's show throws through every message interpolation; the
        # task must still terminalize as failed instead of polling forever
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "failed")
        g = _ext_get(server, state, tid)
        @test occursin("_ExtUglyException", g["result"]["error"]["message"])
    end

    @testset "task record published before fallible delivery (Codex r3 B1)" begin
        server, _, _ = _ext_test_server()
        dead = IOBuffer()
        # Base.close, QUALIFIED: a bare `close` here would resolve Main's binding to
        # Base's before transports/test_stdio.jl imports ModelContextProtocol.close,
        # and Julia 1.11 then ignores that import (MethodError on close(transport))
        Base.close(dead)  # every write throws: CreateTaskResult delivery cannot succeed
        broken = StdioTransport(input=IOBuffer(), output=dead)
        ctx = RequestContext(server=server, request_id=1,
                             protocol_version="2026-07-28", client_capabilities=_EXT_CAPS,
                             detach=ModelContextProtocol.TaskDetachState(broken, nothing))
        @test task_detach(ctx)  # delivery failure is swallowed; the detach holds
        rec = ctx.task
        @test rec !== nothing && rec.status == "working"
        @test ctx.detach.record === rec  # published for the wrapper to terminalize
        @test ctx.detach.create_delivered  # delivery attempted -> no response owed
        @test get_task(server.tasks, rec.task_id, nothing; era=:ext) === rec
        cancel_task!(server.tasks, rec)
    end

    @testset "legacy tasks/list never exposes ext records (Codex r1 B3)" begin
        store = TaskStore()
        legacy = create_task!(store, "tools/call")
        ext = create_task!(store, "tools/call"; era=:ext)
        page, _ = ModelContextProtocol.list_tasks(store, nothing, nothing)
        @test any(r -> r.task_id == legacy.task_id, page)
        @test !any(r -> r.task_id == ext.task_id, page)
        epage, _ = ModelContextProtocol.list_tasks(store, nothing, nothing; era=:ext)
        @test any(r -> r.task_id == ext.task_id, epage)
    end

    @testset "transportless servers run task-capable tools synchronously (Codex r1 W4)" begin
        server = mcp_server(name="no-transport", version="0.0.1", tools=_ext_tools())
        @test server.transport === nothing
        state = ServerState()
        resp = _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 111,
            "method" => "tools/call",
            "params" => Dict{String,Any}("name" => "fast", "arguments" => Dict{String,Any}(),
                                         "_meta" => _ext_meta())))
        @test resp !== nothing
        @test resp["result"]["resultType"] == "complete"
        @test resp["result"]["content"][1]["text"] == "fast done"
        @test !haskey(resp["result"], "taskId")
    end

    @testset "send_progress is a no-op on detachable calls (Codex r1 W6)" begin
        server, _, _ = _ext_test_server()
        ctx = RequestContext(server=server, request_id=1, progress_token="tok",
                             detach=ModelContextProtocol.TaskDetachState(server.transport, nothing))
        @test send_progress(ctx, 0.5) == false
    end

    @testset "gating precedes params validation (Codex r1 W7a)" begin
        server, state, _ = _ext_test_server(tools=_ext_tools())
        # Malformed params (no taskId) from a NON-declaring client: the extension's
        # -32021 takes precedence over -32602 params validation
        for method in ("tasks/get", "tasks/update", "tasks/cancel")
            resp = _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 121,
                "method" => method,
                "params" => Dict("_meta" => _ext_meta(caps=Dict{String,Any}()))))
            @test resp["error"]["code"] == -32021
        end
        # Declared but malformed still gets -32602
        resp = _ext_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 122,
            "method" => "tasks/get", "params" => Dict("_meta" => _ext_meta())))
        @test resp["error"]["code"] == -32602
    end

    @testset "legacy tasks/update stays -32601 (Codex r1 W7b)" begin
        server, _, _ = _ext_test_server()
        lstate = ServerState()
        _ext_rpc(server, lstate, Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
            "params" => Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict(),
                             "clientInfo" => Dict("name" => "l", "version" => "1"))))
        # Empty params: the required-field params type has no zero-arg constructor,
        # which must not abort parsing into -32603
        for params in (Dict{String,Any}(),
                       Dict{String,Any}("taskId" => "x", "inputResponses" => Dict{String,Any}()))
            resp = _ext_rpc(server, lstate, Dict("jsonrpc" => "2.0", "id" => 2,
                "method" => "tasks/update", "params" => params))
            @test resp["error"]["code"] == -32601
        end
    end

    @testset "mid-task input: park, snapshot, resume" begin
        confirmer = MCPTool(name="confirmer", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> begin
                task_detach(ctx)
                resp = task_await_input(ctx, elicit_request("Proceed?"))
                TextContent(text="confirmed: $(JSON3.write(resp))")
            end)
        server, state, buf = _ext_test_server(tools=[confirmer])
        elicit_caps = Dict{String,Any}(
            "elicitation" => Dict{String,Any}(),
            "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))

        @test _ext_call(server, state, "confirmer"; caps=elicit_caps, id=201) === nothing
        tid = _ext_deferred_response(buf, 201)["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "input_required")

        # tasks/get inlines the outstanding request under a server-minted key
        g = _ext_get(server, state, tid)
        @test g["result"]["resultType"] == "complete"
        reqs = g["result"]["inputRequests"]
        @test length(reqs) == 1
        key = first(keys(reqs))
        @test reqs[key]["method"] == "elicitation/create"
        @test reqs[key]["params"]["message"] == "Proceed?"

        # The snapshot is re-included on every poll until answered
        @test haskey(_ext_get(server, state, tid)["result"]["inputRequests"], key)

        # Not-outstanding keys are ignored: acked, task still parked, key intact
        u0 = _ext_update(server, state, tid; responses=Dict{String,Any}(
            "never-issued" => Dict{String,Any}("x" => 1)))
        @test u0["result"]["resultType"] == "complete"
        g2 = _ext_get(server, state, tid)
        @test g2["result"]["status"] == "input_required"
        @test haskey(g2["result"]["inputRequests"], key)

        # The real response resumes the handler; the ack carries no task envelope
        u = _ext_update(server, state, tid; responses=Dict{String,Any}(
            String(key) => Dict{String,Any}("action" => "accept",
                                            "content" => Dict{String,Any}("ok" => "magic-42"))))
        @test u["result"]["resultType"] == "complete"
        @test !haskey(u["result"], "taskId") && !haskey(u["result"], "status") &&
              !haskey(u["result"], "inputRequests")
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "completed")
        done = _ext_get(server, state, tid)
        @test occursin("magic-42", done["result"]["result"]["content"][1]["text"])
        @test !haskey(done["result"], "inputRequests")
    end

    @testset "mid-task input: partial fulfillment and key uniqueness" begin
        fanout = MCPTool(name="fanout", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> begin
                task_detach(ctx)
                rs = task_await_input(ctx, [elicit_request("First?"), elicit_request("Second?")])
                TextContent(text="fanout: $(JSON3.write(rs))")
            end)
        tworounds = MCPTool(name="tworounds", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> begin
                task_detach(ctx)
                a = task_await_input(ctx, elicit_request("Round 1?"))
                b = task_await_input(ctx, elicit_request("Round 2?"))
                TextContent(text="rounds: $(JSON3.write(Any[a, b]))")
            end)
        server, state, buf = _ext_test_server(tools=[fanout, tworounds])
        elicit_caps = Dict{String,Any}(
            "elicitation" => Dict{String,Any}(),
            "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))

        # Two parallel requests park the task with two pending keys
        @test _ext_call(server, state, "fanout"; caps=elicit_caps, id=211) === nothing
        tid = _ext_deferred_response(buf, 211)["result"]["taskId"]
        @test _ext_wait_for(() -> length(get(_ext_get(server, state, tid)["result"],
                                             "inputRequests", Dict())) == 2)
        keys2 = collect(keys(_ext_get(server, state, tid)["result"]["inputRequests"]))
        k1, k2 = String(keys2[1]), String(keys2[2])

        # Subset update: acked, answered key removed, still input_required
        _ext_update(server, state, tid; responses=Dict{String,Any}(
            k1 => Dict{String,Any}("content" => Dict{String,Any}("v" => "first-answer"))))
        after = _ext_get(server, state, tid)["result"]
        @test after["status"] == "input_required"
        @test !haskey(after["inputRequests"], k1)
        @test haskey(after["inputRequests"], k2)

        # Completing the set resumes the handler; responses arrive in request order
        _ext_update(server, state, tid; responses=Dict{String,Any}(
            k2 => Dict{String,Any}("content" => Dict{String,Any}("v" => "second-answer"))))
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "completed")
        text = _ext_get(server, state, tid)["result"]["result"]["content"][1]["text"]
        @test occursin(r"first-answer.*second-answer"s, text)

        # Sequential rounds mint fresh keys: a key is never reused after answering
        @test _ext_call(server, state, "tworounds"; caps=elicit_caps, id=221) === nothing
        tid2 = _ext_deferred_response(buf, 221)["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid2)["result"]["status"] == "input_required")
        r1key = String(first(keys(_ext_get(server, state, tid2)["result"]["inputRequests"])))
        _ext_update(server, state, tid2; responses=Dict{String,Any}(
            r1key => Dict{String,Any}("content" => Dict{String,Any}("v" => 1))))
        @test _ext_wait_for(() -> begin
            r = _ext_get(server, state, tid2)["result"]
            r["status"] == "input_required" && !haskey(get(r, "inputRequests", Dict()), r1key)
        end)
        r2key = String(first(keys(_ext_get(server, state, tid2)["result"]["inputRequests"])))
        @test r2key != r1key
        _ext_update(server, state, tid2; responses=Dict{String,Any}(
            r2key => Dict{String,Any}("content" => Dict{String,Any}("v" => 2))))
        @test _ext_wait_for(() -> _ext_get(server, state, tid2)["result"]["status"] == "completed")
    end

    @testset "mid-task input: cancel unblocks the waiter" begin
        confirmer = MCPTool(name="confirmer", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> begin
                task_detach(ctx)
                task_await_input(ctx, elicit_request("Proceed?"))
                TextContent(text="never delivered")
            end)
        server, state, buf = _ext_test_server(tools=[confirmer])
        elicit_caps = Dict{String,Any}(
            "elicitation" => Dict{String,Any}(),
            "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))

        @test _ext_call(server, state, "confirmer"; caps=elicit_caps, id=231) === nothing
        tid = _ext_deferred_response(buf, 231)["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "input_required")
        pending_key = String(first(keys(_ext_get(server, state, tid)["result"]["inputRequests"])))

        c = _ext_cancel(server, state, tid)
        @test c["result"]["resultType"] == "complete"
        @test _ext_get(server, state, tid)["result"]["status"] == "cancelled"

        # The unwound waiter's discarded outcome never overwrites the cancel, and
        # a late update finds nothing outstanding (acked, ignored)
        sleep(0.2)
        @test _ext_get(server, state, tid)["result"]["status"] == "cancelled"
        late = _ext_update(server, state, tid; responses=Dict{String,Any}(
            pending_key => Dict{String,Any}("content" => Dict{String,Any}())))
        @test late["result"]["resultType"] == "complete"
        @test _ext_get(server, state, tid)["result"]["status"] == "cancelled"
    end

    @testset "mid-task input: misuse surfaces as errors" begin
        confirmer = MCPTool(name="confirmer", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> begin
                task_detach(ctx)
                task_await_input(ctx, elicit_request("Proceed?"))
                TextContent(text="never delivered")
            end)
        no_detach = MCPTool(name="no_detach", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> begin
                task_await_input(ctx, elicit_request("Proceed?"))
                TextContent(text="unreachable")
            end)
        server, state, buf = _ext_test_server(tools=[confirmer, no_detach])
        elicit_caps = Dict{String,Any}(
            "elicitation" => Dict{String,Any}(),
            "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))

        # The creating request never declared elicitation: the server must not
        # surface the request — the await throws and the task fails
        @test _ext_call(server, state, "confirmer"; id=241) === nothing  # _EXT_CAPS: no elicitation
        tid = _ext_deferred_response(buf, 241)["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "failed")
        g = _ext_get(server, state, tid)
        @test g["result"]["error"]["code"] == -32603
        @test occursin("capability", g["result"]["error"]["message"])

        # Awaiting before detaching is a handler bug, answered as a tool error
        # (the MRTR round is the pre-detach input mechanism)
        @test _ext_call(server, state, "no_detach"; caps=elicit_caps, id=251) === nothing
        resp = _ext_deferred_response(buf, 251)
        @test resp["error"]["code"] == -32603
        @test occursin("task_detach", resp["error"]["message"])
    end

    @testset "mid-task input: registered requests are frozen (Codex r1 B1)" begin
        shared_schema = Dict{String,Any}("type" => "object",
            "properties" => Dict{String,Any}("ok" => Dict{String,Any}("type" => "boolean")))
        shared_sampling = Dict{String,Any}("messages" => Any[], "maxTokens" => 8)
        freezer = MCPTool(name="freezer", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> begin
                task_detach(ctx)
                task_await_input(ctx, [
                    elicit_request("Approve?"; requested_schema=shared_schema),
                    sampling_request(shared_sampling),
                ])
                TextContent(text="froze")
            end)
        server, state, buf = _ext_test_server(tools=[freezer])
        caps = Dict{String,Any}(
            "elicitation" => Dict{String,Any}(),
            "sampling" => Dict{String,Any}(),  # plain: tools subfeature NOT declared
            "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))
        @test _ext_call(server, state, "freezer"; caps=caps, id=261) === nothing
        tid = _ext_deferred_response(buf, 261)["result"]["taskId"]
        @test _ext_wait_for(() -> length(get(_ext_get(server, state, tid)["result"],
                                             "inputRequests", Dict())) == 2)

        # Post-registration mutation of the caller's params must not reach the
        # surfaced snapshot: a key can never be repurposed across polls, and a
        # sampling request can never grow `tools` past the capability check
        shared_schema["properties"]["evil"] = Dict{String,Any}("type" => "string")
        shared_sampling["tools"] = Any[Dict{String,Any}("name" => "t")]
        vals = collect(values(_ext_get(server, state, tid)["result"]["inputRequests"]))
        elicit_entry = first(v for v in vals if v["method"] == "elicitation/create")
        sampling_entry = first(v for v in vals if v["method"] == "sampling/createMessage")
        @test !haskey(elicit_entry["params"]["requestedSchema"]["properties"], :evil)
        @test haskey(elicit_entry["params"]["requestedSchema"]["properties"], :ok)
        @test !haskey(sampling_entry["params"], :tools)
        _ext_cancel(server, state, tid)
    end

    @testset "mid-task input: expired parked task fails and unblocks (Codex r1 W1 + r2 W1)" begin
        unblocked = Ref(false)
        saw_client_cancel = Ref(true)
        parked = MCPTool(name="parked", description="d", parameters=[],
            task_support=:optional,
            handler=(args, ctx) -> begin
                task_detach(ctx; ttl_ms=400)
                try
                    task_await_input(ctx, elicit_request("Anyone there?"))
                catch e
                    e isa TaskCancelledException || rethrow()
                    # Expiry is distinguishable from a client cancel via
                    # task_cancelled(ctx) — false here, since nobody cancelled
                    saw_client_cancel[] = task_cancelled(ctx)
                    unblocked[] = true
                    rethrow()
                end
                TextContent(text="answered")
            end)
        server, state, buf = _ext_test_server(tools=[parked])
        elicit_caps = Dict{String,Any}(
            "elicitation" => Dict{String,Any}(),
            "extensions" => Dict{String,Any}("io.modelcontextprotocol/tasks" => Dict{String,Any}()))
        @test _ext_call(server, state, "parked"; caps=elicit_caps, id=271) === nothing
        tid = _ext_deferred_response(buf, 271)["result"]["taskId"]
        @test _ext_wait_for(() -> _ext_get(server, state, tid)["result"]["status"] == "input_required")

        # Clock-driven: the deadline timer must unwind the waiter with NO further
        # store activity (a lazy sweep alone would leave a vanished client's task
        # parked forever)
        @test _ext_wait_for(() -> unblocked[])
        @test saw_client_cancel[] == false

        # The failed record is terminal AND expired, so post-expiry polls observe
        # task-not-found — the same as any expired task
        @test _ext_get(server, state, tid)["error"]["code"] == -32602
    end

    @testset "frozen params preserve numeric fidelity (Codex r2 W2)" begin
        # An integer beyond Int64 in a schema const must survive freezing exactly
        # (a JSON round-trip would degrade it to Float64)
        big_n = big(10)^30 + 1
        r = ModelContextProtocol._frozen_input_request(
            sampling_request(Dict{String,Any}("maxTokens" => big_n, "messages" => Any[])))
        @test r.params["maxTokens"] == big_n
        @test occursin(string(big_n), JSON3.write(r.params))

        # Mutation isolation holds with the owned copy, at depth
        src = Dict{String,Any}("m" => Dict{String,Any}("x" => 1))
        r2 = ModelContextProtocol._frozen_input_request(sampling_request(src))
        src["m"]["x"] = 2
        @test r2.params["m"]["x"] == 1

        # The snapshot severs ALIASES OF ANY SHAPE within the accepted plain-JSON
        # set: a caller-held Set or a NamedTuple's mutable field must not be able
        # to rewrite the frozen params
        src_set = Set(["stop"])
        src_inner = Dict{String,Any}("x" => 1)
        r3 = ModelContextProtocol._frozen_input_request(sampling_request(Dict{String,Any}(
            "s" => src_set, "nt" => (inner = src_inner,))))
        push!(src_set, "CHANGED"); src_inner["x"] = 99
        w = JSON3.write(r3.params)
        @test !occursin("CHANGED", w) && !occursin("99", w)

        # Even a BigInt is snapshotted by value: its GMP backing is mutable in place
        bn = big(7)
        r4 = ModelContextProtocol._frozen_input_request(
            sampling_request(Dict{String,Any}("n" => bn)))
        Base.GMP.MPZ.add!(bn, big(1))  # in-place: the caller's bn is now 8
        @test r4.params["n"] == 7

        # Everything outside the closed plain-JSON set refuses with a clear error —
        # including JSON3-serializable values that deepcopy passes through by
        # identity (Regex) or that wrap arbitrary mutable state (Ref, functions),
        # at any nesting depth
        for bad in (identity, Ref(1), r"safe", Dict{String,Any}("nested" => Ref(1)))
            @test_throws ArgumentError ModelContextProtocol._frozen_input_request(
                sampling_request(Dict{String,Any}("v" => bad)))
        end
    end

    @testset "mid-task input: cancellation beats validation (Codex r1 N1)" begin
        server, _, _ = _ext_test_server()
        rec = create_task!(server.tasks, "tools/call"; era=:ext)
        cancel_task!(server.tasks, rec)
        # Undeclared capability (roots) on an already-cancelled task: the handler
        # must see the cancellation, not a validation error that skips its
        # cancellation-specific cleanup
        ctx = RequestContext(server=server, request_id=1, protocol_version="2026-07-28",
                             client_capabilities=_EXT_CAPS, task=rec)
        @test_throws TaskCancelledException task_await_input(ctx, roots_request())
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

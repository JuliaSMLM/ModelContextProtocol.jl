# test/features/test_tasks.jl
#
# MCP Tasks (SEP-1686, experimental): task store semantics + the task-augmented
# tools/call and tasks/* handler flows, in-process over a StdioTransport whose
# output is an IOBuffer (deferred responses and status notifications land there).
# No `using` here by convention — runtests.jl provides the imports.

# Wait until f() is true, with a generous timeout for slow CI machines.
function _tasks_wait_for(f; timeout=15.0, interval=0.05)
    deadline = time() + timeout
    while time() < deadline
        f() && return true
        sleep(interval)
    end
    f()
end

# Collect JSON lines written out-of-band (deferred responses + notifications).
function _tasks_oob_lines(buf::IOBuffer)
    [JSON3.read(l) for l in split(String(take!(buf)), '\n') if startswith(l, "{")]
end

function _tasks_test_server(; tools=MCPTool[])
    server = mcp_server(name="tasks-test", version="0.0.1", tools=tools)
    buf = IOBuffer()
    server.transport = StdioTransport(input=IOBuffer(), output=buf)
    state = ServerState()
    init = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"""
    init_resp = JSON3.read(process_message(server, state, init))
    (server, state, buf, init_resp)
end

_tasks_msg(server, state, s) = process_message(server, state, s)

@testset "MCP Tasks" begin

    @testset "TaskStore semantics" begin
        store = TaskStore()

        # ttl defaulting and clamping
        t1 = create_task!(store, "tools/call")
        @test t1.ttl_ms == store.default_ttl_ms
        t2 = create_task!(store, "tools/call"; requested_ttl_ms=10_000_000_000)
        @test t2.ttl_ms == store.max_ttl_ms
        t3 = create_task!(store, "tools/call"; requested_ttl_ms=1234)
        @test t3.ttl_ms == 1234

        # initial state + wire shape
        @test t1.status == "working"
        w = task_wire(t1)
        @test w["taskId"] == t1.task_id
        @test w["status"] == "working"
        @test haskey(w, "ttl") && w["ttl"] == store.default_ttl_ms
        @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", w["createdAt"])
        @test w["pollInterval"] == store.poll_interval_ms

        # terminal transitions
        ok = CallToolResult(content=[Dict{String,Any}("type" => "text", "text" => "x")])
        @test finish_task!(store, t1, ok)
        @test t1.status == "completed"
        @test task_is_terminal(t1)
        # terminal records never transition again
        @test !finish_task!(store, t1, ok)
        @test !cancel_task!(store, t1)

        # isError result -> failed
        bad = CallToolResult(content=Dict{String,Any}[], is_error=true)
        @test finish_task!(store, t2, bad)
        @test t2.status == "failed"

        # cancel beats late completion: outcome discarded
        @test cancel_task!(store, t3)
        @test t3.status == "cancelled" && t3.cancel_requested
        @test !finish_task!(store, t3, ok)
        @test t3.status == "cancelled" && t3.result === nothing

        # principal binding: mismatches are indistinguishable from not-found
        ta = create_task!(store, "tools/call"; principal="alice")
        @test get_task(store, ta.task_id, "alice") === ta
        @test get_task(store, ta.task_id, "bob") === nothing
        @test get_task(store, ta.task_id, nothing) === nothing
        @test get_task(store, t1.task_id, nothing) === t1
        @test get_task(store, "no-such-task", nothing) === nothing

        # expiry sweep deletes terminal tasks past ttl, keeps non-terminal ones
        te = create_task!(store, "tools/call"; requested_ttl_ms=0)
        finish_task!(store, te, ok)
        tw = create_task!(store, "tools/call"; requested_ttl_ms=0)  # stays working
        sleep(0.01)
        @test get_task(store, te.task_id, nothing) === nothing      # swept
        @test get_task(store, tw.task_id, nothing) === tw           # kept (non-terminal)

        # cursor encoding is opaque but round-trips; junk is rejected
        @test decode_task_cursor(encode_task_cursor(7)) == 7
        @test_throws ArgumentError decode_task_cursor("zzz")
        @test_throws ArgumentError decode_task_cursor(base64encode("lol:5"))
    end

    @testset "task-augmented tools/call lifecycle" begin
        slow = MCPTool(name="slow_echo", description="d",
            parameters=[ToolParameter(name="msg", type="string", description="m", required=true)],
            handler=args -> (sleep(0.2); TextContent(text="echo: $(args["msg"])")),
            task_support=:optional)
        server, state, buf, init_resp = _tasks_test_server(tools=[slow])

        # capability advertised with full spec shape
        tasks_cap = init_resp.result.capabilities.tasks
        @test haskey(tasks_cap, :list) && haskey(tasks_cap, :cancel)
        @test haskey(tasks_cap.requests.tools, :call)

        # tools/list carries execution.taskSupport
        list = JSON3.read(_tasks_msg(server, state, """{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"""))
        @test list.result.tools[1].execution.taskSupport == "optional"

        # create: immediate CreateTaskResult, no tool output in it
        create = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"slow_echo","arguments":{"msg":"hi"},"task":{"ttl":60000}}}"""))
        task = create.result.task
        @test task.status == "working"
        @test task.ttl == 60000
        @test !haskey(create.result, :content)
        tid = String(task.taskId)

        # tasks/get returns the task flattened into the result
        get1 = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":4,"method":"tasks/get","params":{"taskId":"$tid"}}"""))
        @test get1.result.taskId == tid
        @test get1.result.status in ("working", "completed")

        # tasks/result on a non-terminal task defers (loop gets nothing back)…
        deferred = _tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":5,"method":"tasks/result","params":{"taskId":"$tid"}}""")
        @test deferred === nothing

        # …and the response is delivered out-of-band once the task completes
        @test _tasks_wait_for(() -> begin
            record = get_task(server.tasks, tid, nothing)
            record !== nothing && task_is_terminal(record)
        end)
        local oob
        @test _tasks_wait_for(() -> begin
            seek(buf, 0)
            occursin("\"id\":5", String(read(buf)))
        end)
        oob = _tasks_oob_lines(buf)
        result_msg = only(filter(m -> haskey(m, :id) && m.id == 5, oob))
        @test result_msg.result.content[1].text == "echo: hi"
        @test result_msg.result.isError == false
        @test result_msg.result._meta["io.modelcontextprotocol/related-task"]["taskId"] == tid
        # status notification with the full task state
        notes = filter(m -> haskey(m, :method) && m.method == "notifications/tasks/status", oob)
        @test !isempty(notes)
        @test notes[end].params.taskId == tid
        @test notes[end].params.status == "completed"

        # terminal tasks/result now answers immediately
        res2 = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":6,"method":"tasks/result","params":{"taskId":"$tid"}}"""))
        @test res2.result.content[1].text == "echo: hi"

        # unknown task id -> -32602
        nf = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":7,"method":"tasks/get","params":{"taskId":"nope"}}"""))
        @test nf.error.code == -32602
    end

    @testset "failure mapping" begin
        boom = MCPTool(name="boom", description="d", parameters=[],
            handler=args -> error("kaboom"), task_support=:optional)
        toolerr = MCPTool(name="toolerr", description="d", parameters=[],
            handler=args -> CallToolResult(content=[Dict{String,Any}("type" => "text", "text" => "bad")], is_error=true),
            task_support=:optional)
        server, state, buf, _ = _tasks_test_server(tools=[boom, toolerr])

        # handler exception -> failed; tasks/result returns the JSON-RPC error
        c1 = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"boom","task":{}}}"""))
        tid1 = String(c1.result.task.taskId)
        @test _tasks_wait_for(() -> get_task(server.tasks, tid1, nothing).status == "failed")
        g = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":3,"method":"tasks/get","params":{"taskId":"$tid1"}}"""))
        @test occursin("kaboom", g.result.statusMessage)
        r = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":4,"method":"tasks/result","params":{"taskId":"$tid1"}}"""))
        @test r.error.code == -32603
        @test occursin("kaboom", r.error.message)

        # CallToolResult(is_error=true) -> failed, but tasks/result returns the payload
        c2 = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"toolerr","task":{}}}"""))
        tid2 = String(c2.result.task.taskId)
        @test _tasks_wait_for(() -> get_task(server.tasks, tid2, nothing).status == "failed")
        r2 = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":6,"method":"tasks/result","params":{"taskId":"$tid2"}}"""))
        @test r2.result.isError == true
        @test r2.result.content[1].text == "bad"
    end

    @testset "cancellation" begin
        observed = Ref(false)
        stubborn = MCPTool(name="stubborn", description="d", parameters=[],
            handler=(args, ctx) -> begin
                for _ in 1:600
                    task_cancelled(ctx) && (observed[] = true; break)
                    sleep(0.05)
                end
                TextContent(text="finished anyway")
            end,
            task_support=:optional)
        server, state, buf, _ = _tasks_test_server(tools=[stubborn])

        c = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"stubborn","task":{}}}"""))
        tid = String(c.result.task.taskId)

        cancel = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":3,"method":"tasks/cancel","params":{"taskId":"$tid"}}"""))
        @test cancel.result.status == "cancelled"

        # second cancel rejected per spec
        again = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":4,"method":"tasks/cancel","params":{"taskId":"$tid"}}"""))
        @test again.error.code == -32602
        @test occursin("terminal", again.error.message)

        # cooperative handler observed the cancellation; status stays cancelled
        @test _tasks_wait_for(() -> observed[])
        sleep(0.2)  # let the worker's (discarded) finish attempt run
        g = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":5,"method":"tasks/get","params":{"taskId":"$tid"}}"""))
        @test g.result.status == "cancelled"

        # tasks/result on a cancelled-before-completion task -> error
        r = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":6,"method":"tasks/result","params":{"taskId":"$tid"}}"""))
        @test r.error.code == -32602
        @test occursin("cancelled", r.error.message)
    end

    @testset "tool-level negotiation" begin
        plain = MCPTool(name="plain", description="d", parameters=[],
            handler=args -> TextContent(text="ok"))  # task_support defaults to :forbidden
        must = MCPTool(name="must", description="d", parameters=[],
            handler=args -> TextContent(text="ok"), task_support=:required)
        server, state, _, _ = _tasks_test_server(tools=[plain, must])

        # forbidden tool called as task -> -32601
        f = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"plain","task":{}}}"""))
        @test f.error.code == -32601

        # required tool called synchronously -> -32601
        s = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"must"}}"""))
        @test s.error.code == -32601

        # required tool called as task -> works
        t = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"must","task":{}}}"""))
        @test t.result.task.status == "working"

        # forbidden tool called normally still works
        n = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"plain"}}"""))
        @test n.result.content[1].text == "ok"
    end

    @testset "old-protocol sessions ignore tasks" begin
        plain = MCPTool(name="plain", description="d", parameters=[],
            handler=args -> TextContent(text="ok"))
        server = mcp_server(name="tasks-old", version="0.0.1", tools=[plain])
        server.transport = StdioTransport(input=IOBuffer(), output=IOBuffer())
        state = ServerState()
        init = JSON3.read(process_message(server, state,
            """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"""))
        # capability withheld from pre-2025-11-25 clients
        @test !haskey(init.result.capabilities, :tasks)

        # task metadata ignored -> synchronous execution (spec-mandated)
        call = JSON3.read(process_message(server, state,
            """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"plain","task":{}}}"""))
        @test call.result.content[1].text == "ok"

        # tasks/* methods don't exist for this session
        g = JSON3.read(process_message(server, state,
            """{"jsonrpc":"2.0","id":3,"method":"tasks/get","params":{"taskId":"x"}}"""))
        @test g.error.code == -32601
    end

    @testset "tasks/list pagination + principal filtering" begin
        server, state, _, _ = _tasks_test_server()
        server.tasks = TaskStore(page_size=2)
        for i in 1:5
            create_task!(server.tasks, "tools/call")
        end
        create_task!(server.tasks, "tools/call"; principal="alice")

        ids = String[]
        cursor = nothing
        for _ in 1:5  # bounded; expect 3 pages
            params = cursor === nothing ? "{}" : """{"cursor":"$cursor"}"""
            page = JSON3.read(_tasks_msg(server, state,
                """{"jsonrpc":"2.0","id":2,"method":"tasks/list","params":$params}"""))
            append!(ids, String.(t.taskId for t in page.result.tasks))
            haskey(page.result, :nextCursor) || break
            cursor = String(page.result.nextCursor)
        end
        @test length(ids) == 5              # alice's task filtered out
        @test length(unique(ids)) == 5      # no duplicates across pages

        bad = JSON3.read(_tasks_msg(server, state,
            """{"jsonrpc":"2.0","id":3,"method":"tasks/list","params":{"cursor":"junk"}}"""))
        @test bad.error.code == -32602
    end

    @testset "tasks/list withheld on unauthenticated HTTP" begin
        server = mcp_server(name="tasks-http", version="0.0.1")
        server.transport = HttpTransport(port=39999)  # not connected; auth === nothing
        state = ServerState()
        init = JSON3.read(process_message(server, state,
            """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"""))
        tasks_cap = init.result.capabilities.tasks
        @test !haskey(tasks_cap, :list)          # cannot identify requestors
        @test haskey(tasks_cap, :cancel)

        l = JSON3.read(process_message(server, state,
            """{"jsonrpc":"2.0","id":2,"method":"tasks/list","params":{}}"""))
        @test l.error.code == -32601
    end
end

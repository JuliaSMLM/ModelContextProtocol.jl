@testset "Streamable HTTP Transport" begin
    @testset "SSE Event Formatting" begin
        # Test basic event formatting
        event = ModelContextProtocol.format_sse_event("test data")
        @test event == "data: test data\n\n"
        
        # Test with event type
        event = ModelContextProtocol.format_sse_event("test data", event="message")
        @test contains(event, "event: message")
        @test contains(event, "data: test data")
        
        # Test with ID
        event = ModelContextProtocol.format_sse_event("test data", id=123)
        @test contains(event, "id: 123")
        @test contains(event, "data: test data")
        
        # Test multiline data
        multiline = "line1\nline2\nline3"
        event = ModelContextProtocol.format_sse_event(multiline)
        @test contains(event, "data: line1")
        @test contains(event, "data: line2")
        @test contains(event, "data: line3")
    end
    
    @testset "Session ID Generation" begin
        # Test session ID generation
        session_id = ModelContextProtocol.generate_session_id()
        @test !isempty(session_id)
        @test ModelContextProtocol.is_valid_session_id(session_id)
        
        # Test invalid session IDs
        @test !ModelContextProtocol.is_valid_session_id("")
        @test !ModelContextProtocol.is_valid_session_id("has spaces")
        @test !ModelContextProtocol.is_valid_session_id("has\nnewline")
        @test !ModelContextProtocol.is_valid_session_id("has\ttab")
        
        # Test valid session IDs
        @test ModelContextProtocol.is_valid_session_id("valid-session-123")
        @test ModelContextProtocol.is_valid_session_id("UUID-1234-5678-90AB")
    end
    
    @testset "SSE Streaming" begin
        port = 13090 + rand(1:1000)
        
        transport = HttpTransport(port=port)
        
        # Create a tool that simulates streaming
        stream_tool = MCPTool(
            name = "stream_test",
            description = "Test streaming",
            handler = function(params)
                return TextContent(text = "Stream response")
            end,
            parameters = []  # No parameters for this tool
        )
        
        server = mcp_server(
            name = "sse-test-server",
            version = "1.0.0",
            tools = [stream_tool]
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        
        server_task = @async start!(server)
        sleep(2)
        
        # Initialize first
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-06-18",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        
        @test response.status == 200
        session_id = HTTP.header(response, "Mcp-Session-Id", "")
        
        # Test SSE connection. Collect lines continuously and poll for the connection
        # event with a deadline — do NOT read until eof or a fixed line count: a
        # healthy SSE stream stays open indefinitely, so an eof-terminated reader
        # only returns when the connection dies. (This test used to pass that way —
        # the notification loop crashed ~100ms in and dropped the stream, handing
        # the reader its eof. See the issue #71 regression testset below.)
        sse_lines = String[]
        sse_task = @async begin
            try
                HTTP.open("GET", "http://127.0.0.1:$port/",
                         ["Accept" => "text/event-stream"]) do io
                    while !eof(io)
                        line = readline(io)
                        isempty(line) || push!(sse_lines, line)
                    end
                end
            catch e
                # Connection torn down at cleanup
            end
        end

        deadline = time() + 10
        while time() < deadline && isempty(sse_lines)
            sleep(0.05)
        end

        # SSE should have received connection event
        @test length(sse_lines) > 0
        event_text = join(sse_lines, "\n")
        @test contains(event_text, "event: connection") || contains(event_text, "connected")
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end

    @testset "SSE notification delivery (issue #71 regression)" begin
        # The initial "connection" event is written BEFORE the notification loop, so a
        # test asserting only that stays green even when the loop itself is broken.
        # This test asserts a real OUT-OF-BAND notification traverses queue -> GET SSE
        # stream (the path used by e.g. background MCP Task status updates;
        # request-scoped notifications ride the originating POST's SSE response stream
        # instead — see the dedicated testset below). Two historical failure modes this
        # guards against:
        #   - `close(timer)` / `flush(sse_stream)` resolving to the package's own
        #     Transport-only methods (Base shadowing) -> MethodError on the first loop
        #     iteration, swallowed by the catch, stream dropped ~100ms after connect;
        #   - the loop leaking one blocked `take!` waiter task per iteration, so
        #     arriving notifications woke an orphaned waiter (Channel waiters are
        #     FIFO) and were silently lost.
        port = 15090 + rand(1:1000)

        transport = HttpTransport(port=port)
        server = mcp_server(
            name = "sse-notify-server",
            version = "1.0.0"
        )
        server.transport = transport
        ModelContextProtocol.connect(transport)
        server_task = @async start!(server)
        sleep(2)

        init_response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-11-25",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-11-25",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        @test init_response.status == 200
        session_id = HTTP.header(init_response, "Mcp-Session-Id", "")

        # Collect SSE lines continuously; the main task polls this vector.
        sse_lines = String[]
        sse_task = @async begin
            try
                HTTP.open("GET", "http://127.0.0.1:$port/",
                          ["Accept" => "text/event-stream",
                           "Mcp-Session-Id" => session_id]) do io
                    while !eof(io)
                        push!(sse_lines, readline(io))
                    end
                end
            catch
                # Connection torn down at cleanup
            end
        end

        # Wait until the stream is established (connection event seen)...
        deadline = time() + 10
        while time() < deadline && !any(contains("connection"), sse_lines)
            sleep(0.05)
        end
        @test any(contains("connection"), sse_lines)

        # ...then linger PAST several 100ms notification-loop iterations. Under the
        # historical bugs this idle window is what killed the stream / accumulated
        # the orphaned waiters, so it must precede the notification for the test to
        # discriminate.
        sleep(1.0)

        # Emit an out-of-band notification (no request being handled, so no
        # task-local route): it must flow over the standalone GET SSE stream.
        ModelContextProtocol.send_notification(transport, JSON3.write(Dict(
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => Dict(
                "progressToken" => "tok-71",
                "progress" => 1,
                "total" => 1,
                "message" => "sse-regression-tick"
            )
        )))

        # The progress notification must arrive on the SSE stream.
        deadline = time() + 10
        while time() < deadline && !any(contains("notifications/progress"), sse_lines)
            sleep(0.05)
        end
        received = join(sse_lines, "\n")
        @test contains(received, "notifications/progress")
        @test contains(received, "tok-71")
        @test contains(received, "sse-regression-tick")

        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end

    @testset "Request-scoped notifications ride the POST SSE response stream" begin
        # Per Streamable HTTP, notifications related to a request (progress, log
        # messages) are delivered on that request's SSE response stream, before the
        # final response — NOT on the standalone GET stream. This is what standard
        # clients (TS SDK, Inspector, conformance suite) listen to.
        port = 17090 + rand(1:1000)

        transport = HttpTransport(port=port)
        progress_tool = MCPTool(
            name = "progress_test",
            description = "Emit a progress notification",
            parameters = [],
            handler = (args, ctx) -> begin
                send_progress(ctx, 1; total = 1, message = "post-sse-tick")
                TextContent(text = "done")
            end
        )
        log_tool = MCPTool(
            name = "log_test",
            description = "Emit a log notification",
            parameters = [],
            handler = args -> begin
                @info "post-sse-log-probe"
                TextContent(text = "logged")
            end
        )
        quiet_tool = MCPTool(
            name = "quiet_test",
            description = "No notifications",
            parameters = [],
            handler = args -> TextContent(text = "quiet")
        )
        server = mcp_server(
            name = "post-sse-server",
            version = "1.0.0",
            tools = [progress_tool, log_tool, quiet_tool]
        )
        server.transport = transport
        ModelContextProtocol.connect(transport)
        prior_logger = Logging.global_logger()
        server_task = @async start!(server)
        sleep(2)

        init_response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-11-25",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-11-25",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        @test init_response.status == 200
        session_id = HTTP.header(init_response, "Mcp-Session-Id", "")

        # Progress-emitting call: the response is an SSE stream scoped to the request,
        # carrying the notification then the final response, in order.
        call_response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Mcp-Session-Id" => session_id,
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "progress_test",
                    "arguments" => Dict(),
                    "_meta" => Dict("progressToken" => "tok-post")
                ),
                "id" => 2
            ))
        )
        @test call_response.status == 200
        @test startswith(HTTP.header(call_response, "Content-Type", ""), "text/event-stream")
        body = String(call_response.body)
        @test contains(body, "notifications/progress")
        @test contains(body, "tok-post")
        @test contains(body, "post-sse-tick")
        @test contains(body, "\"result\"")
        @test first(findfirst("notifications/progress", body)) <
              first(findfirst("\"result\"", body))

        # Log-emitting call: notifications/message rides the same request's stream.
        log_response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Mcp-Session-Id" => session_id,
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "tools/call",
                "params" => Dict("name" => "log_test", "arguments" => Dict()),
                "id" => 3
            ))
        )
        @test log_response.status == 200
        @test startswith(HTTP.header(log_response, "Content-Type", ""), "text/event-stream")
        log_body = String(log_response.body)
        @test contains(log_body, "notifications/message")
        @test contains(log_body, "post-sse-log-probe")

        # Quiet call: stays a plain JSON response.
        quiet_response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Mcp-Session-Id" => session_id,
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "tools/call",
                "params" => Dict("name" => "quiet_test", "arguments" => Dict()),
                "id" => 4
            ))
        )
        @test startswith(HTTP.header(quiet_response, "Content-Type", ""), "application/json")
        quiet_result = JSON3.read(String(quiet_response.body))
        @test quiet_result["id"] == 4

        # A client whose Accept lacks text/event-stream gets plain JSON with the
        # request-scoped notifications dropped.
        json_only = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Mcp-Session-Id" => session_id,
             "Accept" => "application/json"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "progress_test",
                    "arguments" => Dict(),
                    "_meta" => Dict("progressToken" => "tok-json")
                ),
                "id" => 5
            ))
        )
        @test startswith(HTTP.header(json_only, "Content-Type", ""), "application/json")
        json_result = JSON3.read(String(json_only.body))
        @test json_result["id"] == 5
        @test haskey(json_result, "result")

        # Clean up (restore the suite's logger — start! installed its own)
        server.active = false
        ModelContextProtocol.close(transport)
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
        Logging.global_logger(prior_logger)
    end

    @testset "Modern era over HTTP (headers, statuses, session isolation)" begin
        port = 19090 + rand(1:1000)
        # session_required=true is the hard case: modern requests must be exempt
        transport = HttpTransport(port = port, session_required = true)
        echo_tool = MCPTool(name = "echo", description = "Echo", parameters = [
                ToolParameter(name = "message", type = "string", description = "m", required = true)],
            handler = args -> TextContent(text = args["message"]))
        server = mcp_server(name = "modern-http", version = "1.0.0", tools = [echo_tool])
        server.transport = transport
        ModelContextProtocol.connect(transport)
        server_task = @async start!(server)
        sleep(2)

        url = "http://127.0.0.1:$port/"
        mmeta = Dict(
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => Dict())
        base = ["Content-Type" => "application/json",
                "Accept" => "application/json, text/event-stream"]
        mhdrs(method; version = "2026-07-28") = vcat(base,
            ["MCP-Protocol-Version" => version, "Mcp-Method" => method])
        post(hdrs, msg) = HTTP.post(url, hdrs, JSON3.write(msg); status_exception = false)

        # Legacy initialize first: mints a session and negotiates a legacy version
        init = post(vcat(base, ["MCP-Protocol-Version" => "2025-11-25"]), Dict(
            "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
            "params" => Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict(),
                             "clientInfo" => Dict("name" => "l", "version" => "1"))))
        @test init.status == 200
        session = HTTP.header(init, "Mcp-Session-Id", "")
        @test !isempty(session)

        # Legacy request without a session is rejected (session_required)
        r = post(base, Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tools/list",
                            "params" => Dict()))
        @test r.status == 400

        # Modern request without a session sails through: sessions don't exist for
        # it, the response echoes ITS version (not the legacy-negotiated one) and
        # carries no session header
        r = post(mhdrs("tools/list"), Dict("jsonrpc" => "2.0", "id" => 3,
            "method" => "tools/list", "params" => Dict("_meta" => mmeta)))
        @test r.status == 200
        @test HTTP.header(r, "MCP-Protocol-Version", "") == "2026-07-28"
        @test HTTP.header(r, "Mcp-Session-Id", "") == ""
        @test JSON3.read(String(r.body))["result"]["resultType"] == "complete"

        # Missing Mcp-Method -> 400 + -32020
        r = post(vcat(base, ["MCP-Protocol-Version" => "2026-07-28"]),
            Dict("jsonrpc" => "2.0", "id" => 4, "method" => "tools/list",
                 "params" => Dict("_meta" => mmeta)))
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32020

        # Mcp-Method mismatch -> 400 + -32020
        r = post(mhdrs("tools/call"), Dict("jsonrpc" => "2.0", "id" => 5,
            "method" => "tools/list", "params" => Dict("_meta" => mmeta)))
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32020

        # Missing MCP-Protocol-Version header -> 400 + -32020
        r = post(vcat(base, ["Mcp-Method" => "tools/list"]),
            Dict("jsonrpc" => "2.0", "id" => 6, "method" => "tools/list",
                 "params" => Dict("_meta" => mmeta)))
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32020

        # tools/call requires Mcp-Name mirroring params.name
        call_msg(id) = Dict("jsonrpc" => "2.0", "id" => id, "method" => "tools/call",
            "params" => Dict("name" => "echo", "arguments" => Dict("message" => "hi"),
                             "_meta" => mmeta))
        r = post(mhdrs("tools/call"), call_msg(7))                     # missing Mcp-Name
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32020
        r = post(vcat(mhdrs("tools/call"), ["Mcp-Name" => "wrong"]), call_msg(8))
        @test r.status == 400
        r = post(vcat(mhdrs("tools/call"), ["Mcp-Name" => "echo"]), call_msg(9))
        @test r.status == 200
        @test JSON3.read(String(r.body))["result"]["content"][1]["text"] == "hi"

        # Base64 sentinel value decodes before comparison; malformed sentinel rejects
        sentinel = "=?base64?" * Base64.base64encode("echo") * "?="
        r = post(vcat(mhdrs("tools/call"), ["Mcp-Name" => sentinel]), call_msg(10))
        @test r.status == 200
        r = post(vcat(mhdrs("tools/call"), ["Mcp-Name" => "=?base64?!!notb64!!?="]), call_msg(11))
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32020

        # Unsupported version (header matches body) -> 400 + -32022 with data
        bad_meta = Dict("io.modelcontextprotocol/protocolVersion" => "1999-01-01",
                        "io.modelcontextprotocol/clientCapabilities" => Dict())
        r = post(mhdrs("tools/list"; version = "1999-01-01"),
            Dict("jsonrpc" => "2.0", "id" => 12, "method" => "tools/list",
                 "params" => Dict("_meta" => bad_meta)))
        @test r.status == 400
        err = JSON3.read(String(r.body))["error"]
        @test err["code"] == -32022
        @test err["data"]["requested"] == "1999-01-01"

        # Removed method -> 404 + -32601
        r = post(mhdrs("ping"), Dict("jsonrpc" => "2.0", "id" => 13, "method" => "ping",
                                     "params" => Dict("_meta" => mmeta)))
        @test r.status == 404
        @test JSON3.read(String(r.body))["error"]["code"] == -32601

        # Missing clientCapabilities -> 400 + -32602
        r = post(mhdrs("tools/list"), Dict("jsonrpc" => "2.0", "id" => 14,
            "method" => "tools/list", "params" => Dict("_meta" => Dict(
                "io.modelcontextprotocol/protocolVersion" => "2026-07-28"))))
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32602

        # server/discover without _meta -> 400 + -32602 (modern-only method)
        r = post(vcat(base, ["Mcp-Method" => "server/discover"]),
            Dict("jsonrpc" => "2.0", "id" => 15, "method" => "server/discover",
                 "params" => Dict()))
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32602

        # A modern HEADER with a legacy body must NOT slip past validation: a
        # gateway routing on the header and a backend executing the body would
        # otherwise see two different requests. The header makes the request
        # modern-era, so its missing required _meta field is -32602 (with -32020
        # reserved for values that disagree); either way it is 400-rejected before
        # any legacy handling.
        r = post(mhdrs("tools/list"), Dict("jsonrpc" => "2.0", "id" => 17,
            "method" => "tools/list", "params" => Dict()))  # no modern _meta
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32602

        # Duplicate standard headers are a smuggling vector -> 400 + -32020
        r = post(vcat(mhdrs("tools/list"), ["Mcp-Method" => "tools/list"]),
            Dict("jsonrpc" => "2.0", "id" => 18, "method" => "tools/list",
                 "params" => Dict("_meta" => mmeta)))
        @test r.status == 400
        @test JSON3.read(String(r.body))["error"]["code"] == -32020

        # Permissive Base64 must be rejected: missing padding and invalid chars
        # both decode "successfully" under Julia's lenient decoder
        for bad in ("=?base64?" * "SGVsbG8" * "?=",          # no padding (len % 4 != 0)
                    "=?base64?" * "SGVs!!!bG8=" * "?=")      # invalid characters
            r = post(vcat(mhdrs("tools/call"), ["Mcp-Name" => bad]), call_msg(19))
            @test r.status == 400
            @test JSON3.read(String(r.body))["error"]["code"] == -32020
        end

        # Header injection via the body version string: the response must never
        # echo an unvalidated body value into a header
        inj_meta = Dict(
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28\r\nSet-Cookie: injected=1",
            "io.modelcontextprotocol/clientCapabilities" => Dict())
        r = post(mhdrs("tools/list"), Dict("jsonrpc" => "2.0", "id" => 20,
            "method" => "tools/list", "params" => Dict("_meta" => inj_meta)))
        @test r.status == 400
        @test HTTP.header(r, "Set-Cookie", "") == ""
        @test !contains(HTTP.header(r, "MCP-Protocol-Version", ""), "injected")

        # Modern-marked notification: 202 without legacy session/version headers
        r = post(mhdrs("notifications/initialized"), Dict(
            "jsonrpc" => "2.0", "method" => "notifications/initialized",
            "params" => Dict("_meta" => mmeta)))
        @test r.status == 202
        @test HTTP.header(r, "Mcp-Session-Id", "") == ""

        # A JSON array body (batch) must produce a JSON-RPC rejection, not a 500
        r = HTTP.post(url, base, "[]"; status_exception = false)
        @test r.status != 500
        @test contains(String(r.body), "error")

        # GET declaring a modern version -> 405 (the modern era removed GET)
        r = HTTP.get(url, ["MCP-Protocol-Version" => "2026-07-28"]; status_exception = false)
        @test r.status == 405

        # The health GET must not leak the legacy session ID
        r = HTTP.get(url, ["Accept" => "application/json"]; status_exception = false)
        @test r.status == 200
        @test !haskey(JSON3.read(String(r.body)), "session_id")

        # Legacy session still intact after all the modern traffic
        r = post(vcat(base, ["Mcp-Session-Id" => session]),
            Dict("jsonrpc" => "2.0", "id" => 16, "method" => "tools/list", "params" => Dict()))
        @test r.status == 200
        @test !haskey(JSON3.read(String(r.body))["result"], "resultType")

        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end

    @testset "subscriptions/listen over live HTTP" begin
        port = 20090 + rand(1:1000)
        # Fast keepalives so idle-disconnect detection is observable in test time
        transport = HttpTransport(port = port, sse_keepalive_secs = 0.3)
        server = mcp_server(name = "listen-http", version = "1.0.0",
            capabilities = ModelContextProtocol.Capability[
                ModelContextProtocol.ToolCapability(list_changed = true),
                ModelContextProtocol.PromptCapability(list_changed = true),
                ModelContextProtocol.ResourceCapability(list_changed = true, subscribe = true)],
            tools = [MCPTool(name = "noop", description = "noop", parameters = [],
                             handler = args -> TextContent(text = "ok"))])
        server.transport = transport
        ModelContextProtocol.connect(transport)
        server_task = @async start!(server)
        sleep(2)

        url = "http://127.0.0.1:$port/"
        mmeta = Dict(
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => Dict())
        listen_headers = ["Content-Type" => "application/json",
                          "Accept" => "application/json, text/event-stream",
                          "MCP-Protocol-Version" => "2026-07-28",
                          "Mcp-Method" => "subscriptions/listen"]
        listen_body(id) = JSON3.write(Dict(
            "jsonrpc" => "2.0", "id" => id, "method" => "subscriptions/listen",
            "params" => Dict("_meta" => mmeta,
                             "notifications" => Dict("toolsListChanged" => true))))

        # The listen response is a long-lived stream: collect it continuously and
        # poll (never read to eof — a healthy stream stays open indefinitely). The
        # listener records any exception instead of swallowing it: only teardown IO
        # errors are acceptable, and that is asserted at the end.
        lines = String[]
        listen_err = Ref{Any}(nothing)
        listen_task = @async begin
            try
                HTTP.open("POST", url, listen_headers) do io
                    write(io, listen_body("sub-1"))
                    HTTP.closewrite(io)
                    HTTP.startread(io)
                    while !eof(io)
                        line = readline(io)
                        isempty(line) || push!(lines, line)
                    end
                end
            catch e
                listen_err[] = e
            end
        end

        seen(pat) = any(l -> occursin(pat, l), lines)
        function waitfor(pred, secs = 10)
            deadline = time() + secs
            while time() < deadline && !pred()
                sleep(0.05)
            end
            pred()
        end

        try
            # A listen whose Accept cannot carry SSE is rejected up front — it
            # could never read the stream it asks for
            r = HTTP.post(url, ["Content-Type" => "application/json",
                                "Accept" => "application/json",
                                "MCP-Protocol-Version" => "2026-07-28",
                                "Mcp-Method" => "subscriptions/listen"],
                listen_body("sub-reject"); status_exception = false)
            @test r.status == 400
            @test JSON3.read(String(r.body))["error"]["code"] == -32600

            # ...and q=0 is a refusal, not an acceptance (media-range matching,
            # not a substring test)
            r = HTTP.post(url, ["Content-Type" => "application/json",
                                "Accept" => "text/event-stream;q=0, application/json",
                                "MCP-Protocol-Version" => "2026-07-28",
                                "Mcp-Method" => "subscriptions/listen"],
                listen_body("sub-reject-q0"); status_exception = false)
            @test r.status == 400


            # The acknowledgment MUST be the stream's first message, tagged with the id
            @test waitfor(() -> seen("notifications/subscriptions/acknowledged"))
            first_data = findfirst(l -> startswith(l, "data:"), lines)
            @test first_data !== nothing &&
                  occursin("notifications/subscriptions/acknowledged", lines[first_data])
            @test seen("io.modelcontextprotocol/subscriptionId")
            @test seen("sub-1")

            # A subscribed change is delivered on the open stream, tagged
            @test notify_list_changed(server, :tools) == 1
            @test waitfor(() -> seen("notifications/tools/list_changed"))
            tools_line = lines[findfirst(l -> occursin("notifications/tools/list_changed", l), lines)]
            @test occursin("sub-1", tools_line)

            # An UNsubscribed change must not leak onto this stream
            before = count(l -> occursin("prompts/list_changed", l), lines)
            @test notify_list_changed(server, :prompts) == 0
            sleep(1)
            @test count(l -> occursin("prompts/list_changed", l), lines) == before

            # Ordinary requests still work while the stream is open (the loop was not
            # blocked by the deferred listen request)
            r = HTTP.post(url, ["Content-Type" => "application/json",
                                "Accept" => "application/json, text/event-stream",
                                "MCP-Protocol-Version" => "2026-07-28",
                                "Mcp-Method" => "tools/list"],
                JSON3.write(Dict("jsonrpc" => "2.0", "id" => 9, "method" => "tools/list",
                                 "params" => Dict("_meta" => mmeta)));
                status_exception = false)
            @test r.status == 200

            # The live stream receives periodic keepalive comments while idle —
            # the write is what surfaces a dead socket, so this is also the
            # disconnect-detection mechanism under test below
            @test waitfor(() -> any(l -> startswith(l, ": keepalive"), lines))

            # A second subscriber that disconnects while idle is detected WITHOUT
            # any broadcast: the keepalive write fails on the dead socket and the
            # connection handler dies, freeing the route. The registry record is
            # inert from that moment (its route is gone) and is swept by the next
            # broadcast or registration. Raw TCP so the client can vanish abruptly
            # (an HTTP.open exit would block draining the endless stream).
            # (The two Accept LINES also prove repeated fields are combined per
            # RFC 9110 — SSE is named only in the second one, and the request
            # must not be rejected.)
            body2 = listen_body("sub-2")
            sock = HTTP.Sockets.connect("127.0.0.1", port)
            write(sock,
                "POST / HTTP/1.1\r\n" *
                "Host: 127.0.0.1:$port\r\n" *
                "Content-Type: application/json\r\n" *
                "Accept: application/json\r\n" *
                "Accept: text/event-stream\r\n" *
                "MCP-Protocol-Version: 2026-07-28\r\n" *
                "Mcp-Method: subscriptions/listen\r\n" *
                "Content-Length: $(ncodeunits(body2))\r\n\r\n" * body2)
            @test waitfor(() -> length(server.listen_subscriptions.subs) == 2)
            open_routes() = lock(transport.channels_lock) do
                length(transport.response_channels)
            end
            @test open_routes() == 2  # sub-1 and sub-2 streams
            Base.close(sock)  # never read the response: unread data makes this an abrupt reset
            @test waitfor(() -> open_routes() == 1, 5)  # keepalive surfaced the dead socket
            # One broadcast then sweeps the stale record and reaches only the live stream
            @test notify_list_changed(server, :tools) == 1
            @test length(server.listen_subscriptions.subs) == 1

            # stop! must end the server loop while the transport is STILL open, so
            # the graceful closing result reaches the stream before the response
            # channels are torn down (the loop checks server.active)
            stop!(server)
            @test waitfor(() -> seen("\"result\""))
            @test waitfor(() -> istaskdone(server_task), 5)
            @test isempty(server.listen_subscriptions.subs)
        finally
            server.active = false
            ModelContextProtocol.close(transport)
            timer = Timer(2)
            while !(istaskdone(server_task) && istaskdone(listen_task)) && isopen(timer)
                sleep(0.1)
            end
            Base.close(timer)
        end

        # The listener must have ended cleanly (or with a teardown IO error) — a
        # logic error must fail the test, not vanish into a blanket catch
        @test istaskdone(listen_task)
        @test listen_err[] === nothing ||
              listen_err[] isa Union{EOFError,Base.IOError,HTTP.Exceptions.RequestError,HTTP.Exceptions.HTTPError}
    end

    @testset "Accept media-range matching for SSE" begin
        ok = ModelContextProtocol.accepts_sse
        @test ok("text/event-stream")
        @test ok("application/json, text/event-stream")
        @test ok("TEXT/EVENT-STREAM")                       # case-insensitive
        @test ok("text/event-stream; charset=utf-8")        # params stripped
        @test ok("text/*")
        @test ok("*/*")
        @test ok("text/event-stream;q=0.5")
        @test !ok("text/event-stream;q=0")                  # q=0 is a refusal
        @test !ok("text/event-stream; q=0.0, application/json")
        @test !ok("application/x-text/event-stream")        # different media type
        @test !ok("application/json")
        @test !ok("")
        # The MOST SPECIFIC matching range decides (RFC 9110 precedence)
        @test !ok("text/event-stream;q=0, text/*;q=1")      # exact refusal beats wildcard
        @test !ok("text/*;q=0, */*;q=1")
        @test ok("text/event-stream, text/*;q=0")           # exact acceptance beats wildcard refusal
        @test ok("text/event-stream;q=0, text/event-stream")  # equal specificity: acceptance wins
        # Separators inside quoted parameter values do not split ranges/params
        @test !ok("text/event-stream;profile=\"a,b\";q=0")  # quoted comma: still ONE refused range
        @test ok("text/event-stream;profile=\"a;q=0\"")     # quoted semicolon: q was never set
    end

    @testset "HttpTransport keepalive validation" begin
        # Inf/NaN would silently disable dead-peer detection; non-positive busy-writes
        @test_throws ArgumentError HttpTransport(port = 18995, sse_keepalive_secs = 0)
        @test_throws ArgumentError HttpTransport(port = 18995, sse_keepalive_secs = -1.0)
        @test_throws ArgumentError HttpTransport(port = 18995, sse_keepalive_secs = Inf)
        @test_throws ArgumentError HttpTransport(port = 18995, sse_keepalive_secs = NaN)
        # Validation applies to the CONVERTED Float64: a subnormal BigFloat is
        # finite and positive but would store as 0.0 (and a huge one as Inf)
        @test_throws ArgumentError HttpTransport(port = 18995, sse_keepalive_secs = big"1e-10000")
        @test_throws ArgumentError HttpTransport(port = 18995, sse_keepalive_secs = big"1e10000")
        @test HttpTransport(port = 18995, sse_keepalive_secs = 0.5).sse_keepalive_secs == 0.5
    end

    @testset "SEP-2243 header value decoding (strict)" begin
        dec = ModelContextProtocol.decode_mcp_header_value
        @test dec("plain-value") == "plain-value"
        @test dec("=?base64?" * Base64.base64encode("Hello, 世界") * "?=") == "Hello, 世界"
        # Strictness: Julia's decoder would accept all of these
        @test dec("=?base64?SGVsbG8?=") === nothing        # missing padding
        @test dec("=?base64?SGVs!!!bG8=?=") === nothing    # invalid characters
        @test dec("=?base64??=") === nothing               # empty payload
        @test dec("=?base64?é?=") === nothing              # non-ASCII payload (no throw)
        @test dec("=?base64?/w==?=") === nothing           # decodes to invalid UTF-8
        # Sentinel-shaped literal that is valid base64 of a sentinel: decodes once
        @test dec("=?base64?" * Base64.base64encode("=?base64?x?=") * "?=") == "=?base64?x?="

        hs = ModelContextProtocol.mcp_standard_header
        req = HTTP.Request("POST", "/", ["Mcp-Method" => "tools/list"])
        @test hs(req, "Mcp-Method") == "tools/list"
        @test hs(req, "mcp-method") == "tools/list"        # case-insensitive name
        @test hs(req, "Mcp-Name") === nothing
        req2 = HTTP.Request("POST", "/", ["Mcp-Method" => "a", "MCP-METHOD" => "b"])
        @test hs(req2, "Mcp-Method") === :invalid          # duplicates rejected
        req3 = HTTP.Request("POST", "/", ["Mcp-Name" => "foo\tbar"])
        @test hs(req3, "Mcp-Name") == "foo\tbar"           # tab is legal in values
        # HTTP.jl's client-side Request constructor rejects NUL, but the SERVER
        # parser admits it (verified against HTTP.Messages.readheaders) — push the
        # raw pair to model what a hostile client can actually deliver
        req4 = HTTP.Request("POST", "/")
        push!(req4.headers, "Mcp-Name" => "foo\0bar")
        @test hs(req4, "Mcp-Name") === :invalid            # NUL rejected
    end

    @testset "Origin Validation" begin
        port = 14090 + rand(1:1000)
        
        # Create transport with restricted origins
        transport = HttpTransport(
            port=port,
            allowed_origins=["http://localhost:3000", "http://127.0.0.1:3000"]
        )
        
        server = mcp_server(
            name = "origin-test",
            version = "1.0.0"
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        
        server_task = @async start!(server)
        sleep(2)
        
        # Request with allowed origin
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "Origin" => "http://localhost:3000",
             "MCP-Protocol-Version" => "2025-06-18",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        
        @test response.status == 200
        
        # Request with disallowed origin
        try
            response = HTTP.post(
                "http://127.0.0.1:$port/",
                ["Content-Type" => "application/json",
                 "Origin" => "http://evil.com",
                 "MCP-Protocol-Version" => "2025-06-18",
                 "Accept" => "application/json, text/event-stream"],
                JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "method" => "initialize",
                    "params" => Dict(
                        "protocolVersion" => "2025-06-18",
                        "capabilities" => Dict(),
                        "clientInfo" => Dict("name" => "test", "version" => "1.0")
                    ),
                    "id" => 2
                ))
            )
            @test response.status == 403
        catch e
            if e isa HTTP.ExceptionRequest.StatusError
                @test e.response.status == 403
            else
                # Rethrow unexpected errors
                rethrow(e)
            end
        end
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
    
    @testset "Protocol Version Negotiation" begin
        # Per MCP spec: version negotiation happens at the JSON-RPC level.
        # If the client requests a version we support, the server echoes it back;
        # otherwise it responds with its latest supported version.

        port = 15090 + rand(1:1000)

        transport = HttpTransport(port=port)

        server = mcp_server(
            name = "version-test",
            version = "1.0.0"
        )

        server.transport = transport
        ModelContextProtocol.connect(transport)

        server_task = @async start!(server)
        sleep(2)

        # Test 1: Client requests the latest supported version; server echoes it back
        init_response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-11-25",  # Client sends newer version
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-11-25",  # Client requests newer version
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        @test init_response.status == 200
        result = JSON3.read(String(init_response.body))
        @test haskey(result, "result")
        # Server echoes back the negotiated (supported) version
        @test result["result"]["protocolVersion"] == "2025-11-25"

        session_id = HTTP.header(init_response, "Mcp-Session-Id", "")

        # Test 2: Client requests an older but still-supported version; server echoes it
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2024-11-05",  # Older version header
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2024-11-05",  # Older version
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 2
            ))
        )
        @test response.status == 200
        result = JSON3.read(String(response.body))
        @test haskey(result, "result")
        # Server echoes back the negotiated (older, supported) version
        @test result["result"]["protocolVersion"] == "2024-11-05"

        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)

        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
    
    @testset "Multiple Concurrent Requests" begin
        port = 16090 + rand(1:1000)
        
        transport = HttpTransport(port=port)
        
        # Create a slow tool to test concurrency
        slow_tool = MCPTool(
            name = "slow_tool",
            description = "Slow tool",
            handler = function(params)
                delay = get(params, "delay", 0.1)
                sleep(delay)
                return TextContent(text = "Done after $(delay)s")
            end,
            parameters = [
                ToolParameter(
                    name = "delay",
                    type = "number",
                    description = "Delay in seconds",
                    required = false
                )
            ]
        )
        
        server = mcp_server(
            name = "concurrent-test",
            version = "1.0.0",
            tools = [slow_tool]
        )
        
        server.transport = transport
        ModelContextProtocol.connect(transport)
        
        server_task = @async start!(server)
        sleep(2)
        
        # Initialize
        response = HTTP.post(
            "http://127.0.0.1:$port/",
            ["Content-Type" => "application/json",
             "MCP-Protocol-Version" => "2025-06-18",
             "Accept" => "application/json, text/event-stream"],
            JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => Dict(),
                    "clientInfo" => Dict("name" => "test", "version" => "1.0")
                ),
                "id" => 1
            ))
        )
        
        session_id = HTTP.header(response, "Mcp-Session-Id", "")
        
        # Send multiple concurrent requests
        tasks = []
        for i in 1:3
            task = @async begin
                response = HTTP.post(
                    "http://127.0.0.1:$port/",
                    ["Content-Type" => "application/json",
                     "Mcp-Session-Id" => session_id,
                     "Accept" => "application/json, text/event-stream"],
                    JSON3.write(Dict(
                        "jsonrpc" => "2.0",
                        "method" => "tools/call",
                        "params" => Dict(
                            "name" => "slow_tool",
                            "arguments" => Dict("delay" => 0.1)
                        ),
                        "id" => i + 1
                    ))
                )
                JSON3.read(String(response.body))
            end
            push!(tasks, task)
        end
        
        # Wait for all responses
        results = [fetch(task) for task in tasks]
        
        # All should succeed
        for (i, result) in enumerate(results)
            @test result["id"] == i + 1
            @test haskey(result, "result")
            @test result["result"]["content"][1]["text"] == "Done after 0.1s"
        end
        
        # Clean up
        server.active = false
        ModelContextProtocol.close(transport)
        
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end

    @testset "A response sent before the body is read leaves its connection usable" begin
        # The 403/404/405/415 answers (and the health check) are sent without the
        # request being processed. Its body must still be read, or the server drops
        # the connection and a client that pools connections loses its next request
        # ("other side closed"). The read is bounded in bytes and in time; past
        # either bound the response says `Connection: close` and the server closes.
        port = 19090 + rand(1001:2000)
        transport = HttpTransport(port = port)
        server = mcp_server(name = "reject-early", version = "1.0.0")
        server.transport = transport
        ModelContextProtocol.connect(transport)
        server_task = @async start!(server)
        sleep(2)

        body = """{"jsonrpc":"2.0","id":1,"method":"ping"}"""
        host = "127.0.0.1:$port"
        head(method, path, headers) =
            "$method $path HTTP/1.1\r\n" * join(("$k: $v\r\n" for (k, v) in headers)) * "\r\n"
        request(method, path, headers, payload) =
            head(method, path, vcat(headers, ["Content-Length" => string(ncodeunits(payload))])) * payload
        good = request("POST", "/", ["Host" => host, "Content-Type" => "application/json",
                                     "Accept" => "application/json, text/event-stream"], body)
        # Write `parts` in order on ONE connection (a Real is a pause in seconds) and
        # collect what comes back until `want` responses arrived, the server closed
        # the connection, or `wait` seconds passed.
        # Returns (received text, whether the server closed, seconds until done).
        function exchange(parts...; want = 2, wait = 5, to = port)
            sock = HTTP.Sockets.connect("127.0.0.1", to)
            received = IOBuffer()
            reader = @async try
                while !eof(sock)
                    write(received, readavailable(sock))
                end
            catch
            end
            started = time()
            for part in parts
                part isa Real ? sleep(part) : try
                    write(sock, part)
                catch
                end
            end
            seen() = String(copy(received.data[1:received.size]))
            timer = Timer(wait)
            while isopen(timer) && !istaskdone(reader) &&
                  length(collect(eachmatch(r"HTTP/1\.1 [2-5]\d\d", seen()))) < want
                sleep(0.02)
            end
            sleep(0.1)  # let a close that follows the last response show
            elapsed = time() - started
            closed = istaskdone(reader)
            Base.close(timer); Base.close(sock)
            String(take!(received)), closed, elapsed
        end
        statuses(text) = [m.match[10:12] for m in eachmatch(r"HTTP/1\.1 [2-5]\d\d", text)]
        json = ["Host" => host, "Content-Type" => "application/json"]
        text_plain = ["Host" => host, "Content-Type" => "text/plain"]

        # Each early response, with a body, followed by a good request on the same
        # connection: both are answered, and the connection is not closed
        early = [
            ("415", request("POST", "/", text_plain, body)),
            ("404", request("POST", "/elsewhere", json, body)),
            ("404", request("GET", "/.well-known/oauth-protected-resource", json, body)),
            ("405", request("PUT", "/", json, body)),
            ("403", request("POST", "/", ["Host" => "evil.example", "Content-Type" => "application/json"], body)),
            ("200", request("GET", "/", json, body)),   # the health check
            # no body at all, and an empty one
            ("415", head("POST", "/", text_plain)),
            ("415", request("POST", "/", text_plain, "")),
            # a chunked body, and an empty chunked body
            ("415", head("POST", "/", vcat(text_plain, ["Transfer-Encoding" => "chunked"])) *
                    "5\r\nhello\r\n3\r\nabc\r\n0\r\n\r\n"),
            ("415", head("POST", "/", vcat(text_plain, ["Transfer-Encoding" => "chunked"])) * "0\r\n\r\n"),
            # a body of exactly the most that is read, with a declared length and
            # chunked (where the terminating chunk comes after the last byte allowed)
            ("415", request("POST", "/", text_plain, "x"^(1024 * 1024))),
            ("415", head("POST", "/", vcat(text_plain, ["Transfer-Encoding" => "chunked"])) *
                    "80000\r\n" * "x"^(512 * 1024) * "\r\n80000\r\n" * "y"^(512 * 1024) * "\r\n0\r\n\r\n"),
        ]
        for (status, first) in early
            responses, closed, _ = exchange(first, 0.3, good)
            @test statuses(responses) == [status, "200"]
            @test !closed
            @test !occursin(r"(?i)\r\nconnection: close", responses)
            @test occursin("\"id\":1", responses)
        end

        # After `Expect: 100-continue` every early response is still a complete
        # response: a status line and headers, not a bare body
        for (status, path, headers) in (("404", "/elsewhere", json), ("415", "/", text_plain))
            first = request("POST", path, vcat(headers, ["Expect" => "100-continue"]), body)
            responses, closed, _ = exchange(first, 0.3, good)
            @test occursin("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 $status", responses)
            @test statuses(responses) == [status, "200"]
            @test occursin(r"(?i)HTTP/1\.1 404[^\r]*\r\n(?:[^\r]+\r\n)*content-length: 9\r\n", responses) ||
                  status != "404"
        end

        # A body over the limit is not read: the response comes at once, says the
        # connection will close, and the server closes it. Nothing after it is served.
        over = request("POST", "/", text_plain, "x"^(1024 * 1024 + 1))
        responses, closed, elapsed = exchange(over, good; want = 2, wait = 4)
        @test statuses(responses) == ["415"]
        @test occursin(r"(?i)\r\nconnection: close\r\n", responses)
        @test closed
        @test elapsed < 4
        # A chunked body one byte over the limit is given up on in the same way
        chunked_over = head("POST", "/", vcat(text_plain, ["Transfer-Encoding" => "chunked"])) *
                       "100001\r\n" * "x"^(1024 * 1024 + 1) * "\r\n0\r\n\r\n"
        responses, closed, _ = exchange(chunked_over, good; want = 2, wait = 4)
        @test statuses(responses) == ["415"]
        @test occursin(r"(?i)\r\nconnection: close\r\n", responses)
        @test closed
        # ...and an ordinary client sees that as a normal 415
        r = HTTP.post("http://127.0.0.1:$port/", ["Content-Type" => "text/plain"], "x"^(2 * 1024 * 1024);
                      status_exception = false, retry = false)
        @test r.status == 415
        @test lowercase(HTTP.header(r, "Connection", "")) == "close"

        # A body that never arrives does not hold the connection open: after the
        # time bound the client gets its answer and the server closes. Meanwhile
        # other connections are served.
        stalled = head("POST", "/", vcat(text_plain, ["Content-Length" => "100"]))
        stalled_result = @async exchange(stalled; want = 1, wait = 12)
        sleep(0.5)
        url = "http://127.0.0.1:$port/"
        ok_headers = ["Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"]
        t0 = time()
        @test HTTP.post(url, ok_headers, body; status_exception = false, retry = false).status == 200
        @test time() - t0 < 2
        responses, closed, elapsed = fetch(stalled_result)
        @test statuses(responses) == ["415"]
        @test occursin(r"(?i)\r\nconnection: close\r\n", responses)
        @test closed
        @test 4 < elapsed < 9

        # The 401 of a server that requires a bearer token: the path a remote
        # deployment meets from every client that has not signed in yet
        auth_port = port + 1
        validator = ModelContextProtocol.SimpleTokenValidator()
        add_token!(validator, "sk-good", ModelContextProtocol.AuthenticatedUser(
            subject = "u", provider = "api_key", username = "u"))
        auth_transport = HttpTransport(port = auth_port, auth = ModelContextProtocol.AuthMiddleware(
            config = ModelContextProtocol.OAuthConfig(issuer = "local", audience = "local"),
            validator = validator))
        auth_server = mcp_server(name = "reject-early-auth", version = "1.0.0")
        auth_server.transport = auth_transport
        ModelContextProtocol.connect(auth_transport)
        auth_task = @async start!(auth_server)
        sleep(2)
        auth_host = "127.0.0.1:$auth_port"
        signed(token) = request("POST", "/", ["Host" => auth_host, "Content-Type" => "application/json",
                                             "Accept" => "application/json, text/event-stream",
                                             "Authorization" => "Bearer $token"], body)
        unsigned = request("POST", "/", ["Host" => auth_host, "Content-Type" => "application/json"], body)
        for first in (unsigned, signed("sk-wrong"))
            responses, closed, _ = exchange(first, 0.3, signed("sk-good"); to = auth_port)
            @test statuses(responses) == ["401", "200"]
            @test !closed
            @test occursin(r"(?i)\r\nwww-authenticate: Bearer", responses)
        end
        auth_server.active = false
        ModelContextProtocol.close(auth_transport)

        # A pooling client: rejected and good requests alternating
        for _ in 1:20
            @test HTTP.post(url, ["Content-Type" => "text/plain"], body;
                            status_exception = false, retry = false).status == 415
            @test HTTP.post(url, ok_headers, body; status_exception = false, retry = false).status == 200
        end

        server.active = false
        ModelContextProtocol.close(transport)
        timer = Timer(2)
        while !istaskdone(server_task) && isopen(timer)
            sleep(0.1)
        end
        Base.close(timer)
    end
end

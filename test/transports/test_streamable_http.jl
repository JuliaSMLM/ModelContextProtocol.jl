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
end
# test/protocol/test_param_headers.jl
#
# SEP-2243 custom-header parameter mirroring (x-mcp-header): a tool schema may
# annotate a parameter with an `x-mcp-header` suffix; modern HTTP clients mirror
# that argument as an `Mcp-Param-<suffix>` request header, and the server
# validates the mirror against the body — strict Base64 sentinel decoding,
# literal fallback, and rejection (-32020 → HTTP 400) when the header is
# missing, malformed, duplicated, or mismatched. The transport collects the
# headers (`collect_param_headers`) and threads them to the handler through the
# request context; stdio (no headers) skips the validation entirely.
# No `using` here by convention — runtests.jl provides the imports.

function _ph_server()
    tools = [
        MCPTool(
            name = "routed",
            description = "d",
            parameters = [
                ToolParameter(name = "routing_key", description = "d",
                              type = "string", required = true, header = "Routing-Key"),
                ToolParameter(name = "level", description = "d",
                              type = "number", header = "Level"),
                ToolParameter(name = "plain", description = "d", type = "string"),
            ],
            handler = args -> TextContent(text = "ok: $(args["routing_key"])")),
        MCPTool(
            name = "raw_routed",
            description = "d",
            input_schema = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "shard" => Dict{String,Any}("type" => "string",
                                                "x-mcp-header" => "Shard")),
                "required" => ["shard"]),
            handler = args -> TextContent(text = "raw ok")),
        MCPTool(
            name = "unannotated",
            description = "d",
            parameters = [ToolParameter(name = "x", description = "d", type = "string")],
            handler = args -> TextContent(text = "un ok")),
    ]
    server = mcp_server(name = "ph-test", version = "0.0.1", tools = tools)
    server.transport = StdioTransport(input = IOBuffer(), output = IOBuffer())
    (server, ServerState())
end

const _PH_META = Dict{String,Any}(
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => Dict{String,Any}(),
)

function _ph_call(server, state, name, arguments; headers = Dict{String,Any}(), id = 1)
    r = process_message(server, state, JSON3.write(
            Dict("jsonrpc" => "2.0", "id" => id, "method" => "tools/call",
                 "params" => Dict("name" => name, "arguments" => arguments,
                                  "_meta" => _PH_META)));
        param_headers = headers)
    task_local_storage(:mcp_suppress_log_notifications, false)
    JSON3.read(r)
end

_ph_b64(s) = Base64.base64encode(s)

@testset "SEP-2243 parameter mirroring (x-mcp-header)" begin

    @testset "schema emits the annotation" begin
        server, state = _ph_server()
        r = process_message(server, state, JSON3.write(
            Dict("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list",
                 "params" => Dict("_meta" => _PH_META))))
        task_local_storage(:mcp_suppress_log_notifications, false)
        tools = JSON3.read(r)["result"]["tools"]
        routed = first(t for t in tools if t["name"] == "routed")
        @test routed["inputSchema"]["properties"]["routing_key"]["x-mcp-header"] == "Routing-Key"
        @test !haskey(routed["inputSchema"]["properties"]["plain"], "x-mcp-header")
    end

    @testset "matching mirrors accept: literal, sentinel, number, raw schema" begin
        server, state = _ph_server()
        # Literal value
        r = _ph_call(server, state, "routed", Dict("routing_key" => "east-1");
                     headers = Dict{String,Any}("routing-key" => "east-1"))
        @test r["result"]["content"][1]["text"] == "ok: east-1"

        # Base64 sentinel decodes before comparison
        r2 = _ph_call(server, state, "routed", Dict("routing_key" => "Hello");
                      headers = Dict{String,Any}("routing-key" => "=?base64?$(_ph_b64("Hello"))?="),
                      id = 2)
        @test haskey(r2, "result")

        # A missing-prefix / missing-suffix value is a LITERAL, not Base64
        b64 = _ph_b64("Hello")
        for lit in (b64, "=?base64?$(b64)")
            rl = _ph_call(server, state, "routed", Dict("routing_key" => lit);
                          headers = Dict{String,Any}("routing-key" => lit), id = 3)
            @test haskey(rl, "result")
        end

        # Non-string annotated params compare through their string form; the
        # unannotated param needs no header
        r3 = _ph_call(server, state, "routed",
                      Dict("routing_key" => "e", "level" => 0, "plain" => "p");
                      headers = Dict{String,Any}("routing-key" => "e", "level" => "0"),
                      id = 4)
        @test haskey(r3, "result")

        # Raw input_schema annotations validate identically
        r4 = _ph_call(server, state, "raw_routed", Dict("shard" => "s1");
                      headers = Dict{String,Any}("shard" => "s1"), id = 5)
        @test haskey(r4, "result")
    end

    @testset "violations are -32020" begin
        server, state = _ph_server()
        cases = [
            # header omitted while the annotated value is in the body
            (Dict("routing_key" => "east-1"), Dict{String,Any}()),
            # mismatch
            (Dict("routing_key" => "east-1"), Dict{String,Any}("routing-key" => "west-2")),
            # wrapped with invalid Base64 padding (length not a multiple of 4)
            (Dict("routing_key" => "Hello"), Dict{String,Any}("routing-key" => "=?base64?SGVsbG8?=")),
            # wrapped with non-alphabet characters
            (Dict("routing_key" => "Hello"), Dict{String,Any}("routing-key" => "=?base64?SGVs!!!bG8=?=")),
            # duplicated/unsafe header (transport marks :invalid)
            (Dict("routing_key" => "east-1"), Dict{String,Any}("routing-key" => :invalid)),
        ]
        for (args, headers) in cases
            r = _ph_call(server, state, "routed", args; headers = headers)
            @test r["error"]["code"] == -32020
            @test occursin("Mcp-Param-Routing-Key", r["error"]["message"])
        end
        # The -32020 response maps to HTTP 400 at the transport layer
        r = _ph_call(server, state, "routed", Dict("routing_key" => "east-1");
                     headers = Dict{String,Any}())
        @test ModelContextProtocol.modern_error_http_status(JSON3.write(r)) == 400
    end

    @testset "out-of-scope requests skip the validation" begin
        server, state = _ph_server()
        # Annotated param NOT sent: nothing to mirror (defaults/validation are
        # the schema layer's concern, not the header layer's)
        r = _ph_call(server, state, "routed", Dict{String,Any}();
                     headers = Dict{String,Any}())
        @test !haskey(r, "error") || r["error"]["code"] != -32020

        # Extra Mcp-Param headers matching no annotated in-body param are ignored
        r2 = _ph_call(server, state, "unannotated", Dict("x" => "v");
                      headers = Dict{String,Any}("bogus" => "whatever"), id = 2)
        @test haskey(r2, "result")

        # stdio: no headers collected (param_headers === nothing) -> no validation
        r3 = process_message(server, state, JSON3.write(
            Dict("jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
                 "params" => Dict("name" => "routed",
                                  "arguments" => Dict("routing_key" => "east-1"),
                                  "_meta" => _PH_META))))
        task_local_storage(:mcp_suppress_log_notifications, false)
        @test haskey(JSON3.read(r3), "result")

        # Legacy-era sessions are untouched even with headers present
        lstate = ServerState()
        process_message(server, lstate, JSON3.write(
            Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
                 "params" => Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict(),
                                  "clientInfo" => Dict("name" => "l", "version" => "1")))))
        rl = process_message(server, lstate, JSON3.write(
            Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tools/call",
                 "params" => Dict("name" => "routed",
                                  "arguments" => Dict("routing_key" => "east-1"))));
            param_headers = Dict{String,Any}())
        task_local_storage(:mcp_suppress_log_notifications, false)
        @test haskey(JSON3.read(rl), "result")
    end

    @testset "pre-header positional ToolParameter still constructs (Codex r1 B5)" begin
        tp = ToolParameter("v", "d", "string", false, nothing)
        @test tp.header === nothing
        tp2 = ToolParameter("v", "d", "string", true, "x")
        @test tp2.default == "x"
    end

    @testset "nested annotations validate at depth (Codex r1 B2)" begin
        nested = MCPTool(
            name = "nested",
            description = "d",
            input_schema = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "tenant" => Dict{String,Any}(
                        "type" => "object",
                        "properties" => Dict{String,Any}(
                            "id" => Dict{String,Any}("type" => "string",
                                                     "x-mcp-header" => "Tenant"))))),
            handler = args -> TextContent(text = "n ok"))
        server = mcp_server(name = "nested-test", version = "0.0.1", tools = [nested])
        server.transport = StdioTransport(input = IOBuffer(), output = IOBuffer())
        state = ServerState()

        args = Dict("tenant" => Dict("id" => "body-A"))
        # Missing mirror for a nested annotated value
        r = _ph_call(server, state, "nested", args; headers = Dict{String,Any}())
        @test r["error"]["code"] == -32020 && occursin("tenant.id", r["error"]["message"])
        # Mismatch
        r2 = _ph_call(server, state, "nested", args;
                      headers = Dict{String,Any}("tenant" => "header-B"), id = 2)
        @test r2["error"]["code"] == -32020
        # Match
        r3 = _ph_call(server, state, "nested", args;
                      headers = Dict{String,Any}("tenant" => "body-A"), id = 3)
        @test haskey(r3, "result")
        # Explicit null at the leaf: clients omit the header, servers must not expect it
        r4 = _ph_call(server, state, "nested",
                      Dict("tenant" => Dict("id" => nothing));
                      headers = Dict{String,Any}(), id = 4)
        @test !haskey(r4, "error") || r4["error"]["code"] != -32020
    end

    @testset "explicit null and numeric representations (Codex r1 B3+B4)" begin
        server, state = _ph_server()
        # Explicit JSON null: no header expected
        r = _ph_call(server, state, "routed",
                     Dict{String,Any}("routing_key" => "e", "level" => nothing);
                     headers = Dict{String,Any}("routing-key" => "e"))
        @test haskey(r, "result")

        # Numbers compare NUMERICALLY: a JS client's String(1e-7) is "1e-7",
        # Julia would print "1.0e-7" — both must match the same body number
        for hdr in ("1e-7", "0.0000001", "1.0e-7")
            rn = _ph_call(server, state, "routed",
                          Dict{String,Any}("routing_key" => "e", "level" => 1e-7);
                          headers = Dict{String,Any}("routing-key" => "e", "level" => hdr),
                          id = 2)
            @test haskey(rn, "result")
        end
        # A genuinely different number still rejects
        rm = _ph_call(server, state, "routed",
                      Dict{String,Any}("routing_key" => "e", "level" => 1e-7);
                      headers = Dict{String,Any}("routing-key" => "e", "level" => "2e-7"),
                      id = 3)
        @test rm["error"]["code"] == -32020
    end

    @testset "violations reject before the log opt-in can stream (Codex r1 B1)" begin
        server, state = _ph_server()
        # A debug logLevel opt-in must not let a notification precede the -32020:
        # the preflight answers the error as the request's ONLY message
        meta = merge(_PH_META, Dict{String,Any}("io.modelcontextprotocol/logLevel" => "debug"))
        r = process_message(server, state, JSON3.write(
                Dict("jsonrpc" => "2.0", "id" => 9, "method" => "tools/call",
                     "params" => Dict("name" => "routed",
                                      "arguments" => Dict("routing_key" => "east-1"),
                                      "_meta" => meta)));
            param_headers = Dict{String,Any}())
        task_local_storage(:mcp_suppress_log_notifications, false)
        @test JSON3.read(r)["error"]["code"] == -32020
    end

    @testset "invalid suffixes are refused at registration (Codex r1 W1)" begin
        bad_token = MCPTool(name = "bt", description = "d",
            parameters = [ToolParameter(name = "a", description = "d", type = "string",
                                        header = "no spaces")],
            handler = args -> TextContent(text = "x"))
        empty_sfx = MCPTool(name = "es", description = "d",
            parameters = [ToolParameter(name = "a", description = "d", type = "string",
                                        header = "")],
            handler = args -> TextContent(text = "x"))
        colliding = MCPTool(name = "cc", description = "d",
            parameters = [ToolParameter(name = "a", description = "d", type = "string",
                                        header = "Route"),
                          ToolParameter(name = "b", description = "d", type = "string",
                                        header = "route")],
            handler = args -> TextContent(text = "x"))
        for tool in (bad_token, empty_sfx, colliding)
            @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
                                                  tools = [tool])
        end

        # Bounded violation messages: schema-controlled names cannot inflate the
        # -32020 envelope past the transport's small-error sniff cap
        long_name = "p" ^ 5000
        long_tool = MCPTool(name = "long", description = "d",
            input_schema = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    long_name => Dict{String,Any}("type" => "string",
                                                  "x-mcp-header" => "L"))),
            handler = args -> TextContent(text = "x"))
        server = mcp_server(name = "long-test", version = "0.0.1", tools = [long_tool])
        server.transport = StdioTransport(input = IOBuffer(), output = IOBuffer())
        state = ServerState()
        r = _ph_call(server, state, "long", Dict(long_name => "v");
                     headers = Dict{String,Any}())
        @test r["error"]["code"] == -32020
        @test ncodeunits(r["error"]["message"]) < 1000
        @test ModelContextProtocol.modern_error_http_status(JSON3.write(r)) == 400
    end

    @testset "exact integer mirrors and constrained number syntax (Codex r2 B1)" begin
        server, state = _ph_server()
        base = Dict{String,Any}("routing_key" => "e")
        hdr(level) = Dict{String,Any}("routing-key" => "e", "level" => level)

        # Integers compare EXACTLY: a Float64 round-trip would collapse values
        # beyond 2^53
        big_body = Dict{String,Any}(base..., "level" => 9007199254740993)
        @test haskey(_ph_call(server, state, "routed", big_body;
                              headers = hdr("9007199254740993")), "result")
        r = _ph_call(server, state, "routed", big_body;
                     headers = hdr("9007199254740992"), id = 2)
        @test r["error"]["code"] == -32020

        # Julia-parseable exotica are NOT valid mirrors: hex, Inf, NaN
        int_body = Dict{String,Any}(base..., "level" => 16)
        @test _ph_call(server, state, "routed", int_body;
                       headers = hdr("0x10"), id = 3)["error"]["code"] == -32020
        @test haskey(_ph_call(server, state, "routed", int_body;
                              headers = hdr("16"), id = 4), "result")
        float_body = Dict{String,Any}(base..., "level" => 1.5)
        for bad in ("Inf", "NaN", "0x1.8p0")
            @test _ph_call(server, state, "routed", float_body;
                           headers = hdr(bad), id = 5)["error"]["code"] == -32020
        end
    end

    @testset "huge request ids cannot demote 400 to 200 (Codex r2 B2)" begin
        # An error envelope whose echoed id blows past the small-payload parse
        # must still map: the structural sniff reads the code regardless of size
        long_id = "i" ^ 5000
        for (code, want) in ((-32020, 400), (-32021, 400), (-32022, 400), (-32601, 404))
            # Through the REAL serializer: the sniff keys on its stable field order
            payload = ModelContextProtocol.serialize_message(ModelContextProtocol.JSONRPCError(
                id = long_id,
                error = ModelContextProtocol.ErrorInfo(code = code, message = "m")))
            @test ncodeunits(payload) > 4096
            @test ModelContextProtocol.modern_error_http_status(payload) == want
        end
        # A large SUCCESS payload whose nested data contains error-shaped keys
        # stays 200 (the top-level result key precedes any such nesting), and
        # error-shaped TEXT inside strings serializes escaped, so it never
        # matches the structural needles
        big_success = JSON3.write(Dict{String,Any}(
            "jsonrpc" => "2.0", "id" => 1,
            "result" => Dict{String,Any}(
                "content" => [Dict{String,Any}("type" => "text",
                                               "text" => "x" ^ 5000 * "\"error\":{\"code\":-32020}")],
                "structuredContent" => Dict{String,Any}(
                    "error" => Dict{String,Any}("code" => -32020)))))
        @test ModelContextProtocol.modern_error_http_status(big_success) == 200
    end

    @testset "registration rejects every invalid annotation shape (Codex r2 W1)" begin
        # Trailing newline: PCRE \$ would match before it — \\z anchoring must not
        trailing = MCPTool(name = "tn", description = "d",
            parameters = [ToolParameter(name = "a", description = "d", type = "string",
                                        header = "Route\n")],
            handler = args -> TextContent(text = "x"))
        # Non-string annotation value in a raw schema
        nonstring = MCPTool(name = "ns", description = "d",
            input_schema = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "a" => Dict{String,Any}("type" => "string", "x-mcp-header" => 17))),
            handler = args -> TextContent(text = "x"))
        # Annotation under an array's items: unsatisfiable, must be refused
        under_items = MCPTool(name = "ui", description = "d",
            input_schema = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "list" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}(
                            "type" => "object",
                            "properties" => Dict{String,Any}(
                                "id" => Dict{String,Any}("type" => "string",
                                                         "x-mcp-header" => "Id")))))),
            handler = args -> TextContent(text = "x"))
        for tool in (trailing, nonstring, under_items)
            @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
                                                  tools = [tool])
        end
    end

    @testset "collect_param_headers gathers, strips, and flags" begin
        mk(headers) = HTTP.Request("POST", "/", headers, "")
        h = ModelContextProtocol.collect_param_headers(mk(
            ["Mcp-Param-Routing-Key" => "  east-1  ",
             "MCP-PARAM-LEVEL" => "0",
             "Content-Type" => "application/json"]))
        @test h["routing-key"] == "east-1"  # OWS stripped, suffix lowercased
        @test h["level"] == "0"
        @test length(h) == 2

        # Duplicates flag :invalid (unsafe control bytes are additionally flagged
        # in collect_param_headers as defense-in-depth, but HTTP.jl already
        # refuses to construct such headers, so that path cannot be fabricated)
        hd = ModelContextProtocol.collect_param_headers(mk(
            ["Mcp-Param-X" => "a", "mcp-param-x" => "b"]))
        @test hd["x"] === :invalid
    end
end

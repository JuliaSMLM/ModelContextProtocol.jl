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
                              type = "integer", header = "Level"),
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

    @testset "exact integer mirrors and constrained number syntax (Codex r2 B1 + r3 B1)" begin
        server, state = _ph_server()
        base = Dict{String,Any}("routing_key" => "e")
        hdr(level) = Dict{String,Any}("routing-key" => "e", "level" => level)

        # Integers beyond the JavaScript-safe range cannot be mirrored at all
        # (SEP-2243) — whatever the header says
        big_body = Dict{String,Any}(base..., "level" => 9007199254740993)
        for h in ("9007199254740993", "9007199254740992")
            r = _ph_call(server, state, "routed", big_body; headers = hdr(h))
            @test r["error"]["code"] == -32020
            @test occursin("JavaScript-safe", r["error"]["message"])
        end
        # The safe-range boundary compares EXACTLY (never through Float64)
        max_safe = Dict{String,Any}(base..., "level" => 9007199254740991)
        @test haskey(_ph_call(server, state, "routed", max_safe;
                              headers = hdr("9007199254740991"), id = 2), "result")
        @test _ph_call(server, state, "routed", max_safe;
                       headers = hdr("9007199254740990"), id = 3)["error"]["code"] == -32020

        # JSON3 normalizes integral tokens (42.0, 1e3) to Int64 — every JSON
        # spelling of the same integer is a valid mirror, compared exactly
        for (body, goods, bads) in (
            (Dict{String,Any}(base..., "level" => 42.0), ("42", "42.0", "4.2e1"), ("42.5", "43")),
            (Dict{String,Any}(base..., "level" => 1e3), ("1e3", "1000", "1.0e3"), ("1e4",)),
            (Dict{String,Any}(base..., "level" => -0.0), ("-0.0", "0"), ()),
        )
            for g in goods
                @test haskey(_ph_call(server, state, "routed", body;
                                      headers = hdr(g), id = 4), "result")
            end
            for b in bads
                @test _ph_call(server, state, "routed", body;
                               headers = hdr(b), id = 5)["error"]["code"] == -32020
            end
        end

        # Julia-parseable exotica are NOT valid mirrors: hex, Inf, NaN
        int_body = Dict{String,Any}(base..., "level" => 16)
        @test _ph_call(server, state, "routed", int_body;
                       headers = hdr("0x10"), id = 6)["error"]["code"] == -32020
        @test haskey(_ph_call(server, state, "routed", int_body;
                              headers = hdr("16"), id = 7), "result")
        float_body = Dict{String,Any}(base..., "level" => 1.5)
        for bad in ("Inf", "NaN", "0x1.8p0")
            @test _ph_call(server, state, "routed", float_body;
                           headers = hdr(bad), id = 8)["error"]["code"] == -32020
        end
        # A gigadigit exponent must not allocate: rejected by the exponent cap
        @test _ph_call(server, state, "routed", int_body;
                       headers = hdr("16e999999"), id = 9)["error"]["code"] == -32020
    end

    @testset "annotatable types and reachability at registration (Codex r3 B2)" begin
        mk(schema) = MCPTool(name = "t", description = "d", input_schema = schema,
                             handler = args -> TextContent(text = "x"))
        # number is spec-excluded; objects/missing types likewise
        for t in ("number", "object", nothing)
            props = Dict{String,Any}("a" => Dict{String,Any}("x-mcp-header" => "A"))
            t === nothing || (props["a"]["type"] = t)
            @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
                tools = [mk(Dict{String,Any}("type" => "object", "properties" => props))])
        end
        # ToolParameter path enforces the same constraint
        @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
            tools = [MCPTool(name = "np", description = "d",
                parameters = [ToolParameter(name = "a", description = "d",
                                            type = "number", header = "A")],
                handler = args -> TextContent(text = "x"))])
        # An annotation directly ON an items node (not one of its properties)
        @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
            tools = [mk(Dict{String,Any}("type" => "object",
                "properties" => Dict{String,Any}(
                    "list" => Dict{String,Any}(
                        "type" => "array",
                        "items" => Dict{String,Any}("type" => "string",
                                                    "x-mcp-header" => "Id")))))])
        # Composition branches are not statically reachable
        @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
            tools = [mk(Dict{String,Any}("type" => "object",
                "anyOf" => [Dict{String,Any}(
                    "properties" => Dict{String,Any}(
                        "a" => Dict{String,Any}("type" => "string",
                                                "x-mcp-header" => "A")))]))])
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

    @testset "Float64-fallback integers and exponent overflows (Codex r4 B1+B2)" begin
        server, state = _ph_server()
        base = Dict{String,Any}("routing_key" => "e")
        hdr(level) = Dict{String,Any}("routing-key" => "e", "level" => level)

        # Integer tokens beyond Int64 arrive as Float64 from JSON3 — the
        # JavaScript-safe range check must catch integral floats too, or
        # 9223372036854775808 and ...809 would collapse in the float compare
        huge = Dict{String,Any}(base..., "level" => Int128(9223372036854775808))
        for h in ("9223372036854775808", "9223372036854775809")
            r = _ph_call(server, state, "routed", huge; headers = hdr(h))
            @test r["error"]["code"] == -32020
            @test occursin("JavaScript-safe", r["error"]["message"])
        end
        r2 = _ph_call(server, state, "routed", Dict{String,Any}(base..., "level" => 1e20);
                      headers = hdr("1e20"), id = 2)
        @test r2["error"]["code"] == -32020

        # Oversized exponent lexemes are a MISMATCH (-32020), never a thrown
        # OverflowError surfacing as -32603/HTTP 200
        int_body = Dict{String,Any}(base..., "level" => 16)
        for h in ("1e999999999999999999999999999999", "1e-9223372036854775808")
            r3 = _ph_call(server, state, "routed", int_body; headers = hdr(h), id = 3)
            @test r3["error"]["code"] == -32020
        end
    end

    @testset "every non-properties schema path rejects annotations (Codex r4 B3)" begin
        mk(schema) = MCPTool(name = "t", description = "d", input_schema = schema,
                             handler = args -> TextContent(text = "x"))
        annotated = Dict{String,Any}("type" => "string", "x-mcp-header" => "A")
        inner = Dict{String,Any}("type" => "object",
                                 "properties" => Dict{String,Any}("a" => annotated))
        # The deep scan catches annotations under ANY schema-valued keyword —
        # including ones no keyword blacklist would have listed
        for wrap in (
            Dict{String,Any}("if" => inner),
            Dict{String,Any}("then" => inner),
            Dict{String,Any}("else" => inner),
            Dict{String,Any}("contains" => copy(annotated)),
            Dict{String,Any}("dependentSchemas" => Dict{String,Any}("x" => inner)),
            Dict{String,Any}("propertyNames" => copy(annotated)),
            Dict{String,Any}("unevaluatedProperties" => copy(annotated)),
            Dict{String,Any}("additionalItems" => copy(annotated)),
            Dict{String,Any}("someFutureKeyword" => inner),
        )
            schema = merge(Dict{String,Any}("type" => "object"), wrap)
            @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
                                                  tools = [mk(schema)])
        end
        # Pure properties chains (at depth) remain valid
        ok = Dict{String,Any}("type" => "object",
            "properties" => Dict{String,Any}(
                "outer" => Dict{String,Any}(
                    "type" => "object",
                    "properties" => Dict{String,Any}(
                        "a" => Dict{String,Any}("type" => "string",
                                                "x-mcp-header" => "A")))))
        @test mcp_server(name = "v", version = "0.0.1", tools = [mk(ok)]) isa Any
    end

    @testset "context-aware scan: data keys, containers, aliasing (Codex r5)" begin
        mk(schema) = MCPTool(name = "t", description = "d", input_schema = schema,
                             handler = args -> TextContent(text = "x"))

        # A property NAMED x-mcp-header is an ordinary argument, not an
        # annotation — and instance-data keywords may contain the key freely
        named = Dict{String,Any}("type" => "object",
            "properties" => Dict{String,Any}(
                "x-mcp-header" => Dict{String,Any}("type" => "string")))
        @test mcp_server(name = "v", version = "0.0.1", tools = [mk(named)]) isa Any
        for data_key in ("default", "const", "examples")
            payload = data_key == "examples" ?
                Any[Dict{String,Any}("x-mcp-header" => "X")] :
                Dict{String,Any}("x-mcp-header" => "X")
            s = Dict{String,Any}("type" => "object",
                "properties" => Dict{String,Any}(
                    "a" => Dict{String,Any}("type" => "object", data_key => payload)))
            @test mcp_server(name = "v", version = "0.0.1", tools = [mk(s)]) isa Any
        end

        # Serialization-equivalent containers cannot smuggle annotations:
        # JSON3 emits Tuples and Sets as arrays, and the normalized walk sees
        # exactly the advertised JSON
        annotated = Dict{String,Any}("type" => "string", "x-mcp-header" => "A")
        tup = Dict{String,Any}("type" => "object",
            "anyOf" => (Dict{String,Any}(
                "properties" => Dict{String,Any}("a" => copy(annotated))),))
        @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
                                              tools = [mk(tup)])

        # An aliased subschema straddling a reachable and an unreachable
        # position is caught: normalization duplicates it into a proper tree
        shared = Dict{String,Any}("type" => "string", "x-mcp-header" => "A")
        aliased = Dict{String,Any}("type" => "object",
            "properties" => Dict{String,Any}(
                "a" => shared,
                "list" => Dict{String,Any}("type" => "array", "items" => shared)))
        @test_throws ArgumentError mcp_server(name = "v", version = "0.0.1",
                                              tools = [mk(aliased)])
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

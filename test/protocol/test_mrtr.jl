@testset "MRTR input_required (2026-07-28)" begin
    mmeta(caps) = Dict("io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                       "io.modelcontextprotocol/clientCapabilities" => caps)

    @testset "construction rules" begin
        # Only the three spec-blessed request types exist
        @test elicit_request("Q?").method == "elicitation/create"
        @test elicit_request("Q?"; requested_schema = Dict("type" => "object")).params["requestedSchema"]["type"] == "object"
        @test sampling_request(Dict("maxTokens" => 4)).method == "sampling/createMessage"
        @test roots_request().method == "roots/list"
        @test_throws ArgumentError ModelContextProtocol.InputRequest("tools/list", nothing)
        # An InputRequired must carry at least one request or a state, and only
        # InputRequest values
        @test_throws ArgumentError InputRequired(Dict{String,Any}())
        @test_throws ArgumentError InputRequired(Dict("k" => "not-a-request"))
        @test InputRequired(Dict{String,Any}(); state = Dict("x" => 1)).state["x"] == 1
    end

    @testset "capability requirements" begin
        req = ModelContextProtocol.undeclared_capability_requirements
        ir = InputRequired(Dict("a" => elicit_request("Q?"),
                                "b" => sampling_request(Dict("maxTokens" => 4))))
        r = req(ir, Dict())
        @test haskey(r, "elicitation") && haskey(r, "sampling")
        @test r["elicitation"]["form"] isa AbstractDict  # mode-precise requirement
        @test collect(keys(req(ir, Dict("elicitation" => Dict())))) == ["sampling"]
        @test isempty(req(ir, Dict("elicitation" => Dict(), "sampling" => Dict())))
        # A non-object capabilities value declares nothing
        @test length(req(ir, "junk")) == 2
        # A null/scalar capability VALUE declares nothing either
        @test haskey(req(ir, Dict("sampling" => nothing, "elicitation" => Dict())), "sampling")
        @test haskey(req(ir, Dict("sampling" => true, "elicitation" => Dict())), "sampling")
        # Elicitation modes are honored: url-only does NOT cover a form request...
        e = InputRequired(Dict("a" => elicit_request("Q?")))
        @test haskey(req(e, Dict("elicitation" => Dict("url" => Dict()))), "elicitation")
        # ...form (alone or alongside url) does, as does a modeless declaration
        @test isempty(req(e, Dict("elicitation" => Dict("form" => Dict()))))
        @test isempty(req(e, Dict("elicitation" => Dict("form" => Dict(), "url" => Dict()))))
        @test isempty(req(e, Dict("elicitation" => Dict())))
        # A PRESENT-but-null mode is not an absent mode: form: null declares no
        # form support (only the empty elicitation object implies it)
        @test haskey(req(e, Dict("elicitation" => Dict("form" => nothing))), "elicitation")
        @test haskey(req(e, Dict("elicitation" => Dict("url" => nothing))), "elicitation")
        # ...and ONLY the bare empty object implies form: an unknown future mode
        # set excludes it too
        @test haskey(req(e, Dict("elicitation" => Dict("futureMode" => Dict()))), "elicitation")

        # Tool-enabled sampling needs sampling.tools, not just sampling
        st = InputRequired(Dict("s" => sampling_request(Dict(
            "maxTokens" => 4, "tools" => [Dict("name" => "t")]))))
        r = req(st, Dict("sampling" => Dict()))
        @test r["sampling"]["tools"] isa AbstractDict  # requirement names the subfeature
        @test isempty(req(st, Dict("sampling" => Dict("tools" => Dict()))))
        @test haskey(req(st, Dict("sampling" => Dict("tools" => nothing))), "sampling")
        # toolChoice alone is also tool-enabled sampling (the schema ties both
        # fields to sampling.tools)
        tc = InputRequired(Dict("s" => sampling_request(Dict(
            "maxTokens" => 4, "toolChoice" => Dict("mode" => "none")))))
        @test req(tc, Dict("sampling" => Dict()))["sampling"]["tools"] isa AbstractDict
        @test isempty(req(tc, Dict("sampling" => Dict("tools" => Dict()))))
        # Plain sampling stays satisfied by a bare object...
        sp = InputRequired(Dict("s" => sampling_request(Dict("maxTokens" => 4))))
        @test isempty(req(sp, Dict("sampling" => Dict())))
        # ...and a mixed plain+tool set with nothing declared requires the superset
        mixed = InputRequired(Dict("p" => sampling_request(Dict("maxTokens" => 4)),
                                   "t" => sampling_request(Dict("maxTokens" => 4,
                                                                "tools" => Any[]))))
        @test req(mixed, Dict())["sampling"]["tools"] isa AbstractDict
    end

    @testset "canonical params digest" begin
        dig = ModelContextProtocol.canonical_json_digest
        # Key order must not matter, values must
        @test dig(Dict("a" => 1, "b" => Dict("c" => 2, "d" => 3))) ==
              dig(Dict("b" => Dict("d" => 3, "c" => 2), "a" => 1))
        @test dig(Dict("a" => 1)) != dig(Dict("a" => 2))
        @test dig(Dict("a" => [1, 2])) != dig(Dict("a" => [2, 1]))
    end

    @testset "requestState tokens" begin
        issue = ModelContextProtocol.issue_request_state
        verify = ModelContextProtocol.verify_request_state
        server = mcp_server(name = "state-t", version = "1.0.0")
        tok = issue(server, "tools/call", "digest-1", "alice", Dict("step" => 2))
        ok, st = verify(server, tok, "tools/call", "digest-1", "alice")
        @test ok && st["step"] == 2
        # Every binding is enforced: signature, principal, METHOD, digest
        @test !verify(server, tok * "x", "tools/call", "digest-1", "alice")[1]
        @test !verify(server, tok, "tools/call", "digest-1", "mallory")[1]
        @test !verify(server, tok, "prompts/get", "digest-1", "alice")[1]  # cross-method confusion
        @test !verify(server, tok, "tools/call", "digest-2", "alice")[1]
        @test !verify(server, "garbage", "tools/call", "digest-1", "alice")[1]
        # Another server's random key cannot verify it...
        other = mcp_server(name = "state-o", version = "1.0.0")
        @test !verify(other, tok, "tools/call", "digest-1", "alice")[1]
        # ...but a deployment-shared key makes retries survive re-routing
        key = rand(UInt8, 32)
        a = mcp_server(name = "replica-a", version = "1.0.0", mrtr_state_key = key)
        b = mcp_server(name = "replica-b", version = "1.0.0", mrtr_state_key = key)
        tok2 = issue(a, "tools/call", "d", "", nothing)
        @test verify(b, tok2, "tools/call", "d", "")[1]
        @test_throws ArgumentError mcp_server(name = "short-key", version = "1.0.0",
                                              mrtr_state_key = rand(UInt8, 16))
        # Expiry: a hand-signed payload with an old iat is rejected
        old = JSON3.write(Dict("v" => 2, "iat" => round(Int, time()) - 10_000, "ttl" => 600,
                               "sub" => "alice", "mth" => "tools/call",
                               "dig" => "digest-1", "st" => nothing))
        mac = ModelContextProtocol.hmac_sha256(server.mrtr_state_key, old)
        expired = string(Base64.base64encode(old), ".", Base64.base64encode(mac))
        okx, why = verify(server, expired, "tools/call", "digest-1", "alice")
        @test !okx && occursin("expired", why)
        # Format versioning: a v1 (pre-provider-qualified-principal) token is
        # rejected as "unsupported version", never as a principal mismatch
        v1 = JSON3.write(Dict("v" => 1, "iat" => round(Int, time()), "ttl" => 600,
                              "sub" => "alice", "mth" => "tools/call",
                              "dig" => "digest-1", "st" => nothing))
        mac1 = ModelContextProtocol.hmac_sha256(server.mrtr_state_key, v1)
        v1tok = string(Base64.base64encode(v1), ".", Base64.base64encode(mac1))
        okv, whyv = verify(server, v1tok, "tools/call", "digest-1", "alice")
        @test !okv && occursin("version", whyv)
    end

    @testset "wire flow: elicit, retry, complete" begin
        executions = Ref(0)
        tool = MCPTool(name = "confirm_tool", description = "d", parameters = ToolParameter[],
            handler = (args, ctx) -> begin
                executions[] += 1
                resp = get(input_responses(ctx), "confirm", nothing)
                resp === nothing && return InputRequired(
                    Dict("confirm" => elicit_request("Really?")); state = Dict("n" => 41))
                TextContent(text = "answer=$(resp["action"]) carried=$(input_state(ctx)["n"] + 1)")
            end)
        server = mcp_server(name = "mrtr-wire", version = "1.0.0", tools = [tool])
        state = ServerState()
        call(id, params) = JSON3.read(process_message(server, state, JSON3.write(Dict(
            "jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => params))))

        # Undeclared capability -> -32021 with requiredCapabilities as an OBJECT
        r = call(1, Dict("name" => "confirm_tool", "arguments" => Dict(), "_meta" => mmeta(Dict())))
        @test r["error"]["code"] == -32021
        @test r["error"]["data"]["requiredCapabilities"]["elicitation"] isa JSON3.Object

        # Declared -> InputRequiredResult with the full envelope, including the
        # REQUIRED (and defaulted) object schema on the form elicitation
        caps = Dict("elicitation" => Dict())
        r = call(2, Dict("name" => "confirm_tool", "arguments" => Dict(), "_meta" => mmeta(caps)))
        @test r["result"]["resultType"] == "input_required"
        @test r["result"]["inputRequests"]["confirm"]["method"] == "elicitation/create"
        @test r["result"]["inputRequests"]["confirm"]["params"]["message"] == "Really?"
        schema = r["result"]["inputRequests"]["confirm"]["params"]["requestedSchema"]
        @test schema["type"] == "object" && haskey(schema, "properties")
        @test haskey(r["result"]["_meta"], "io.modelcontextprotocol/serverInfo")
        tok = r["result"]["requestState"]
        @test tok isa String && !isempty(tok)

        # Retry with the response and echoed state -> complete, with carried state
        r = call(3, Dict("name" => "confirm_tool", "arguments" => Dict(), "_meta" => mmeta(caps),
                         "inputResponses" => Dict("confirm" => Dict("action" => "accept")),
                         "requestState" => tok))
        @test r["result"]["resultType"] == "complete"
        @test occursin("answer=accept carried=42", JSON3.write(r["result"]))

        # Retry with the state but WITHOUT the response -> re-issue, not error
        r = call(4, Dict("name" => "confirm_tool", "arguments" => Dict(), "_meta" => mmeta(caps),
                         "requestState" => tok))
        @test r["result"]["resultType"] == "input_required"

        # Tampered state -> -32602 before the handler runs
        r = call(5, Dict("name" => "confirm_tool", "arguments" => Dict(), "_meta" => mmeta(caps),
                         "inputResponses" => Dict("confirm" => Dict("action" => "accept")),
                         "requestState" => tok * "x"))
        @test r["error"]["code"] == -32602

        # Changed arguments break the params-digest binding -> -32602
        r = call(6, Dict("name" => "confirm_tool", "arguments" => Dict("x" => 1),
                         "_meta" => mmeta(caps),
                         "inputResponses" => Dict("confirm" => Dict("action" => "accept")),
                         "requestState" => tok))
        @test r["error"]["code"] == -32602

        # A PRESENT but mistyped retry field must be rejected BEFORE the handler
        # runs — a numeric requestState must not bypass verification, and a scalar
        # inputResponses must not silently re-elicit
        before = executions[]
        for bad_state in (7, [1, 2], Dict("a" => 1), nothing)
            r = call(7, Dict("name" => "confirm_tool", "arguments" => Dict(),
                             "_meta" => mmeta(caps),
                             "inputResponses" => Dict("confirm" => Dict("action" => "accept")),
                             "requestState" => bad_state))
            @test r["error"]["code"] == -32602
        end
        r = call(8, Dict("name" => "confirm_tool", "arguments" => Dict(),
                         "_meta" => mmeta(caps), "inputResponses" => "junk"))
        @test r["error"]["code"] == -32602
        @test executions[] == before  # the handler never ran for any of them
        task_local_storage(:mcp_suppress_log_notifications, false)
    end

    @testset "legacy sessions cannot receive input_required" begin
        tool = MCPTool(name = "legacy_elicit", description = "d", parameters = ToolParameter[],
            handler = (args, ctx) -> InputRequired(Dict("q" => elicit_request("Q?"))))
        server = mcp_server(name = "mrtr-legacy", version = "1.0.0", tools = [tool])
        # A legacy ctx has no per-request protocol version
        ctx = RequestContext(server = server, request_id = 1)
        result = ModelContextProtocol.handle_call_tool(ctx,
            CallToolParams(name = "legacy_elicit", arguments = Dict{String,Any}()))
        @test result.error !== nothing
        @test result.error.code == -32600
        @test occursin("input_required", result.error.message)
    end

    @testset "URL-mode elicitation: construction" begin
        r = elicit_url_request("Connect your account", "https://example.com/connect?flow=1")
        @test r.method == "elicitation/create"
        @test r.params["mode"] == "url"
        @test r.params["message"] == "Connect your account"
        @test r.params["url"] == "https://example.com/connect?flow=1"
        # The 2026-07-28 URL shape is mode + message + url: no schema, no elicitationId
        @test sort(collect(keys(r.params))) == ["message", "mode", "url"]
        @test elicit_url_request("m", "http://127.0.0.1:8080/x").params["url"] == "http://127.0.0.1:8080/x"
        # _meta rides along on both modes when given, and is absent otherwise
        @test elicit_url_request("m", "https://e.com/"; _meta = Dict("k" => 1)).params["_meta"]["k"] == 1
        @test elicit_request("Q?"; _meta = Dict("k" => 2)).params["_meta"]["k"] == 2
        @test !haskey(elicit_request("Q?").params, "_meta")
        # Not a valid absolute http(s) URL, or one carrying credentials -> refused.
        # Every string here fails RFC 3986 as written (or is not http(s)): spaces,
        # quotes, brackets outside an IP literal, non-ASCII, bad percent escapes,
        # bad ports, malformed IPv6, a second "#", userinfo
        for bad in ("not a url", "/relative/path", "ftp://example.com/x", "example.com",
                    "https://", "https://user:secret@example.com/", "https://@example.com/",
                    "javascript:alert(1)", "https://bad host/path", "https://example.org:abc/x",
                    "https://example.org:99999/", "https://example.org/a b",
                    "https://example.org/\"x\"", "https://example.org/<x>", "https://example.org/\n",
                    "https://ex\u00e4mple.org/", "https://example.org/" * Char(0x202e),
                    "https://[:::]/", "https://[zz]/", "https://[::1/", "https://[1:2:3:4:5:6:7]/",
                    "https://[v7.fe80::1]/", "https://foo.example/%ZZ", "https://foo.example/%4",
                    "https://example.org/a[b]", "https://example.org/#a#b", "https://example.org/{id}",
                    "https://example.org/?q=a|b", "https://example.org\\x", "https://..", "https://-/",
                    # a multibyte character inside brackets, a port out of range
                    # however it is spelled, an escaped "/" or non-ASCII in the
                    # host, and a numeric host that is not an IPv4 address
                    "https://[\u00e9]/", "https://example.org:065536/", "https://bad%2fhost.example/",
                    "https://ex%C3%A4mple.org/", "https://999.999.999.999/", "https://1.2.3/",
                    "https://example.0x10/", "https://example.org/?filter[status]=open")
            @test_throws ArgumentError elicit_url_request("m", bad)
        end
        # ...while ordinary forms pass unchanged: ports, IPv4 and IPv6 literals,
        # queries, fragments, percent-encoding (in the host too), underscores
        for good in ("https://example.org", "https://example.org:8443/a/b?x=1&y=%20#frag",
                     "http://localhost:3000/cb", "http://[::1]:8080/x", "https://[2001:db8::1]/",
                     "https://[::ffff:192.168.1.1]/", "https://192.168.1.1/", "https://a.b-c.example./",
                     "https://exa%6dple.org/", "https://exa_mple.org/", "https://example.org/@x:y",
                     "HTTPS://Example.ORG/a;b=c/~d?q=a/b?c#f/g?h",
                     "https://example.org:000443/cb", "https://127.0.0.1./", "https://a1.example/",
                     "https://example.org:/", "https://example.org/?filter%5Bstatus%5D=open")
            @test elicit_url_request("m", good).params["url"] == good
        end
        # A message of any string type is taken
        @test elicit_url_request(SubString("Open it now", 1, 7), "https://e.com/").params["message"] == "Open it"
        @test elicit_request(SubString("Q? extra", 1, 2)).params["message"] == "Q?"
        # _meta is an object or absent
        @test_throws ArgumentError elicit_url_request("m", "https://e.com/"; _meta = 3)
        @test_throws ArgumentError elicit_request("Q?"; _meta = [1])
    end

    @testset "URL-mode elicitation: capability requirements" begin
        sat = ModelContextProtocol.capability_satisfied
        req = ModelContextProtocol.undeclared_capability_requirements
        url = elicit_url_request("m", "https://example.com/x")
        form = elicit_request("Q?")
        # url needs its own declared key: the bare object implies form only
        @test sat(Dict("elicitation" => Dict("url" => Dict())), url)
        @test sat(Dict("elicitation" => Dict("form" => Dict(), "url" => Dict())), url)
        @test !sat(Dict("elicitation" => Dict()), url)
        @test !sat(Dict("elicitation" => Dict("form" => Dict())), url)
        @test !sat(Dict("elicitation" => Dict("url" => nothing)), url)
        @test !sat(Dict("elicitation" => Dict("url" => true)), url)
        @test !sat(Dict(), url)
        @test !sat(nothing, url)
        # Symbol-keyed (parsed-JSON) capabilities behave the same
        @test sat(Dict(:elicitation => Dict(:url => Dict())), url)
        # The requirement names the missing mode, and merges when both are missing
        only_url = InputRequired(Dict("u" => url))
        @test req(only_url, Dict("elicitation" => Dict()))["elicitation"] ==
              Dict("url" => Dict())
        @test collect(keys(req(only_url, Dict("elicitation" => Dict("form" => Dict())))["elicitation"])) == ["url"]
        @test isempty(req(only_url, Dict("elicitation" => Dict("url" => Dict()))))
        both = InputRequired(Dict("u" => url, "f" => form))
        @test sort(collect(keys(req(both, Dict())["elicitation"]))) == ["form", "url"]
        @test collect(keys(req(both, Dict("elicitation" => Dict("url" => Dict())))["elicitation"])) == ["form"]
        @test isempty(req(both, Dict("elicitation" => Dict("form" => Dict(), "url" => Dict()))))
        # A hand-built request is validated once, at construction: only an ABSENT
        # mode means form, and a present one must be "form" or "url"
        IR = ModelContextProtocol.InputRequest
        for bad_mode in ("voice", 7, nothing, "URL", ["url"])
            @test_throws ArgumentError IR("elicitation/create", Dict("mode" => bad_mode, "message" => "m"))
            @test_throws ArgumentError IR("elicitation/create", Dict(:mode => bad_mode, :message => "m"))
        end
        # Params are a dictionary (or absent), never a shape the key lookups cannot
        # see: a NamedTuple would serialize as URL mode but be checked as form
        @test_throws ArgumentError IR("elicitation/create",
            (mode = "url", message = "Open", url = "https://example.org/"))
        @test_throws ArgumentError IR("elicitation/create", nothing)
        @test_throws ArgumentError IR("sampling/createMessage", (maxTokens = 4, tools = []))
        @test IR("roots/list", nothing).params === nothing
        # A hand-built request is complete for its mode, and names each field once
        @test_throws ArgumentError IR("elicitation/create", Dict("mode" => "url", "message" => "m"))
        @test_throws ArgumentError IR("elicitation/create", Dict("mode" => "url", "url" => "https://e.org/"))
        @test_throws ArgumentError IR("elicitation/create", Dict("message" => "m"))  # form without a schema
        @test_throws ArgumentError IR("elicitation/create", Dict("mode" => "form", "message" => 7,
                                                                "requestedSchema" => Dict()))
        @test_throws ArgumentError IR("elicitation/create", LittleDict{Any,Any}(
            "mode" => "form", :mode => "url", "message" => "m", "url" => "https://e.org/",
            "requestedSchema" => Dict()))
        @test_throws ArgumentError IR("sampling/createMessage", Dict(1 => 2))
        # A hand-built URL request passes the same URL check as the helper
        @test_throws ArgumentError IR("elicitation/create",
            Dict("mode" => "url", "message" => "m", "url" => "not a url"))
        @test_throws ArgumentError IR("elicitation/create",
            Dict("mode" => "url", "message" => "m", "url" => "https://user:pw@e.org/"))
        # The request owns its params: changing the caller's dictionary afterwards
        # changes neither what is checked nor what is sent
        mine = Dict{String,Any}("message" => "m", "requestedSchema" => Dict("type" => "object", "properties" => Dict()))
        built = IR("elicitation/create", mine)
        mine["mode"] = "typo"; mine["message"] = "changed"
        @test !haskey(built.params, "mode") && built.params["message"] == "m"
        @test sat(Dict("elicitation" => Dict()), built)
        @test all(k -> k isa String, keys(IR("sampling/createMessage", Dict(:maxTokens => 4, :messages => [])).params))
        # An explicit mode: "form" is form; a hand-built url request is url, with
        # String or Symbol keys
        explicit = IR("elicitation/create",
            Dict("mode" => "form", "message" => "m",
                 "requestedSchema" => Dict("type" => "object", "properties" => Dict())))
        @test sat(Dict("elicitation" => Dict()), explicit)
        for hand in (IR("elicitation/create", Dict("mode" => "url", "message" => "m", "url" => "https://e.org/")),
                     IR("elicitation/create", Dict(:mode => "url", :message => "m", :url => "https://e.org/")))
            @test sat(Dict("elicitation" => Dict("url" => Dict())), hand)
            @test !sat(Dict("elicitation" => Dict("form" => Dict())), hand)
            @test collect(keys(req(InputRequired(Dict("h" => hand)), Dict("elicitation" => Dict()))["elicitation"])) == ["url"]
        end
    end

    @testset "URL-mode elicitation: wire flow and client_supports" begin
        tool = MCPTool(name = "connect", description = "d", parameters = ToolParameter[],
            handler = (args, ctx) -> begin
                resp = get(input_responses(ctx), "connect", nothing)
                resp === nothing && return InputRequired(Dict("connect" =>
                    elicit_url_request("Connect your account", "https://example.com/connect")))
                TextContent(text = "action=$(resp["action"]) content=$(haskey(resp, "content"))")
            end)
        # A handler that adapts to what the client declared
        adaptive = MCPTool(name = "adaptive", description = "d", parameters = ToolParameter[],
            handler = (args, ctx) -> begin
                isempty(input_responses(ctx)) || return TextContent(text = "done")
                url = elicit_url_request("Open the page", "https://example.com/p")
                form = elicit_request("Type it here")
                client_supports(ctx, url) && return InputRequired(Dict("via_url" => url))
                client_supports(ctx, form) && return InputRequired(Dict("via_form" => form))
                TextContent(text = "this client cannot be asked")
            end)
        server = mcp_server(name = "mrtr-url", version = "1.0.0", tools = [tool, adaptive])
        state = ServerState()
        call(id, params) = JSON3.read(process_message(server, state, JSON3.write(Dict(
            "jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => params))))
        form_only = Dict("elicitation" => Dict("form" => Dict()))
        bare = Dict("elicitation" => Dict())
        both = Dict("elicitation" => Dict("form" => Dict(), "url" => Dict()))

        # A form-only (or bare) client is refused with the precise requirement
        for caps in (form_only, bare, Dict())
            r = call(1, Dict("name" => "connect", "arguments" => Dict(), "_meta" => mmeta(caps)))
            @test r["error"]["code"] == -32021
            @test haskey(r["error"]["data"]["requiredCapabilities"]["elicitation"], "url")
            @test !haskey(r["error"]["data"]["requiredCapabilities"]["elicitation"], "form")
        end

        # A request changed after it was built is checked and sent as ONE snapshot:
        # a mode the client was never asked about cannot reach the wire
        for (name, tamper) in (
                ("voice", r -> (r.params["mode"] = "voice")),
                ("bad-url", r -> (r.params["mode"] = "url"; r.params["url"] = "not a url")),
                ("unserializable", r -> (r.params["requestedSchema"] = Dict("x" => Inf))))
            register!(server, MCPTool(name = "tampered-$name", description = "t", parameters = [],
                handler = (args, ctx) -> begin
                    r = elicit_request("q")
                    tamper(r)
                    InputRequired(Dict("q" => r))
                end))
            r = call(7, Dict("name" => "tampered-$name", "arguments" => Dict(), "_meta" => mmeta(form_only)))
            @test r["error"]["code"] == -32603
            @test occursin("invalid input request", r["error"]["message"])
        end
        # ...while a request switched to URL mode properly is judged as a URL request
        register!(server, MCPTool(name = "switched", description = "t", parameters = [],
            handler = (args, ctx) -> begin
                r = elicit_request("q")
                delete!(r.params, "requestedSchema")
                r.params["mode"] = "url"; r.params["url"] = "https://example.com/x"
                InputRequired(Dict("q" => r))
            end))
        r = call(8, Dict("name" => "switched", "arguments" => Dict(), "_meta" => mmeta(form_only)))
        @test r["error"]["code"] == -32021
        @test haskey(r["error"]["data"]["requiredCapabilities"]["elicitation"], "url")
        r = call(9, Dict("name" => "switched", "arguments" => Dict(), "_meta" => mmeta(both)))
        @test r["result"]["inputRequests"]["q"]["params"]["mode"] == "url"

        # A url-capable client gets the URL request, then completes on accept
        r = call(2, Dict("name" => "connect", "arguments" => Dict(), "_meta" => mmeta(both)))
        @test r["result"]["resultType"] == "input_required"
        p = r["result"]["inputRequests"]["connect"]["params"]
        @test p["mode"] == "url" && p["url"] == "https://example.com/connect"
        @test p["message"] == "Connect your account"
        @test !haskey(p, "requestedSchema")
        r = call(3, Dict("name" => "connect", "arguments" => Dict(), "_meta" => mmeta(both),
                         "inputResponses" => Dict("connect" => Dict("action" => "accept")),
                         "requestState" => r["result"]["requestState"]))
        @test r["result"]["resultType"] == "complete"
        @test occursin("action=accept", JSON3.write(r["result"]))

        # client_supports lets the handler choose per client
        r = call(4, Dict("name" => "adaptive", "arguments" => Dict(), "_meta" => mmeta(both)))
        @test collect(keys(r["result"]["inputRequests"])) == [:via_url]
        r = call(5, Dict("name" => "adaptive", "arguments" => Dict(), "_meta" => mmeta(form_only)))
        @test collect(keys(r["result"]["inputRequests"])) == [:via_form]
        r = call(6, Dict("name" => "adaptive", "arguments" => Dict(), "_meta" => mmeta(Dict())))
        @test r["result"]["resultType"] == "complete"
        @test occursin("cannot be asked", JSON3.write(r["result"]))

        # On a legacy request nothing can be asked, even with capabilities that
        # would suffice on a modern one (the same capabilities do, with a version)
        legacy = RequestContext(server = server, request_id = 1, client_capabilities = both)
        modern = RequestContext(server = server, request_id = 1, client_capabilities = both,
                                protocol_version = "2026-07-28")
        for ask in (elicit_request("Q?"), elicit_url_request("m", "https://example.com/"))
            @test !client_supports(legacy, ask)
            @test client_supports(modern, ask)
        end

        # URL mode also works from a detached task's mid-task input
        @test ModelContextProtocol.capability_satisfied(both,
            ModelContextProtocol._frozen_input_request(elicit_url_request("m", "https://example.com/")))
        task_local_storage(:mcp_suppress_log_notifications, false)
    end

    @testset "prompt handlers" begin
        calls = Ref(0)
        asking = MCPPrompt(name = "asking", description = "asks first",
            handler = (args, ctx) -> begin
                calls[] += 1
                resp = get(input_responses(ctx), "topic", nothing)
                resp === nothing && return InputRequired(
                    Dict("topic" => elicit_request("Which topic?")); state = Dict("n" => 1))
                "Write about $(resp["content"]["topic"]) for $(get(args, "who", "anyone")) (state $(input_state(ctx)["n"]))"
            end,
            arguments = [PromptArgument(name = "who")])
        plain = MCPPrompt(name = "plain", description = "one-argument handler",
            arguments = [PromptArgument(name = "x", required = true)],
            messages = [PromptMessage(content = TextContent(text = "template is ignored"))],
            handler = args -> [
                PromptMessage(content = TextContent(text = "system-ish"), role = assistant),
                "x is $(args["x"])",
                ImageContent(data = UInt8[1, 2, 3], mime_type = "image/png")])
        broken = MCPPrompt(name = "broken", handler = args -> 42)
        throws = MCPPrompt(name = "throws", handler = args -> error("boom"))
        server = mcp_server(name = "prompt-handlers", version = "1.0.0",
                            prompts = [asking, plain, broken, throws])
        state = ServerState()
        get_prompt(id, params) = JSON3.read(process_message(server, state, JSON3.write(Dict(
            "jsonrpc" => "2.0", "id" => id, "method" => "prompts/get", "params" => params))))
        caps = Dict("elicitation" => Dict())

        # Modern: InputRequired from prompts/get, then the retry completes
        r = get_prompt(1, Dict("name" => "asking", "arguments" => Dict("who" => "Ada"),
                               "_meta" => mmeta(caps)))
        @test r["result"]["resultType"] == "input_required"
        @test r["result"]["inputRequests"]["topic"]["method"] == "elicitation/create"
        tok = r["result"]["requestState"]
        r = get_prompt(2, Dict("name" => "asking", "arguments" => Dict("who" => "Ada"),
                               "_meta" => mmeta(caps), "requestState" => tok,
                               "inputResponses" => Dict("topic" => Dict(
                                   "action" => "accept", "content" => Dict("topic" => "tides")))))
        @test r["result"]["resultType"] == "complete"
        @test length(r["result"]["messages"]) == 1
        @test r["result"]["messages"][1]["role"] == "user"
        @test r["result"]["messages"][1]["content"]["text"] == "Write about tides for Ada (state 1)"
        @test calls[] == 2  # the handler ran once per round

        # The requestState is bound to the original params, as for tools
        r = get_prompt(3, Dict("name" => "asking", "arguments" => Dict("who" => "Eve"),
                               "_meta" => mmeta(caps), "requestState" => tok,
                               "inputResponses" => Dict("topic" => Dict("action" => "accept"))))
        @test r["error"]["code"] == -32602  # changed arguments break the digest binding

        # An undeclared capability is refused with -32021, as for tools
        r = get_prompt(4, Dict("name" => "asking", "_meta" => mmeta(Dict())))
        @test r["error"]["code"] == -32021

        # A plain handler: mixed return values become messages; the template is unused
        r = get_prompt(5, Dict("name" => "plain", "arguments" => Dict("x" => "7"),
                               "_meta" => mmeta(Dict())))
        msgs = r["result"]["messages"]
        @test [m["role"] for m in msgs] == ["assistant", "user", "user"]
        @test msgs[2]["content"]["text"] == "x is 7"
        @test msgs[3]["content"]["type"] == "image" && msgs[3]["content"]["mimeType"] == "image/png"
        @test !occursin("template is ignored", JSON3.write(r["result"]))
        # ...required arguments are checked before the handler runs, whether
        # `arguments` is empty or omitted
        ran = Ref(0)
        strict = MCPPrompt(name = "strict", arguments = [PromptArgument(name = "x", required = true)],
                           handler = args -> (ran[] += 1; "x is $(args["x"])"))
        # A handler typed on Dict{String,String} gets that type in both cases
        typed = MCPPrompt(name = "typed", handler = (args::Dict{String,String}) -> "n=$(length(args))")
        register!(server, strict); register!(server, typed)
        for params in (Dict("name" => "strict", "arguments" => Dict(), "_meta" => mmeta(Dict())),
                       Dict("name" => "strict", "_meta" => mmeta(Dict())))
            r = get_prompt(6, params)
            @test r["error"]["code"] == -32602
            @test occursin("x", r["error"]["message"])
        end
        @test ran[] == 0
        for params in (Dict("name" => "typed", "arguments" => Dict(), "_meta" => mmeta(Dict())),
                       Dict("name" => "typed", "_meta" => mmeta(Dict())))
            r = get_prompt(6, params)
            @test r["result"]["messages"][1]["content"]["text"] == "n=0"
        end
        # The same rule holds for a static prompt and on a legacy request
        static = MCPPrompt(name = "static", arguments = [PromptArgument(name = "x", required = true)],
                           messages = [PromptMessage(content = TextContent(text = "x={x}"))])
        register!(server, static)
        legacy_ctx = RequestContext(server = server, request_id = 1)
        @test handle_get_prompt(legacy_ctx, GetPromptParams(name = "static")).error.code == -32602
        @test handle_get_prompt(legacy_ctx, GetPromptParams(name = "static",
            arguments = Dict{String,String}())).error.code == -32602
        ok = handle_get_prompt(legacy_ctx, GetPromptParams(name = "static", arguments = Dict("x" => "1")))
        @test ok.response.result["messages"][1]["content"]["text"] == "x=1"

        # A declined or cancelled elicitation reaches the handler as a response
        # without content; the handler decides what the prompt is then
        polite = MCPPrompt(name = "polite", handler = (args, ctx) -> begin
            resp = get(input_responses(ctx), "q", nothing)
            resp === nothing && return InputRequired(Dict("q" => elicit_request("Q?")))
            resp["action"] == "accept" ? "accepted" : "not accepted: $(resp["action"])"
        end)
        register!(server, polite)
        first_round = get_prompt(20, Dict("name" => "polite", "_meta" => mmeta(caps)))
        for action in ("decline", "cancel")
            r = get_prompt(21, Dict("name" => "polite", "_meta" => mmeta(caps),
                                    "requestState" => first_round["result"]["requestState"],
                                    "inputResponses" => Dict("q" => Dict("action" => action))))
            @test r["result"]["messages"][1]["content"]["text"] == "not accepted: $action"
        end

        # Handler mistakes surface as errors, not throws
        register!(server, MCPPrompt(name = "mixed", handler = (args, ctx) ->
            ["text", InputRequired(Dict("q" => elicit_request("Q?")))]))
        for name in ("broken", "throws", "mixed")
            r = get_prompt(7, Dict("name" => name, "_meta" => mmeta(Dict())))
            @test r["error"]["code"] == -32603
        end

        # Legacy: handlers work, but cannot ask for input
        ctx = RequestContext(server = server, request_id = 1)
        result = handle_get_prompt(ctx, GetPromptParams(name = "plain",
                                                       arguments = Dict("x" => "9")))
        @test result.error === nothing
        @test result.response.result["messages"][2]["content"]["text"] == "x is 9"
        result = handle_get_prompt(ctx, GetPromptParams(name = "asking"))
        @test result.error !== nothing && result.error.code == -32600
        @test occursin("input_required", result.error.message)

        # prompts/list never exposes the handler
        listed = JSON3.read(process_message(server, state, JSON3.write(Dict(
            "jsonrpc" => "2.0", "id" => 9, "method" => "prompts/list",
            "params" => Dict("_meta" => mmeta(Dict()))))))
        @test all(!haskey(p, "handler") for p in listed["result"]["prompts"])
        # ...and a prompt's direct JSON form has no handler either: a static
        # prompt serializes exactly as before the field existed, and a handler
        # that captures state does not break serialization
        static_json = JSON3.read(JSON3.write(static))
        @test sort(String.(collect(keys(static_json)))) ==
              ["_meta", "arguments", "completions", "description", "icons", "messages", "name", "title"]
        captured = "state"
        capturing = MCPPrompt(name = "capturing", handler = args -> captured)
        @test !haskey(JSON3.read(JSON3.write(capturing)), "handler")

        # The earlier positional shapes still construct (seven and eight fields)
        p7 = MCPPrompt("n", "d", [], [], nothing, nothing, nothing)
        p8 = MCPPrompt("n", "d", PromptArgument[], PromptMessage[], nothing, nothing, nothing, nothing)
        @test p7.handler === nothing && p8.handler === nothing && p8.completions === nothing
        task_local_storage(:mcp_suppress_log_notifications, false)
    end
end

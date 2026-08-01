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
        ir = InputRequired(Dict("a" => elicit_request("Q?"),
                                "b" => sampling_request(Dict("maxTokens" => 4))))
        @test ModelContextProtocol.missing_capabilities(ir, Dict()) == ["elicitation", "sampling"]
        @test ModelContextProtocol.missing_capabilities(ir, Dict("elicitation" => Dict())) == ["sampling"]
        @test isempty(ModelContextProtocol.missing_capabilities(ir,
            Dict("elicitation" => Dict(), "sampling" => Dict())))
        # A non-object capabilities value declares nothing
        @test ModelContextProtocol.missing_capabilities(ir, "junk") == ["elicitation", "sampling"]
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
        server = mcp_server(name = "state-t", version = "1.0.0")
        tok = ModelContextProtocol.issue_request_state(server, "digest-1", "alice", Dict("step" => 2))
        ok, st = ModelContextProtocol.verify_request_state(server, tok, "digest-1", "alice")
        @test ok && st["step"] == 2
        # Every binding is enforced: signature, principal, digest
        @test !ModelContextProtocol.verify_request_state(server, tok * "x", "digest-1", "alice")[1]
        @test !ModelContextProtocol.verify_request_state(server, tok, "digest-1", "mallory")[1]
        @test !ModelContextProtocol.verify_request_state(server, tok, "digest-2", "alice")[1]
        @test !ModelContextProtocol.verify_request_state(server, "garbage", "digest-1", "alice")[1]
        # Another server's key cannot verify it (ephemeral per-server key)
        other = mcp_server(name = "state-o", version = "1.0.0")
        @test !ModelContextProtocol.verify_request_state(other, tok, "digest-1", "alice")[1]
        # Expiry: a hand-signed payload with an old iat is rejected
        old = JSON3.write(Dict("v" => 1, "iat" => round(Int, time()) - 10_000, "ttl" => 600,
                               "sub" => "alice", "dig" => "digest-1", "st" => nothing))
        mac = ModelContextProtocol.hmac_sha256(server.mrtr_state_key, old)
        expired = string(Base64.base64encode(old), ".", Base64.base64encode(mac))
        okx, why = ModelContextProtocol.verify_request_state(server, expired, "digest-1", "alice")
        @test !okx && occursin("expired", why)
    end

    @testset "wire flow: elicit, retry, complete" begin
        tool = MCPTool(name = "confirm_tool", description = "d", parameters = ToolParameter[],
            handler = (args, ctx) -> begin
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

        # Declared -> InputRequiredResult with the full envelope
        caps = Dict("elicitation" => Dict())
        r = call(2, Dict("name" => "confirm_tool", "arguments" => Dict(), "_meta" => mmeta(caps)))
        @test r["result"]["resultType"] == "input_required"
        @test r["result"]["inputRequests"]["confirm"]["method"] == "elicitation/create"
        @test r["result"]["inputRequests"]["confirm"]["params"]["message"] == "Really?"
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
end

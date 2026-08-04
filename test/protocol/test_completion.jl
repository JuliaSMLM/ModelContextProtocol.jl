# test/protocol/test_completion.jl
#
# completion/complete: argument suggestions for prompt arguments (ref/prompt) and
# resource-template variables (ref/resource), served in both eras — legacy sessions
# (capability advertised as `completions` in the initialize response) and modern
# stateless requests (capability-gated via MODERN_METHODS, advertised by
# server/discover). Sources live on the component's `completions` field: static
# vectors are prefix-filtered, functions are called with the partial value (and
# the request context's resolved arguments when they accept two).
# No `using` here by convention — runtests.jl provides the imports.

function _cmp_server()
    prompts = [
        MCPPrompt(
            name = "cities",
            description = "d",
            arguments = [PromptArgument(name = "city", required = true),
                         PromptArgument(name = "country", required = true)],
            messages = [PromptMessage(content = TextContent(text = "{city} {country}"))],
            completions = Dict{String,Any}(
                "city" => ["paris", "park-city", "london"],
                "country" => (value, context_args) -> begin
                    prefix = context_args isa AbstractDict ?
                        string(get(context_args, "city", "")) : ""
                    ["$(prefix)-$(value)-1", "$(prefix)-$(value)-2"]
                end)),
        MCPPrompt(
            name = "sourceless",
            description = "d",
            arguments = [PromptArgument(name = "x", required = false)],
            messages = [PromptMessage(content = TextContent(text = "x"))]),
        MCPPrompt(
            name = "wide",
            description = "d",
            arguments = [PromptArgument(name = "n", required = false)],
            messages = [PromptMessage(content = TextContent(text = "n"))],
            completions = Dict{String,Any}("n" => ["v$(i)" for i in 1:150])),
    ]
    templates = [
        ResourceTemplate(
            name = "tpl",
            uri_template = "test://items/{id}",
            data_provider = (uri, vars) -> "item",
            completions = Dict{String,Any}("id" => ["1", "10", "42"])),
    ]
    server = mcp_server(name = "completion-test", version = "0.0.1",
                        prompts = prompts, resource_templates = templates)
    server.transport = StdioTransport(input = IOBuffer(), output = IOBuffer())
    (server, ServerState())
end

function _cmp_rpc(server, state, msg)
    r = process_message(server, state, JSON3.write(msg))
    task_local_storage(:mcp_suppress_log_notifications, false)
    r === nothing ? nothing : JSON3.read(r)
end

_cmp_init(server, state) = _cmp_rpc(server, state,
    Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
         "params" => Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict(),
                          "clientInfo" => Dict("name" => "t", "version" => "1"))))

function _cmp_complete(server, state, ref; name = "city", value = "", context = nothing, id = 2, meta = nothing)
    params = Dict{String,Any}("ref" => ref,
                              "argument" => Dict("name" => name, "value" => value))
    context !== nothing && (params["context"] = context)
    meta !== nothing && (params["_meta"] = meta)
    _cmp_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => id,
                                 "method" => "completion/complete", "params" => params))
end

const _CMP_MODERN_META = Dict{String,Any}(
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => Dict{String,Any}(),
)

@testset "completion/complete" begin

    @testset "capability advertisement" begin
        server, state = _cmp_server()
        init = _cmp_init(server, state)
        @test haskey(init["result"]["capabilities"], "completions")

        d = _cmp_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 5,
            "method" => "server/discover",
            "params" => Dict("_meta" => _CMP_MODERN_META)))
        @test haskey(d["result"]["capabilities"], "completions")
    end

    @testset "ref/prompt: static sources filter by prefix" begin
        server, state = _cmp_server()
        _cmp_init(server, state)

        r = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "cities");
                          name = "city", value = "par")
        c = r["result"]["completion"]
        @test c["values"] == ["paris", "park-city"]
        @test c["total"] == 2
        @test c["hasMore"] == false

        # Empty partial value matches everything
        r2 = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "cities");
                           name = "city", value = "", id = 3)
        @test length(r2["result"]["completion"]["values"]) == 3
    end

    @testset "ref/prompt: function sources receive context arguments" begin
        server, state = _cmp_server()
        _cmp_init(server, state)
        r = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "cities");
                          name = "country", value = "fr",
                          context = Dict("arguments" => Dict("city" => "paris")))
        @test r["result"]["completion"]["values"] == ["paris-fr-1", "paris-fr-2"]

        # Without context the function still runs (context_args === nothing)
        r2 = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "cities");
                           name = "country", value = "fr", id = 3)
        @test r2["result"]["completion"]["values"] == ["-fr-1", "-fr-2"]
    end

    @testset "ref/resource: template variables complete" begin
        server, state = _cmp_server()
        _cmp_init(server, state)
        r = _cmp_complete(server, state,
                          Dict("type" => "ref/resource", "uri" => "test://items/{id}");
                          name = "id", value = "1")
        @test r["result"]["completion"]["values"] == ["1", "10"]
    end

    @testset "no source and unknown argument yield empty suggestions" begin
        server, state = _cmp_server()
        _cmp_init(server, state)
        for (prompt, arg) in (("sourceless", "x"), ("cities", "nonexistent"))
            r = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => prompt);
                              name = arg, value = "a")
            c = r["result"]["completion"]
            @test c["values"] == [] && c["total"] == 0 && c["hasMore"] == false
        end
    end

    @testset "values cap at 100 with total and hasMore" begin
        server, state = _cmp_server()
        _cmp_init(server, state)
        r = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "wide");
                          name = "n", value = "v")
        c = r["result"]["completion"]
        @test length(c["values"]) == 100
        @test c["total"] == 150
        @test c["hasMore"] == true
    end

    @testset "unknown refs are -32602" begin
        server, state = _cmp_server()
        _cmp_init(server, state)
        for ref in (Dict("type" => "ref/prompt", "name" => "nope"),
                    Dict("type" => "ref/resource", "uri" => "test://nope/{x}"),
                    Dict("type" => "ref/other", "name" => "cities"),
                    Dict("type" => "ref/prompt"),          # missing name
                    Dict("type" => "ref/resource"))        # missing uri
            r = _cmp_complete(server, state, ref)
            @test r["error"]["code"] == -32602
        end
    end

    @testset "modern era: envelope and capability gating" begin
        server, state = _cmp_server()
        r = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "cities");
                          name = "city", value = "par", meta = _CMP_MODERN_META)
        @test r["result"]["resultType"] == "complete"
        @test r["result"]["completion"]["values"] == ["paris", "park-city"]
        @test !haskey(r["result"], "ttlMs")  # CompleteResult is not a CacheableResult
        @test haskey(r["result"]["_meta"], "io.modelcontextprotocol/serverInfo")

        # Modern malformed params (missing argument) -> -32602
        bad = _cmp_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 9,
            "method" => "completion/complete",
            "params" => Dict("ref" => Dict("type" => "ref/prompt", "name" => "cities"),
                             "_meta" => _CMP_MODERN_META)))
        @test bad["error"]["code"] == -32602

        # Without the completions capability the modern surface has no method
        nocap = mcp_server(name = "nocap", version = "0.0.1",
                           capabilities = ModelContextProtocol.Capability[
                               ModelContextProtocol.PromptCapability()])
        nocap.transport = StdioTransport(input = IOBuffer(), output = IOBuffer())
        rn = _cmp_rpc(nocap, ServerState(),
            Dict("jsonrpc" => "2.0", "id" => 10, "method" => "completion/complete",
                 "params" => Dict("ref" => Dict("type" => "ref/prompt", "name" => "x"),
                                  "argument" => Dict("name" => "a", "value" => ""),
                                  "_meta" => _CMP_MODERN_META)))
        @test rn["error"]["code"] == -32601
    end

    @testset "legacy malformed params are -32602, not internal (Codex r1 W1)" begin
        server, state = _cmp_server()
        _cmp_init(server, state)
        for params in (
            Dict{String,Any}("ref" => Dict("type" => "ref/prompt", "name" => "cities")),  # no argument
            Dict{String,Any}("ref" => "not-an-object",
                             "argument" => Dict("name" => "city", "value" => "")),
            Dict{String,Any}("ref" => Dict("type" => "ref/prompt", "name" => "cities"),
                             "argument" => 5),
        )
            r = _cmp_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 21,
                "method" => "completion/complete", "params" => params))
            @test r["error"]["code"] == -32602
        end

        # The parse-layer guard is SCOPED to completion: other legacy methods
        # keep their pre-existing malformed-params classification — a mistyped
        # cursor must still error, never silently succeed with defaults
        r = _cmp_rpc(server, state, Dict("jsonrpc" => "2.0", "id" => 22,
            "method" => "resources/list", "params" => Dict("cursor" => [1])))
        @test haskey(r, "error") && r["error"]["code"] == -32603
    end

    @testset "context.arguments is validated as an object of strings (Codex r1 W2)" begin
        typed = MCPPrompt(name = "typed", description = "d",
            arguments = [PromptArgument(name = "a", required = false)],
            messages = [PromptMessage(content = TextContent(text = "a"))],
            completions = Dict{String,Any}(
                # A strictly typed two-argument source must be applicable once
                # the context is normalized to Dict{String,String}
                "a" => (value, context::Dict{String,String}) -> ["$(context["prev"])-$(value)"]))
        server = mcp_server(name = "ctx-test", version = "0.0.1",
                            prompts = [typed])
        server.transport = StdioTransport(input = IOBuffer(), output = IOBuffer())
        state = ServerState()
        _cmp_init(server, state)

        ok = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "typed");
                           name = "a", value = "x",
                           context = Dict("arguments" => Dict("prev" => "p")))
        @test ok["result"]["completion"]["values"] == ["p-x"]

        # Mistyped contexts are the client's error — including an explicit JSON
        # null for arguments (presence-aware, never treated as absent)
        for ctx in (Dict("arguments" => 1),
                    Dict("arguments" => Dict("prev" => 5)),
                    Dict("arguments" => ["a"]),
                    Dict("arguments" => nothing))
            r = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "typed");
                              name = "a", value = "x", context = ctx, id = 31)
            @test r["error"]["code"] == -32602
        end
    end

    @testset "misconfigured sources fail loudly, never coerce (Codex r1 N1)" begin
        bad = [
            MCPPrompt(name = "lone", description = "d",
                arguments = [PromptArgument(name = "a", required = false)],
                messages = [PromptMessage(content = TextContent(text = "a"))],
                completions = Dict{String,Any}("a" => v -> "single-string")),
            MCPPrompt(name = "nonstr", description = "d",
                arguments = [PromptArgument(name = "a", required = false)],
                messages = [PromptMessage(content = TextContent(text = "a"))],
                completions = Dict{String,Any}("a" => v -> [42])),
            MCPPrompt(name = "static_nonstr", description = "d",
                arguments = [PromptArgument(name = "a", required = false)],
                messages = [PromptMessage(content = TextContent(text = "a"))],
                completions = Dict{String,Any}("a" => Any["ok", 42])),
            MCPPrompt(name = "scalar_src", description = "d",
                arguments = [PromptArgument(name = "a", required = false)],
                messages = [PromptMessage(content = TextContent(text = "a"))],
                completions = Dict{String,Any}("a" => "not-a-vector")),
            MCPPrompt(name = "nothing_src", description = "d",
                arguments = [PromptArgument(name = "a", required = false)],
                messages = [PromptMessage(content = TextContent(text = "a"))],
                completions = Dict{String,Any}("a" => nothing)),  # configured, not absent
            MCPPrompt(name = "nothing_ret", description = "d",
                arguments = [PromptArgument(name = "a", required = false)],
                messages = [PromptMessage(content = TextContent(text = "a"))],
                completions = Dict{String,Any}("a" => v -> nothing)),
        ]
        server = mcp_server(name = "badsrc-test", version = "0.0.1", prompts = bad)
        server.transport = StdioTransport(input = IOBuffer(), output = IOBuffer())
        state = ServerState()
        _cmp_init(server, state)
        for prompt in ("lone", "nonstr", "static_nonstr", "scalar_src", "nothing_src", "nothing_ret")
            r = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => prompt);
                              name = "a", value = "")
            @test r["error"]["code"] == -32603
            @test occursin("completion source", r["error"]["message"])
        end
    end

    @testset "pre-completions positional constructor shapes still work (Codex r3 W1 + r4 W1)" begin
        p = MCPPrompt("p", "d", PromptArgument[], PromptMessage[], nothing, nothing, nothing)
        @test p.completions === nothing
        t = ResourceTemplate("r", "u://{x}", nothing, "", nothing, nothing, nothing, nothing)
        @test t.completions === nothing

        # The released constructors also CONVERTED — empty untyped vectors,
        # SubString names, narrower dict types — so the shims must be generic
        p2 = MCPPrompt("p", "d", [], [], nothing, nothing, nothing)
        @test p2.arguments isa Vector{PromptArgument} && p2.completions === nothing
        p3 = MCPPrompt(SubString("prompted", 1, 6), "d", PromptArgument[], PromptMessage[],
                       nothing, nothing, Dict("x" => 1))
        @test p3.name == "prompt" && p3._meta["x"] == 1
        t2 = ResourceTemplate("r", "u://{x}", nothing, "", nothing, [], nothing, nothing)
        @test t2.icons isa Vector{MCPIcon} && t2.completions === nothing
    end

    @testset "throwing completion source fails cleanly" begin
        boom = MCPPrompt(name = "boom", description = "d",
            arguments = [PromptArgument(name = "a", required = false)],
            messages = [PromptMessage(content = TextContent(text = "b"))],
            completions = Dict{String,Any}("a" => v -> error("source kaput")))
        server = mcp_server(name = "boom-test", version = "0.0.1", prompts = [boom])
        server.transport = StdioTransport(input = IOBuffer(), output = IOBuffer())
        state = ServerState()
        _cmp_init(server, state)
        r = _cmp_complete(server, state, Dict("type" => "ref/prompt", "name" => "boom");
                          name = "a", value = "")
        @test r["error"]["code"] == -32603
        @test occursin("kaput", r["error"]["message"])
    end
end

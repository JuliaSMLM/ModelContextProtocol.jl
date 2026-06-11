@testset "Authentication Framework" begin
    @testset "AuthenticatedUser" begin
        user = AuthenticatedUser(
            subject = "user123",
            provider = "github",
            username = "testuser",
            scopes = ["read:user", "repo"],
            claims = Dict{String,Any}("email" => "test@example.com")
        )

        @test user.subject == "user123"
        @test user.provider == "github"
        @test user.username == "testuser"
        @test "read:user" in user.scopes
        @test user.claims["email"] == "test@example.com"
    end

    @testset "OAuthConfig" begin
        config = OAuthConfig(
            issuer = "https://github.com",
            audience = "my-mcp-server",
            required_scopes = ["read:user"]
        )

        @test config.issuer == "https://github.com"
        @test config.audience == "my-mcp-server"
        @test "read:user" in config.required_scopes
    end

    @testset "AuthResult" begin
        # Success result
        user = AuthenticatedUser(subject = "test", provider = "test")
        success = AuthResult(user)
        @test success.success == true
        @test success.user.subject == "test"
        @test isnothing(success.error)

        # Error result
        failure = AuthResult("Invalid token", :invalid_token)
        @test failure.success == false
        @test isnothing(failure.user)
        @test failure.error == "Invalid token"
        @test failure.error_code == :invalid_token
    end

    @testset "extract_bearer_token" begin
        @test ModelContextProtocol.extract_bearer_token("Bearer abc123") == "abc123"
        @test ModelContextProtocol.extract_bearer_token("Bearer  token-with-spaces  ") == "token-with-spaces"
        @test isnothing(ModelContextProtocol.extract_bearer_token("Basic abc123"))
        @test isnothing(ModelContextProtocol.extract_bearer_token("abc123"))
        @test isnothing(ModelContextProtocol.extract_bearer_token(""))
    end

    @testset "SimpleTokenValidator" begin
        validator = SimpleTokenValidator()

        # Add a token
        user = AuthenticatedUser(
            subject = "user1",
            provider = "api_key",
            username = "testuser"
        )
        ModelContextProtocol.add_token!(validator, "sk-test123", user)

        config = OAuthConfig(issuer = "local", audience = "local")

        # Valid token
        result = validate_token(validator, "sk-test123", config)
        @test result.success == true
        @test result.user.subject == "user1"

        # Invalid token
        result = validate_token(validator, "invalid", config)
        @test result.success == false
        @test result.error_code == :invalid_token
    end

    @testset "create_simple_auth" begin
        auth = create_simple_auth(Dict(
            "key1" => "user1",
            "key2" => "user2"
        ))

        @test auth.enabled == true

        # Test with valid token
        result = authenticate_request(auth, "Bearer key1")
        @test result.success == true
        @test result.user.username == "user1"

        # Test with invalid token
        result = authenticate_request(auth, "Bearer invalid")
        @test result.success == false
    end

    @testset "disable_auth" begin
        auth = disable_auth()
        @test auth.enabled == false

        # All requests should succeed with anonymous user
        result = authenticate_request(auth, nothing)
        @test result.success == true
        @test result.user.subject == "anonymous"

        result = authenticate_request(auth, "Bearer anything")
        @test result.success == true
    end

    @testset "check_allowlist" begin
        user1 = AuthenticatedUser(subject = "sub1", provider = "test", username = "user1")
        user2 = AuthenticatedUser(subject = "sub2", provider = "test", username = nothing)

        allowlist = Set(["user1", "sub2"])

        # User with matching username
        @test ModelContextProtocol.check_allowlist(user1, allowlist) == true

        # User with matching subject (no username)
        @test ModelContextProtocol.check_allowlist(user2, allowlist) == true

        # User not in allowlist
        user3 = AuthenticatedUser(subject = "sub3", provider = "test", username = "user3")
        @test ModelContextProtocol.check_allowlist(user3, allowlist) == false
    end

    @testset "AuthMiddleware with allowlist" begin
        auth = create_simple_auth(
            Dict("key1" => "allowed_user", "key2" => "blocked_user"),
            allowlist = Set(["allowed_user"])
        )

        # Allowed user
        result = authenticate_request(auth, "Bearer key1")
        @test result.success == true

        # Blocked user (valid token but not in allowlist)
        result = authenticate_request(auth, "Bearer key2")
        @test result.success == false
        @test result.error_code == :forbidden
    end

    @testset "authenticate_request error cases" begin
        auth = create_simple_auth(Dict("valid" => "user"))

        # Missing header
        result = authenticate_request(auth, nothing)
        @test result.success == false
        @test result.error_code == :missing_token

        # Empty header
        result = authenticate_request(auth, "")
        @test result.success == false
        @test result.error_code == :missing_token

        # Invalid format (not Bearer)
        result = authenticate_request(auth, "Basic abc123")
        @test result.success == false
        @test result.error_code == :invalid_format
    end

    @testset "ProtectedResourceMetadata" begin
        metadata = create_protected_resource_metadata(
            "https://mcp.example.com",
            ["https://github.com/login/oauth"],
            scopes = ["read:user", "repo"]
        )

        @test metadata.resource == "https://mcp.example.com"
        @test "https://github.com/login/oauth" in metadata.authorization_servers
        @test "read:user" in metadata.scopes_supported
        @test "header" in metadata.bearer_methods_supported
    end

    @testset "create_github_resource_metadata" begin
        metadata = create_github_resource_metadata(
            "https://mcp.lidkelab.org",
            scopes = ["read:user", "read:org"]
        )

        @test metadata.resource == "https://mcp.lidkelab.org"
        @test ModelContextProtocol.GitHubAuthorizationServer in metadata.authorization_servers
        @test "read:user" in metadata.scopes_supported
    end

    @testset "metadata_to_json" begin
        metadata = create_protected_resource_metadata(
            "https://example.com",
            ["https://auth.example.com"]
        )

        json = ModelContextProtocol.metadata_to_json(metadata)
        parsed = JSON3.read(json)

        @test parsed["resource"] == "https://example.com"
        @test "https://auth.example.com" in parsed["authorization_servers"]
    end

    @testset "JWTValidator - decode_jwt_payload" begin
        # Create a simple test JWT (header.payload.signature)
        # Payload: {"sub": "user123", "iss": "test", "exp": 9999999999}
        payload_json = """{"sub":"user123","iss":"test","exp":9999999999}"""
        payload_b64 = Base64.base64encode(payload_json)
        # Convert to URL-safe base64
        payload_b64 = replace(payload_b64, "+" => "-", "/" => "_")
        payload_b64 = rstrip(payload_b64, '=')

        # Fake header and signature
        header_b64 = Base64.base64encode("""{"alg":"HS256","typ":"JWT"}""")
        header_b64 = replace(header_b64, "+" => "-", "/" => "_")
        header_b64 = rstrip(header_b64, '=')

        test_jwt = "$(header_b64).$(payload_b64).fake_signature"

        claims = ModelContextProtocol.decode_jwt_payload(test_jwt)
        @test !isnothing(claims)
        @test claims["sub"] == "user123"
        @test claims["iss"] == "test"

        # Invalid JWT format
        @test isnothing(ModelContextProtocol.decode_jwt_payload("not.a.jwt.token"))
        @test isnothing(ModelContextProtocol.decode_jwt_payload("invalid"))
    end

    @testset "auth_error_response" begin
        # 401 errors
        status, body, headers = ModelContextProtocol.auth_error_response(:invalid_token, "Token is invalid")
        @test status == 401
        @test haskey(headers, "WWW-Authenticate")
        @test occursin("invalid_token", headers["WWW-Authenticate"])

        # 403 errors
        status, _, _ = ModelContextProtocol.auth_error_response(:forbidden, "User not allowed")
        @test status == 403

        status, _, headers = ModelContextProtocol.auth_error_response(:insufficient_scope, "Missing scope")
        @test status == 403
        @test occursin("insufficient_scope", headers["WWW-Authenticate"])
    end

    @testset "GitHub OAuth Provider" begin
        @testset "GitHubOAuthValidator" begin
            validator = GitHubOAuthValidator(cache_ttl_seconds = 120)

            @test validator.cache_ttl_seconds == 120
            @test isempty(validator.user_cache)
        end

        @testset "create_github_auth with allowlist" begin
            auth = create_github_auth(
                allowed_users = ["user1", "user2", "user3"]
            )

            @test auth.enabled == true
            @test !isnothing(auth.allowlist)
            @test "user1" in auth.allowlist
            @test "user2" in auth.allowlist
            @test "user3" in auth.allowlist
            @test auth.config.issuer == "https://github.com"
        end

        @testset "create_github_auth with Set allowlist" begin
            auth = create_github_auth(
                allowed_users = Set(["userA", "userB"])
            )

            @test auth.enabled == true
            @test "userA" in auth.allowlist
            @test "userB" in auth.allowlist
        end

        @testset "create_github_auth without allowlist" begin
            auth = create_github_auth()

            @test auth.enabled == true
            @test isnothing(auth.allowlist)  # No allowlist = allow all authenticated
        end

        @testset "create_github_auth with org requirement" begin
            auth = create_github_auth(
                required_org = "JuliaSMLM"
            )

            @test auth.enabled == true
            # The validator should be GitHubOAuthValidatorWithOrg
            @test auth.validator isa ModelContextProtocol.GitHubOAuthValidatorWithOrg
            @test auth.validator.required_org == "JuliaSMLM"
        end

        @testset "clear_cache!" begin
            validator = GitHubOAuthValidator()

            # Manually add to cache for testing
            user = AuthenticatedUser(subject = "123", provider = "github", username = "test")
            validator.user_cache["test-token"] = (user, Dates.now(Dates.UTC))

            @test !isempty(validator.user_cache)

            clear_cache!(validator)

            @test isempty(validator.user_cache)
        end

        @testset "GITHUB_API_URL constant" begin
            @test ModelContextProtocol.GITHUB_API_URL == "https://api.github.com"
        end

        @testset "GitHub auth integration without real token" begin
            # Test that validation fails gracefully without valid token
            auth = create_github_auth(
                allowed_users = ["user1"]
            )

            # Without a real GitHub token, validation should fail
            # Note: This doesn't actually call GitHub API in test
            result = authenticate_request(auth, "Bearer fake-token-12345")

            # The request will fail because we can't reach GitHub API or token is invalid
            @test result.success == false
            @test result.error_code == :invalid_token
        end
    end
end

@testset "OAuth Resource Server hardening" begin
    _b64url(s) = replace(base64encode(s), "+" => "-", "/" => "_", "=" => "")
    _mkjwt(header, payload) = "$(_b64url(JSON3.write(header))).$(_b64url(JSON3.write(payload))).sig"
    cfg = OAuthConfig(issuer = "https://issuer.example", audience = "my-mcp")
    v = JWTValidator()
    future = round(Int, datetime2unix(now(UTC))) + 3600
    past = round(Int, datetime2unix(now(UTC))) - 3600

    @testset "create_auth_middleware requires an explicit validator" begin
        @test_throws UndefKeywordError create_auth_middleware(cfg)
        @test create_auth_middleware(cfg; validator = v) isa AuthMiddleware
    end

    @testset "JWT validator fails closed" begin
        # alg=none is rejected outright (classic bypass)
        @test validate_token(v, _mkjwt(Dict("alg"=>"none"),
            Dict("iss"=>"https://issuer.example","aud"=>"my-mcp","exp"=>future,"sub"=>"u")), cfg).error_code == :invalid_token
        # Missing exp rejected (no non-expiring tokens)
        @test validate_token(v, _mkjwt(Dict("alg"=>"RS256"),
            Dict("iss"=>"https://issuer.example","aud"=>"my-mcp","sub"=>"u")), cfg).error_code == :invalid_token
        # Expired rejected
        @test validate_token(v, _mkjwt(Dict("alg"=>"RS256"),
            Dict("iss"=>"https://issuer.example","aud"=>"my-mcp","exp"=>past,"sub"=>"u")), cfg).error_code == :expired
        # Wrong / missing issuer rejected when configured
        @test validate_token(v, _mkjwt(Dict("alg"=>"RS256"),
            Dict("iss"=>"https://evil","aud"=>"my-mcp","exp"=>future,"sub"=>"u")), cfg).error_code == :invalid_issuer
        @test validate_token(v, _mkjwt(Dict("alg"=>"RS256"),
            Dict("aud"=>"my-mcp","exp"=>future,"sub"=>"u")), cfg).error_code == :invalid_issuer
        # Wrong audience rejected
        @test validate_token(v, _mkjwt(Dict("alg"=>"RS256"),
            Dict("iss"=>"https://issuer.example","aud"=>"other","exp"=>future,"sub"=>"u")), cfg).error_code == :invalid_audience
        # Fully valid claims pass (claims-only; signatures still not verified)
        ok = validate_token(v, _mkjwt(Dict("alg"=>"RS256"),
            Dict("iss"=>"https://issuer.example","aud"=>"my-mcp","exp"=>future,"sub"=>"u","preferred_username"=>"alice")), cfg)
        @test ok.success
        @test ok.user.username == "alice"
    end
end

@testset "Per-request auth context + ctx-aware handlers" begin
    server = mcp_server(name = "ctx-test", description = "", tools = [
        MCPTool(name = "whoami", description = "echo the authenticated user",
                handler = (args, ctx) -> TextContent(text = isnothing(ctx.authenticated_user) ? "anon" : ctx.authenticated_user.username),
                parameters = ToolParameter[]),
        MCPTool(name = "plain", description = "no ctx",
                handler = (args) -> TextContent(text = "ok"),
                parameters = ToolParameter[]),
    ])
    state = ServerState()
    whoami(user) = JSON3.read(process_message(server, state,
        """{"jsonrpc":"2.0","method":"tools/call","params":{"name":"whoami","arguments":{}},"id":1}""";
        authenticated_user = user)).result.content[1].text

    # Plain handler(args) still works
    rplain = JSON3.read(process_message(server, state,
        """{"jsonrpc":"2.0","method":"tools/call","params":{"name":"plain","arguments":{}},"id":1}"""))
    @test rplain.result.content[1].text == "ok"

    # ctx-aware handler sees the per-request user; interleaving must not leak identity
    alice = AuthenticatedUser(subject = "1", provider = "test", username = "alice")
    bob   = AuthenticatedUser(subject = "2", provider = "test", username = "bob")
    @test whoami(nothing) == "anon"
    @test whoami(alice) == "alice"
    @test whoami(bob) == "bob"
    @test whoami(alice) == "alice"
    @test whoami(nothing) == "anon"
end

@testset "JWKSValidator - signature verification (RFC 7517)" begin
    JWTs = ModelContextProtocol.JWTs
    _MbedTLS = JWTs.MbedTLS
    fixture_dir = joinpath(@__DIR__, "fixtures")
    fixture_url(name) = "file://" * abspath(joinpath(fixture_dir, name))

    # Signing helpers backed by the committed fixture keypairs (test-only keys)
    _sign(payload; key_pem, kid) = begin
        signing_key = JWTs.JWKRSA(_MbedTLS.MD_SHA256, _MbedTLS.parse_keyfile(joinpath(fixture_dir, key_pem)))
        jwt = JWTs.JWT(payload = payload)
        JWTs.sign!(jwt, signing_key, kid)
        string(jwt)
    end
    future = round(Int, datetime2unix(now(UTC))) + 3600
    past = round(Int, datetime2unix(now(UTC))) - 3600
    base_claims(; overrides...) = merge(Dict{String,Any}(
        "iss" => "https://issuer.example", "aud" => "my-mcp", "sub" => "user-1",
        "exp" => future, "preferred_username" => "alice", "scope" => "mcp:read mcp:write",
    ), Dict{String,Any}(string(k) => v for (k, v) in overrides))
    cfg = OAuthConfig(issuer = "https://issuer.example", audience = "my-mcp")
    valid_token = _sign(base_claims(); key_pem = "jwks_test_key.pem", kid = "test-key-1")

    @testset "construction is lazy (no fetch)" begin
        v = JWKSValidator(fixture_url("jwks_test.json"))
        @test isempty(v.keyset.keys)
        @test v.allowed_algs == ["RS256", "RS384", "RS512"]
    end

    @testset "valid signed token accepted with claims" begin
        v = JWKSValidator(fixture_url("jwks_test.json"))
        result = validate_token(v, valid_token, cfg)
        @test result.success
        @test result.user.subject == "user-1"
        @test result.user.username == "alice"
        @test "mcp:read" in result.user.scopes
        @test !isempty(v.keyset.keys)  # lazy fetch happened on first use
    end

    @testset "tampered payload and signature rejected" begin
        v = JWKSValidator(fixture_url("jwks_test.json"))
        h, p, s = split(valid_token, ".")
        # Forged payload (admin claims) with the original signature
        forged_payload = replace(String(p), r"^." => "A")
        @test !validate_token(v, "$h.$forged_payload.$s", cfg).success
        # Corrupted signature
        @test validate_token(v, "$h.$p.$(reverse(String(s)))", cfg).error_code == :invalid_token
        # Empty signature
        @test validate_token(v, "$h.$p.", cfg).error_code == :invalid_token
    end

    @testset "token signed by the wrong key rejected" begin
        # Signed with key 2 but claiming kid test-key-1 (kid spoofing)
        spoofed = _sign(base_claims(); key_pem = "jwks_test_key2.pem", kid = "test-key-1")
        v = JWKSValidator(fixture_url("jwks_test.json"))
        @test validate_token(v, spoofed, cfg).error_code == :invalid_token
    end

    @testset "header gate: alg/kid policy before crypto" begin
        v = JWKSValidator(fixture_url("jwks_test.json"))
        _b64url(s) = replace(base64encode(s), "+" => "-", "/" => "_", "=" => "")
        payload_b64 = _b64url(JSON3.write(base_claims()))
        # alg=none
        none_token = "$(_b64url("""{"alg":"none","kid":"test-key-1"}"""))" * ".$payload_b64."
        @test validate_token(v, none_token, cfg).error_code == :invalid_token
        # alg not allowlisted (HS256)
        hs_token = "$(_b64url("""{"alg":"HS256","kid":"test-key-1"}"""))" * ".$payload_b64.AAAA"
        @test validate_token(v, hs_token, cfg).error_code == :invalid_token
        # kid missing
        nokid_token = "$(_b64url("""{"alg":"RS256"}"""))" * ".$payload_b64.AAAA"
        @test validate_token(v, nokid_token, cfg).error_code == :invalid_token
        # malformed token
        @test validate_token(v, "not-a-jwt", cfg).error_code == :invalid_format
    end

    @testset "claims still enforced after valid signature" begin
        v = JWKSValidator(fixture_url("jwks_test.json"))
        expired = _sign(base_claims(exp = past); key_pem = "jwks_test_key.pem", kid = "test-key-1")
        @test validate_token(v, expired, cfg).error_code == :expired
        wrong_aud = _sign(base_claims(aud = "other"); key_pem = "jwks_test_key.pem", kid = "test-key-1")
        @test validate_token(v, wrong_aud, cfg).error_code == :invalid_audience
        scoped_cfg = OAuthConfig(issuer = "https://issuer.example", audience = "my-mcp",
                                 required_scopes = ["mcp:admin"])
        @test validate_token(v, valid_token, scoped_cfg).error_code == :insufficient_scope
    end

    @testset "key rotation: unknown kid triggers re-fetch" begin
        mktempdir() do dir
            jwks_path = joinpath(dir, "jwks.json")
            write(jwks_path, read(joinpath(fixture_dir, "jwks_test.json"), String))
            v = JWKSValidator("file://" * jwks_path; refresh_interval_seconds = 0)
            @test validate_token(v, valid_token, cfg).success
            # Rotate the published key set to key 2; a token under the new kid validates
            write(jwks_path, read(joinpath(fixture_dir, "jwks_test2.json"), String))
            rotated = _sign(base_claims(); key_pem = "jwks_test_key2.pem", kid = "test-key-2")
            @test validate_token(v, rotated, cfg).success
        end
    end

    @testset "unknown-kid refresh is rate-limited" begin
        mktempdir() do dir
            jwks_path = joinpath(dir, "jwks.json")
            write(jwks_path, read(joinpath(fixture_dir, "jwks_test.json"), String))
            v = JWKSValidator("file://" * jwks_path; refresh_interval_seconds = 3600)
            @test validate_token(v, valid_token, cfg).success  # initial fetch stamps the attempt
            write(jwks_path, read(joinpath(fixture_dir, "jwks_test2.json"), String))
            rotated = _sign(base_claims(); key_pem = "jwks_test_key2.pem", kid = "test-key-2")
            # Within the interval the unknown kid must NOT trigger another fetch: fail closed
            @test validate_token(v, rotated, cfg).error_code == :invalid_token
            # Known-kid tokens keep validating against the cached keys
            @test validate_token(v, valid_token, cfg).success
        end
    end

    @testset "fetch_jwks_keys fails closed" begin
        mktempdir() do dir
            bad = joinpath(dir, "bad.json")
            write(bad, "{not json")
            @test ModelContextProtocol.fetch_jwks_keys("file://" * bad) === nothing
            nokeys = joinpath(dir, "nokeys.json")
            write(nokeys, "{\"foo\": 1}")
            @test ModelContextProtocol.fetch_jwks_keys("file://" * nokeys) === nothing
            @test ModelContextProtocol.fetch_jwks_keys("file://" * joinpath(dir, "missing.json")) === nothing
        end
    end

    @testset "end-to-end through AuthMiddleware" begin
        auth = create_auth_middleware(cfg;
            validator = JWKSValidator(fixture_url("jwks_test.json")),
            allowlist = Set(["alice"]))
        ok = authenticate_request(auth, "Bearer $valid_token")
        @test ok.success && ok.user.username == "alice"
        # Signature-valid token for a non-allowlisted user is rejected
        eve_token = _sign(base_claims(preferred_username = "eve", sub = "user-2");
                          key_pem = "jwks_test_key.pem", kid = "test-key-1")
        denied = authenticate_request(auth, "Bearer $eve_token")
        @test !denied.success && denied.error_code == :forbidden
    end
end

@testset "JWKSValidator - hardening (Codex review)" begin
    JWTs = ModelContextProtocol.JWTs
    _MbedTLS = JWTs.MbedTLS
    fixture_dir = joinpath(@__DIR__, "fixtures")
    fixture_url(name) = "file://" * abspath(joinpath(fixture_dir, name))
    cfg = OAuthConfig(issuer = "https://issuer.example", audience = "my-mcp")
    future = round(Int, datetime2unix(now(UTC))) + 3600
    _sign(payload; key_pem, kid) = begin
        signing_key = JWTs.JWKRSA(_MbedTLS.MD_SHA256, _MbedTLS.parse_keyfile(joinpath(fixture_dir, key_pem)))
        jwt = JWTs.JWT(payload = payload)
        JWTs.sign!(jwt, signing_key, kid)
        string(jwt)
    end
    base_claims(; overrides...) = merge(Dict{String,Any}(
        "iss" => "https://issuer.example", "aud" => "my-mcp", "sub" => "u",
        "exp" => future,
    ), Dict{String,Any}(string(k) => v for (k, v) in overrides))

    @testset "plaintext http:// JWKS rejected at construction" begin
        @test_throws ArgumentError JWKSValidator("http://auth.example/jwks.json")
        # opt-in for localhost/testing, and https/file always allowed
        @test JWKSValidator("http://127.0.0.1:9/jwks.json"; allow_insecure_http = true) isa JWKSValidator
        @test JWKSValidator("https://auth.example/jwks.json") isa JWKSValidator
        @test JWKSValidator(fixture_url("jwks_test.json")) isa JWKSValidator
    end

    @testset "negative refresh interval clamped to 0" begin
        v = JWKSValidator(fixture_url("jwks_test.json"); refresh_interval_seconds = -100)
        @test v.refresh_interval_seconds == 0.0
    end

    @testset "non-numeric nbf rejected (not silently ignored)" begin
        v = JWKSValidator(fixture_url("jwks_test.json"))
        bad_nbf = _sign(base_claims(nbf = "9999999999"); key_pem = "jwks_test_key.pem", kid = "test-key-1")
        r = validate_token(v, bad_nbf, cfg)
        @test !r.success
        @test r.error_code == :invalid_token
        # a valid numeric (past) nbf still passes
        ok = _sign(base_claims(nbf = future - 7200); key_pem = "jwks_test_key.pem", kid = "test-key-1")
        @test validate_token(v, ok, cfg).success
    end

    @testset "oversize file JWKS rejected" begin
        mktempdir() do dir
            big = joinpath(dir, "big.json")
            # > MAX_JWKS_BYTES of padding inside an otherwise-valid envelope
            open(big, "w") do io
                write(io, "{\"keys\":[],\"pad\":\"")
                write(io, repeat("A", ModelContextProtocol.MAX_JWKS_BYTES + 10))
                write(io, "\"}")
            end
            @test ModelContextProtocol.fetch_jwks_keys("file://" * big) === nothing
        end
    end

    @testset "malformed JWK entry fails closed (no exception)" begin
        mktempdir() do dir
            bad = joinpath(dir, "jwks.json")
            write(bad, """{"keys":[{}]}""")  # entry missing kid/kty -> JWTs.refresh! throws
            v = JWKSValidator("file://" * bad; refresh_interval_seconds = 0)
            token = _sign(base_claims(); key_pem = "jwks_test_key.pem", kid = "test-key-1")
            r = validate_token(v, token, cfg)  # must not throw
            @test !r.success
            @test r.error_code == :invalid_token
        end
    end

    @testset "live http(s) fetch path: streaming + size cap" begin
        port = rand(20000:40000)
        small = read(joinpath(fixture_dir, "jwks_test.json"), String)
        huge = "{\"keys\":[],\"pad\":\"" * repeat("A", ModelContextProtocol.MAX_JWKS_BYTES + 64) * "\"}"
        server = HTTP.serve!("127.0.0.1", port; stream = true) do http
            target = http.message.target
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, occursin("huge", target) ? huge : small)
        end
        try
            sleep(0.3)
            # Small document over real HTTP validates a signed token
            v = JWKSValidator("http://127.0.0.1:$port/jwks.json"; allow_insecure_http = true)
            token = _sign(base_claims(sub = "u", aud = "my-mcp"); key_pem = "jwks_test_key.pem", kid = "test-key-1")
            @test validate_token(v, token, cfg).success
            # Oversize body is aborted -> no keys -> fails closed
            @test ModelContextProtocol.fetch_jwks_http_body("http://127.0.0.1:$port/huge.json") === nothing
        finally
            HTTP.close(server)
        end
    end
end

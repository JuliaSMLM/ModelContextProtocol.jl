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
        @testset "GitHubAuthConfig" begin
            config = GitHubAuthConfig(
                client_id = "test-client-id",
                allowed_users = Set(["user1", "user2"]),
                required_org = "TestOrg",
                cache_ttl_seconds = 600
            )

            @test config.client_id == "test-client-id"
            @test "user1" in config.allowed_users
            @test "user2" in config.allowed_users
            @test config.required_org == "TestOrg"
            @test config.cache_ttl_seconds == 600
        end

        @testset "GitHubAuthConfig defaults" begin
            config = GitHubAuthConfig()

            @test config.client_id == ""
            @test isempty(config.allowed_users)
            @test isnothing(config.required_org)
            @test config.cache_ttl_seconds == 300
        end

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

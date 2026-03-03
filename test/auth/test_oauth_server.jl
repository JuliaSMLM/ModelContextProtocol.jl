@testset "OAuth 2.1 Authorization Server" begin

    @testset "PKCE Implementation" begin
        @testset "compute_code_challenge" begin
            # Test vector from RFC 7636 Appendix B
            verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            expected_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

            challenge = compute_code_challenge(verifier, "S256")
            @test challenge == expected_challenge
        end

        @testset "validate_pkce S256" begin
            # Use a known verifier/challenge pair
            verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            challenge = compute_code_challenge(verifier, "S256")

            # Valid verification
            @test validate_pkce(challenge, verifier, "S256") == true

            # Invalid verifier
            @test validate_pkce(challenge, "wrong_verifier_but_long_enough_to_pass_length_check_1234567890", "S256") == false

            # Too short verifier
            @test validate_pkce(challenge, "short", "S256") == false

            # Too long verifier (>128 chars)
            long_verifier = repeat("a", 130)
            @test validate_pkce(challenge, long_verifier, "S256") == false

            # Invalid characters in verifier
            @test validate_pkce(challenge, "invalid!chars@here#1234567890123456789012345678901234567890", "S256") == false
        end

        @testset "generate_code_verifier" begin
            verifier = generate_code_verifier()
            @test Base.length(verifier) == 64

            # Custom length
            verifier = generate_code_verifier(100)
            @test Base.length(verifier) == 100

            # Should throw for invalid lengths
            @test_throws ArgumentError generate_code_verifier(42)  # Too short
            @test_throws ArgumentError generate_code_verifier(129)  # Too long
        end

        @testset "constant_time_compare" begin
            @test constant_time_compare("abc", "abc") == true
            @test constant_time_compare("abc", "abd") == false
            @test constant_time_compare("abc", "ab") == false
            @test constant_time_compare("", "") == true
        end
    end

    @testset "InMemoryTokenStorage" begin
        storage = InMemoryTokenStorage()

        @testset "Pending Authorizations" begin
            # Create a pending authorization with a known upstream_state
            pending = PendingAuthorization(
                state = "state123",
                client_id = "client1",
                redirect_uri = "https://app.example.com/callback",
                code_challenge = "challenge123",
                code_challenge_method = "S256",
                resource = "https://mcp.example.com",
                upstream_state = "upstream_state_123"  # Explicit upstream_state
            )

            # Store and retrieve (keyed by upstream_state)
            store_pending!(storage, pending)
            retrieved = get_pending(storage, "upstream_state_123")
            @test !isnothing(retrieved)
            @test retrieved.client_id == "client1"
            @test retrieved.redirect_uri == "https://app.example.com/callback"

            # Delete
            delete_pending!(storage, "upstream_state_123")
            @test isnothing(get_pending(storage, "upstream_state_123"))
        end

        @testset "Authorization Codes" begin
            user = AuthenticatedUser(subject = "user123", provider = "github", username = "testuser")
            code = AuthorizationCode(
                code = "code123",
                client_id = "client1",
                redirect_uri = "https://app.example.com/callback",
                code_challenge = "challenge123",
                code_challenge_method = "S256",
                resource = "https://mcp.example.com",
                user = user,
                expires_at = Dates.now(Dates.UTC) + Dates.Hour(1)
            )

            # Store and retrieve (keyed by code)
            store_auth_code!(storage, code)
            retrieved = get_auth_code(storage, "code123")
            @test !isnothing(retrieved)
            @test retrieved.user.username == "testuser"
            @test retrieved.client_id == "client1"

            # Delete
            delete_auth_code!(storage, "code123")
            @test isnothing(get_auth_code(storage, "code123"))
        end

        @testset "Issued Tokens" begin
            user = AuthenticatedUser(subject = "user123", provider = "github", username = "testuser")
            token = IssuedToken(
                access_token = "access123",
                user = user,
                client_id = "client1",
                resource = "https://mcp.example.com",
                expires_at = Dates.now(Dates.UTC) + Dates.Hour(1),
                refresh_token = "refresh123"
            )

            # Store and retrieve by access token (keyed by access_token)
            store_token!(storage, token)
            retrieved = get_token(storage, "access123")
            @test !isnothing(retrieved)
            @test retrieved.user.username == "testuser"

            # Retrieve by refresh token
            retrieved_by_refresh = get_token_by_refresh(storage, "refresh123")
            @test !isnothing(retrieved_by_refresh)
            @test retrieved_by_refresh.access_token == "access123"

            # Delete
            delete_token!(storage, "access123")
            @test isnothing(get_token(storage, "access123"))
        end

        @testset "Expired Token Cleanup" begin
            new_storage = InMemoryTokenStorage()
            user = AuthenticatedUser(subject = "user123", provider = "github")

            # Add expired token
            expired_token = IssuedToken(
                access_token = "expired_token",
                user = user,
                client_id = "client1",
                resource = "https://mcp.example.com",
                expires_at = Dates.now(Dates.UTC) - Dates.Hour(1)  # Expired
            )
            store_token!(new_storage, expired_token)

            # Add valid token
            valid_token = IssuedToken(
                access_token = "valid_token",
                user = user,
                client_id = "client1",
                resource = "https://mcp.example.com",
                expires_at = Dates.now(Dates.UTC) + Dates.Hour(1)
            )
            store_token!(new_storage, valid_token)

            # Cleanup
            cleanup_expired!(new_storage)

            # Expired should be gone, valid should remain
            @test isnothing(get_token(new_storage, "expired_token"))
            @test !isnothing(get_token(new_storage, "valid_token"))
        end
    end

    @testset "OAuthServerConfig" begin
        config = OAuthServerConfig(
            issuer = "https://mcp.example.com",
            authorization_endpoint = "https://mcp.example.com/authorize",
            token_endpoint = "https://mcp.example.com/token"
        )

        @test config.issuer == "https://mcp.example.com"
        @test "code" in config.response_types_supported
        @test "S256" in config.code_challenge_methods_supported
        @test config.access_token_ttl == 3600
        @test config.refresh_token_ttl == 86400 * 30
    end

    @testset "Authorization Server Metadata" begin
        @testset "build_authorization_server_metadata" begin
            config = OAuthServerConfig(
                issuer = "https://mcp.example.com",
                authorization_endpoint = "https://mcp.example.com/authorize",
                token_endpoint = "https://mcp.example.com/token",
                scopes_supported = ["read", "write"]
            )

            metadata = build_authorization_server_metadata(config)

            @test metadata["issuer"] == "https://mcp.example.com"
            @test metadata["authorization_endpoint"] == "https://mcp.example.com/authorize"
            @test metadata["token_endpoint"] == "https://mcp.example.com/token"
            @test "code" in metadata["response_types_supported"]
            @test "S256" in metadata["code_challenge_methods_supported"]
        end

        @testset "is_authorization_server_metadata_path" begin
            @test is_authorization_server_metadata_path("/.well-known/oauth-authorization-server", "https://mcp.example.com")
            @test is_authorization_server_metadata_path("/.well-known/openid-configuration", "https://mcp.example.com")
            @test !is_authorization_server_metadata_path("/other", "https://mcp.example.com")
        end

        @testset "metadata constants" begin
            @test AUTHORIZATION_SERVER_METADATA_PATH == "/.well-known/oauth-authorization-server"
            @test OPENID_CONFIGURATION_PATH == "/.well-known/openid-configuration"
        end
    end

    @testset "GitHubUpstreamProvider" begin
        provider = GitHubUpstreamProvider(
            client_id = "test_client_id",
            client_secret = "test_client_secret",
            scopes = ["read:user", "read:org"]
        )

        @test provider.client_id == "test_client_id"
        @test provider.client_secret == "test_client_secret"
        @test "read:user" in provider.scopes
        @test provider.authorize_url == "https://github.com/login/oauth/authorize"
        @test provider.token_url == "https://github.com/login/oauth/access_token"
    end

    @testset "OAuthServer Construction" begin
        provider = GitHubUpstreamProvider(
            client_id = "test_client_id",
            client_secret = "test_client_secret"
        )

        @testset "With issuer string" begin
            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider
            )

            @test server.config.issuer == "https://mcp.example.com"
            @test server.config.authorization_endpoint == "https://mcp.example.com/authorize"
            @test server.config.token_endpoint == "https://mcp.example.com/token"
            @test server.callback_path == "/callback"
            @test isnothing(server.allowed_users)
        end

        @testset "With trailing slash removal" begin
            server = OAuthServer(
                issuer = "https://mcp.example.com/",
                upstream = provider
            )

            @test server.config.issuer == "https://mcp.example.com"
        end

        @testset "With allowlist as Vector" begin
            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider,
                allowed_users = ["user1", "user2"]
            )

            @test !isnothing(server.allowed_users)
            @test "user1" in server.allowed_users
            @test "user2" in server.allowed_users
        end

        @testset "With allowlist as Set" begin
            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider,
                allowed_users = Set(["user1", "user2"])
            )

            @test !isnothing(server.allowed_users)
            @test "user1" in server.allowed_users
        end

        @testset "With required_org" begin
            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider,
                required_org = "MyOrg"
            )

            @test server.required_org == "MyOrg"
        end

        @testset "With custom callback path" begin
            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider,
                callback_path = "/oauth/callback"
            )

            @test server.callback_path == "/oauth/callback"
        end

        @testset "get_callback_uri" begin
            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider,
                callback_path = "/callback"
            )

            @test get_callback_uri(server) == "https://mcp.example.com/callback"
        end
    end

    @testset "OAuth Endpoint Detection" begin
        provider = GitHubUpstreamProvider(
            client_id = "test",
            client_secret = "test"
        )

        server = OAuthServer(
            issuer = "https://mcp.example.com",
            upstream = provider
        )

        # OAuth endpoints should be recognized
        @test is_oauth_endpoint(server, "/authorize")
        @test is_oauth_endpoint(server, "/callback")
        @test is_oauth_endpoint(server, "/token")
        @test is_oauth_endpoint(server, "/.well-known/oauth-authorization-server")
        @test is_oauth_endpoint(server, "/.well-known/openid-configuration")

        # Non-OAuth endpoints
        @test !is_oauth_endpoint(server, "/")
        @test !is_oauth_endpoint(server, "/api")
        @test !is_oauth_endpoint(server, "/other")
    end

    @testset "OAuthServerValidator" begin
        storage = InMemoryTokenStorage()
        validator = OAuthServerValidator(storage)
        config = OAuthConfig(
            issuer = "https://mcp.example.com",
            audience = "https://mcp.example.com"
        )

        @testset "Valid token" begin
            # Store a valid token
            user = AuthenticatedUser(subject = "user123", provider = "github", username = "testuser")
            token = IssuedToken(
                access_token = "valid_token_123",
                user = user,
                client_id = "client1",
                resource = "https://mcp.example.com",
                expires_at = Dates.now(Dates.UTC) + Dates.Hour(1)
            )
            store_token!(storage, token)

            # Validate
            result = validate_token(validator, "valid_token_123", config)
            @test result.success == true
            @test result.user.username == "testuser"
        end

        @testset "Invalid token" begin
            result = validate_token(validator, "nonexistent_token", config)
            @test result.success == false
            @test result.error_code == :invalid_token
        end

        @testset "Wrong audience" begin
            # Store a token for different resource
            user = AuthenticatedUser(subject = "user123", provider = "github")
            token = IssuedToken(
                access_token = "wrong_audience_token",
                user = user,
                client_id = "client1",
                resource = "https://other.example.com",  # Different resource
                expires_at = Dates.now(Dates.UTC) + Dates.Hour(1)
            )
            store_token!(storage, token)

            result = validate_token(validator, "wrong_audience_token", config)
            @test result.success == false
            @test result.error_code == :invalid_audience
        end
    end

    @testset "create_oauth_auth_middleware" begin
        provider = GitHubUpstreamProvider(
            client_id = "test",
            client_secret = "test"
        )

        server = OAuthServer(
            issuer = "https://mcp.example.com",
            upstream = provider,
            allowed_users = Set(["user1", "user2"])
        )

        auth = create_oauth_auth_middleware(server)

        @test auth.enabled == true
        @test auth.config.issuer == "https://mcp.example.com"
        @test auth.validator isa OAuthServerValidator
        @test !isnothing(auth.allowlist)
        @test "user1" in auth.allowlist
    end

    @testset "create_oauth_resource_metadata" begin
        provider = GitHubUpstreamProvider(
            client_id = "test",
            client_secret = "test"
        )

        server = OAuthServer(
            issuer = "https://mcp.example.com",
            upstream = provider
        )

        metadata = create_oauth_resource_metadata(server, scopes = ["read", "write"])

        @test metadata.resource == "https://mcp.example.com"
        @test "https://mcp.example.com" in metadata.authorization_servers
        @test "read" in metadata.scopes_supported
        @test "write" in metadata.scopes_supported
    end

    @testset "OAuth Error Codes" begin
        @test OAuthErrorCodes.INVALID_REQUEST == "invalid_request"
        @test OAuthErrorCodes.INVALID_CLIENT == "invalid_client"
        @test OAuthErrorCodes.INVALID_GRANT == "invalid_grant"
        @test OAuthErrorCodes.ACCESS_DENIED == "access_denied"
        @test OAuthErrorCodes.UNSUPPORTED_RESPONSE_TYPE == "unsupported_response_type"
    end

    @testset "Dynamic Client Registration (RFC 7591)" begin
        @testset "RegisteredClient type" begin
            client = RegisteredClient(
                client_id = "test-client-123",
                client_name = "Test Client",
                redirect_uris = ["https://app.example.com/callback"],
                grant_types = ["authorization_code"],
                response_types = ["code"],
                token_endpoint_auth_method = "none"
            )

            @test client.client_id == "test-client-123"
            @test client.client_name == "Test Client"
            @test "https://app.example.com/callback" in client.redirect_uris
            @test client.token_endpoint_auth_method == "none"
            @test isnothing(client.client_secret)
        end

        @testset "Client Storage" begin
            storage = InMemoryTokenStorage()

            client = RegisteredClient(
                client_id = "client-456",
                client_name = "Storage Test Client"
            )

            # Store and retrieve
            store_client!(storage, client)
            retrieved = get_client(storage, "client-456")
            @test !isnothing(retrieved)
            @test retrieved.client_name == "Storage Test Client"

            # Non-existent client
            @test isnothing(get_client(storage, "nonexistent"))

            # Delete
            delete_client!(storage, "client-456")
            @test isnothing(get_client(storage, "client-456"))
        end

        @testset "OAuthServer /register endpoint" begin
            provider = GitHubUpstreamProvider(
                client_id = "test",
                client_secret = "test"
            )

            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider
            )

            # Server should have registration_endpoint in config
            @test server.config.registration_endpoint == "https://mcp.example.com/register"

            # /register should be recognized as OAuth endpoint
            @test is_oauth_endpoint(server, "/register")
        end

        @testset "handle_oauth_request for /register" begin
            provider = GitHubUpstreamProvider(
                client_id = "test",
                client_secret = "test"
            )

            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider
            )

            # Test basic client registration
            body = JSON3.write(Dict(
                "client_name" => "Claude Desktop",
                "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
                "grant_types" => ["authorization_code", "refresh_token"],
                "response_types" => ["code"],
                "token_endpoint_auth_method" => "none"
            ))

            status, response_body, headers = handle_oauth_request(
                server,
                "POST",
                "/register",
                Dict{String,String}(),
                body,
                Dict{String,String}("Content-Type" => "application/json")
            )

            @test status == 201
            @test headers["Content-Type"] == "application/json"

            response = JSON3.read(response_body, Dict{String,Any})
            @test haskey(response, "client_id")
            @test haskey(response, "client_id_issued_at")
            @test response["client_name"] == "Claude Desktop"
            @test "authorization_code" in response["grant_types"]
            @test response["token_endpoint_auth_method"] == "none"

            # Verify client was stored
            stored = get_client(server.storage, response["client_id"])
            @test !isnothing(stored)
            @test stored.client_name == "Claude Desktop"
        end

        @testset "Registration with minimal request" begin
            provider = GitHubUpstreamProvider(
                client_id = "test",
                client_secret = "test"
            )

            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider
            )

            # Empty body should still work (creates public client with defaults)
            status, response_body, _ = handle_oauth_request(
                server,
                "POST",
                "/register",
                Dict{String,String}(),
                "{}",
                Dict{String,String}("Content-Type" => "application/json")
            )

            @test status == 201
            response = JSON3.read(response_body, Dict{String,Any})
            @test haskey(response, "client_id")
            @test response["token_endpoint_auth_method"] == "none"
        end

        @testset "Registration with confidential client" begin
            provider = GitHubUpstreamProvider(
                client_id = "test",
                client_secret = "test"
            )

            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider
            )

            body = JSON3.write(Dict(
                "client_name" => "Confidential App",
                "token_endpoint_auth_method" => "client_secret_post"
            ))

            status, response_body, _ = handle_oauth_request(
                server,
                "POST",
                "/register",
                Dict{String,String}(),
                body,
                Dict{String,String}("Content-Type" => "application/json")
            )

            @test status == 201
            response = JSON3.read(response_body, Dict{String,Any})
            @test haskey(response, "client_id")
            @test haskey(response, "client_secret")  # Secret should be issued
            @test response["token_endpoint_auth_method"] == "client_secret_post"
        end

        @testset "Registration error cases" begin
            provider = GitHubUpstreamProvider(
                client_id = "test",
                client_secret = "test"
            )

            server = OAuthServer(
                issuer = "https://mcp.example.com",
                upstream = provider
            )

            # Unsupported grant type
            body = JSON3.write(Dict(
                "grant_types" => ["client_credentials"]  # Not supported
            ))

            status, response_body, _ = handle_oauth_request(
                server,
                "POST",
                "/register",
                Dict{String,String}(),
                body,
                Dict{String,String}("Content-Type" => "application/json")
            )

            @test status == 400
            response = JSON3.read(response_body, Dict{String,Any})
            @test response["error"] == "invalid_client_metadata"

            # Unsupported response type
            body = JSON3.write(Dict(
                "response_types" => ["token"]  # Implicit flow not supported
            ))

            status, _, _ = handle_oauth_request(
                server,
                "POST",
                "/register",
                Dict{String,String}(),
                body,
                Dict{String,String}("Content-Type" => "application/json")
            )

            @test status == 400
        end

        @testset "Authorization Server Metadata includes registration_endpoint" begin
            config = OAuthServerConfig(
                issuer = "https://mcp.example.com",
                authorization_endpoint = "https://mcp.example.com/authorize",
                token_endpoint = "https://mcp.example.com/token",
                registration_endpoint = "https://mcp.example.com/register"
            )

            metadata = build_authorization_server_metadata(config)

            @test metadata["registration_endpoint"] == "https://mcp.example.com/register"
        end
    end

end

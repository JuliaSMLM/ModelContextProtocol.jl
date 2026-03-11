@testset "Protocol Versioning" begin
    @testset "Version Constants" begin
        # LATEST_PROTOCOL_VERSION should be the newest
        @test LATEST_PROTOCOL_VERSION == "2025-11-25"

        # SUPPORTED_PROTOCOL_VERSIONS should include latest
        @test LATEST_PROTOCOL_VERSION in SUPPORTED_PROTOCOL_VERSIONS

        # Should support multiple versions
        @test length(SUPPORTED_PROTOCOL_VERSIONS) >= 4
        @test "2024-11-05" in SUPPORTED_PROTOCOL_VERSIONS
        @test "2025-06-18" in SUPPORTED_PROTOCOL_VERSIONS

        # Versions should be in descending order (newest first)
        @test SUPPORTED_PROTOCOL_VERSIONS[1] == LATEST_PROTOCOL_VERSION
    end

    @testset "negotiate_version" begin
        # Supported version returns same version
        @test negotiate_version("2024-11-05") == "2024-11-05"
        @test negotiate_version("2025-06-18") == "2025-06-18"
        @test negotiate_version("2025-11-25") == "2025-11-25"

        # Unknown version returns latest
        @test negotiate_version("9999-99-99") == LATEST_PROTOCOL_VERSION
        @test negotiate_version("2020-01-01") == LATEST_PROTOCOL_VERSION

        # Nothing returns latest
        @test negotiate_version(nothing) == LATEST_PROTOCOL_VERSION

        # SubString should work (common in HTTP parsing)
        @test negotiate_version(SubString("2024-11-05", 1, 10)) == "2024-11-05"
    end

    @testset "is_supported_version" begin
        @test is_supported_version("2024-11-05")
        @test is_supported_version("2025-06-18")
        @test is_supported_version("2025-11-25")

        @test !is_supported_version("9999-99-99")
        @test !is_supported_version("2020-01-01")
        @test !is_supported_version("")
    end

    @testset "FEATURE_VERSIONS" begin
        # Should have known features
        @test haskey(FEATURE_VERSIONS, :tasks)
        @test haskey(FEATURE_VERSIONS, :sse_priming_events)
        @test haskey(FEATURE_VERSIONS, :streamable_http)
        @test haskey(FEATURE_VERSIONS, :resource_links)

        # Features should have valid version strings
        for (feature, version) in FEATURE_VERSIONS
            @test is_supported_version(version) || version > LATEST_PROTOCOL_VERSION
        end
    end

    @testset "supports" begin
        # 2025-11-25 features
        @test supports("2025-11-25", :tasks)
        @test supports("2025-11-25", :sse_priming_events)
        @test supports("2025-11-25", :icon_metadata)

        # 2025-06-18 supports its features but not 2025-11-25 features
        @test supports("2025-06-18", :resource_links)
        @test !supports("2025-06-18", :tasks)
        @test !supports("2025-06-18", :sse_priming_events)

        # 2025-03-26 supports streamable_http
        @test supports("2025-03-26", :streamable_http)
        @test !supports("2025-03-26", :tasks)

        # 2024-11-05 doesn't support newer features
        @test !supports("2024-11-05", :tasks)
        @test !supports("2024-11-05", :resource_links)
        @test !supports("2024-11-05", :streamable_http)

        # Unknown features return false
        @test !supports("2025-11-25", :unknown_feature)
        @test !supports("2025-11-25", :nonexistent)
    end

    @testset "Version stored in ServerState" begin
        config = ServerConfig(name = "test-server")
        server = Server(config)
        state = ServerState()

        # Initially nothing
        @test isnothing(state.protocol_version)

        # After initialization, should be set
        init_msg = """{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
        response = process_message(server, state, init_msg)

        # State should have negotiated version
        @test state.protocol_version == "2025-06-18"
    end
end

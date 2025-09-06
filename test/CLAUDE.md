# Testing Guidelines for test/

This directory contains all tests for ModelContextProtocol.jl. Follow these conventions when writing or modifying tests.

## Test Structure

### runtests.jl Organization
- **Only contains**: `using` statements and the overall test structure
- **No test logic**: All actual tests are included from other files
- **All imports here**: Any packages needed for testing must be imported at the top of runtests.jl

### Test File Organization
1. **User-facing API tests** (e.g., `test_server.jl`, `test_client.jl`)
   - Tests all exported functions that users interact with
   - Tests various keyword arguments and options
   - Focuses on expected use cases and behavior

2. **Protocol tests** (e.g., `test_jsonrpc.jl`, `test_messages.jl`)
   - Tests JSON-RPC protocol compliance
   - Tests message serialization/deserialization
   - Validates protocol version handling

3. **Transport tests** (e.g., `test_stdio.jl`, `test_http.jl`)
   - Tests different transport mechanisms
   - Validates session management
   - Tests SSE streaming for HTTP

4. **Feature tests** (e.g., `test_tools.jl`, `test_resources.jl`, `test_prompts.jl`)
   - Tests tool registration and execution
   - Tests resource handling
   - Tests prompt generation

### Important Rules
- **No using statements in included files** - All imports must be in runtests.jl
- **Aim for simplicity** - Good coverage without bloating tests
- **Avoid pedantic edge cases** - Focus on meaningful tests that aid development
- **Maintainability first** - Tests should be easy to update as code evolves
- **Protocol compliance** - Ensure all tests use protocol version `2025-06-18`

## Running Tests

### From Julia REPL
```julia
# Activate the project (from package root)
using Pkg
Pkg.activate(".")

# Run all tests
Pkg.test()

# Or with package name
Pkg.test("ModelContextProtocol")
```

### Running Specific Test Files
```bash
# Run a specific test file
julia --project test/test_server.jl

# Run with specific test args
julia --project -e 'using Pkg; Pkg.test("ModelContextProtocol", test_args=["test_http.jl"])'
```

### During Development
```julia
# Run all tests from REPL
include("test/runtests.jl")

# Run integration tests (if needed)
cd("dev/integration_tests")
include("runtests.jl")
```

## Writing New Tests

### Test Structure Template
```julia
@testset "Feature Name Tests" begin
    @testset "Basic functionality" begin
        # Test basic cases
    end
    
    @testset "Error handling" begin
        # Test error conditions
    end
    
    @testset "Edge cases" begin
        # Test boundary conditions
    end
end
```

### MCP-Specific Testing Patterns

1. **Testing Servers**:
```julia
@testset "MCP Server" begin
    server = Server("test-server", "1.0.0")
    
    # Register components
    add_tool!(server, tool)
    add_resource!(server, resource)
    
    # Test without starting the server
    # Use mock transports for testing
end
```

2. **Testing Protocol Messages**:
```julia
@testset "Protocol Messages" begin
    # Test serialization
    msg = InitializeRequest(...)
    json = JSON3.write(msg)
    
    # Test deserialization
    parsed = JSON3.read(json, InitializeRequest)
    @test parsed.protocol_version == "2025-06-18"
end
```

3. **Testing Tools**:
```julia
@testset "Tool Execution" begin
    tool = MCPTool(
        name = "test_tool",
        handler = (params) -> TextContent(text = "result")
    )
    
    result = tool.handler(Dict())
    @test result isa TextContent
end
```

## Integration Testing

For testing with external MCP clients, see `dev/integration_tests/`:
- Tests with Python MCP SDK
- Tests with MCP Inspector
- Cross-language compatibility tests

## Test Coverage

Focus on testing:
- All exported functions
- Protocol compliance (JSON-RPC 2.0)
- Error handling and edge cases
- Transport mechanisms (stdio, HTTP)
- Content types (TextContent, ImageContent, etc.)
- Multi-content returns
- Session management

## Best Practices

- Group related tests in `@testset` blocks with descriptive names
- Use meaningful test descriptions
- Test both success cases and expected failures
- Keep tests focused and independent
- Mock external dependencies when possible
- Use temporary directories for file-based tests
- Clean up resources after tests complete
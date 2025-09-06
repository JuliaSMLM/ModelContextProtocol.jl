# Development Guidelines for dev/

This directory is for informal development testing, experimentation, and concept exploration for ModelContextProtocol.jl. It provides a sandbox for testing MCP features and interfaces outside of formal testing.

## Purpose
- Informal testing and experimentation with MCP features
- Testing new protocol implementations
- Quick feedback during development
- Integration testing with external MCP clients
- Not part of formal test suite

## Directory Structure
```
dev/
├── integration_tests/   # Cross-language MCP client tests
│   ├── Project.toml    # Integration test dependencies
│   ├── requirements.txt # Python dependencies
│   └── test_*.jl       # Integration test files
└── output/             # Generated outputs (gitignored)
```

## Environment Setup

### Dev Environment
**Note**: Create `dev/Project.toml` if it doesn't exist:
```bash
cd dev && julia -e 'using Pkg; Pkg.activate("."); Pkg.add(["BenchmarkTools", "Revise", "HTTP"])'
```

- Each file starts with: `using Pkg; Pkg.activate("dev")`
- Has its own environment with development tools:
  - BenchmarkTools (for performance testing)
  - Revise (for interactive development)
  - HTTP (for testing HTTP transport)
  - Other development-specific packages as needed

### Running Dev Files (For Code Agents/Claude)

Since you run Julia in separate processes (not an interactive REPL), use this command:
```bash
julia --project=. dev/my_experiment.jl
```

**Important**: The dev files handle their own environment activation, so:
1. Run from the project root with `--project=.`
2. The file itself will activate the dev environment
3. Always capture stdout to see println output
4. Read generated PNG files after execution

## Integration Tests

The `dev/integration_tests/` directory contains tests with external MCP clients:

### Setup
```bash
cd dev/integration_tests
julia --project -e 'using Pkg; Pkg.instantiate()'
pip install -r requirements.txt
```

### Running Integration Tests
```bash
# Basic STDIO communication test
julia --project test_basic_stdio.jl

# Full integration test with Python MCP client
julia --project test_integration.jl

# Python client compatibility test
julia --project test_python_client.jl

# Run all integration tests
julia --project runtests.jl
```

## Creating New Dev Files

When creating new files in the dev/ directory, follow these conventions:

### File Structure Template
```julia
# Environment activation
using Pkg
Pkg.activate("dev")

# Load packages
using ModelContextProtocol
using HTTP
using JSON3

# Parameters (adjust these as needed)
server_port = 3000
test_iterations = 100
verbose = true

# Output directory
output_dir = joinpath(@__DIR__, "output")
mkpath(output_dir)  # Create if it doesn't exist

# Your development/testing code here
println("Starting MCP development test...")

# Save outputs
results_file = joinpath(output_dir, "test_results.json")
open(results_file, "w") do f
    JSON3.write(f, results)
end
println("Results saved to $results_file")
```

### MCP-Specific Dev Files

1. **Testing New Protocol Features**:
```julia
# dev/test_new_protocol_feature.jl
using Pkg; Pkg.activate("dev")
using ModelContextProtocol

# Test new protocol feature
server = Server("dev-server", "1.0.0")
# ... experimental code ...
```

2. **Testing HTTP Transport**:
```julia
# dev/test_http_improvements.jl
using Pkg; Pkg.activate("dev")
using ModelContextProtocol
using HTTP

# Start test server
transport = HttpTransport(host="127.0.0.1", port=3000)
server = Server("http-test", "1.0.0", transport=transport)
# ... test HTTP features ...
```

3. **Benchmarking**:
```julia
# dev/benchmark_jsonrpc.jl
using Pkg; Pkg.activate("dev")
using ModelContextProtocol
using BenchmarkTools

# Benchmark JSON-RPC parsing
@benchmark JSON3.read(msg, InitializeRequest)
```

## Output Conventions

### Output Types
- **Console output**: Use `println()` for text feedback
- **JSON files**: For structured test results (JSON3.write)
- **Log files**: For detailed debug information
- **Test artifacts**: Temporary files for testing features

### Output Location
- All outputs go to `dev/output/` or subfolders
- **Important**: Add `dev/output/` to `.gitignore` if saving test artifacts
- Create subfolders for organization if needed:
  - `dev/output/benchmarks/`
  - `dev/output/protocol_tests/`
  - `dev/output/integration/`

### For Code Agents/LLMs

#### Execution Workflow
1. Run the dev file from project root:
   ```bash
   julia --project=. dev/experiment.jl
   ```
2. Capture and analyze stdout output
3. Check `dev/output/` for generated files
4. Read and interpret results

#### Example MCP Server Testing
```julia
# In dev file
using Pkg; Pkg.activate("dev")
using ModelContextProtocol

# Create test server
server = Server("test-server", "1.0.0")

# Add test tool
tool = MCPTool(
    name = "test_tool",
    description = "Development test tool",
    handler = function(params)
        println("Tool called with: ", params)
        return TextContent(text = "Test result")
    end
)
add_tool!(server, tool)

# Test without starting server (for unit testing)
result = tool.handler(Dict("test" => true))
println("Tool result: ", result.text)

# Save test results
output_dir = joinpath(@__DIR__, "output")
mkpath(output_dir)
open(joinpath(output_dir, "test_results.txt"), "w") do f
    write(f, "Test completed successfully\n")
    write(f, "Result: $(result.text)\n")
end
```

## Testing MCP Servers

### Quick Server Test Script
Create `dev/test_server.jl`:
```julia
using Pkg; Pkg.activate("dev")
using ModelContextProtocol
using HTTP
using JSON3

# Test server with stdio
server = Server("dev-test", "1.0.0")
add_tool!(server, MCPTool(
    name = "echo",
    handler = p -> TextContent(text = get(p, "message", ""))
))

# Simulate request
request = Dict(
    "jsonrpc" => "2.0",
    "method" => "tools/list",
    "id" => 1
)

response = process_message(server, JSON3.write(request))
println("Response: ", response)
```

## Best Practices

- Keep files focused on single concepts or features
- Use clear, descriptive output messages
- Save all generated data for later analysis
- Document findings with println statements
- Clean up old outputs periodically
- Test with protocol version `2025-06-18`
- Use `127.0.0.1` instead of `localhost` for HTTP tests
- Always include both Accept headers for HTTP: `application/json, text/event-stream`
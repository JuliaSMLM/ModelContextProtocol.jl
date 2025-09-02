# API Reference

This page contains the complete API reference for ModelContextProtocol.jl.

## Transport Options

ModelContextProtocol.jl supports multiple transport mechanisms:

### STDIO Transport (Default)
```julia
server = mcp_server(name = "my-server")
start!(server)  # Uses StdioTransport by default
```

### HTTP Transport
```julia
server = mcp_server(name = "my-http-server")
start!(server; transport = HttpTransport(; port = 3000))

# With custom configuration
start!(server; transport = HttpTransport(;
    host = "127.0.0.1",  # Important for Windows
    port = 8080,         # Default port
    endpoint = "/"       # Default endpoint
))
```

**Note**: HTTP transport currently supports HTTP only, not HTTPS. For production use:
- Use `mcp-remote` with `--allow-http` flag for secure connections
- Or deploy behind a reverse proxy (nginx, Apache) for TLS termination

## Complete API Documentation

```@autodocs
Modules = [ModelContextProtocol]
Order   = [:function, :macro, :type, :module, :constant]
```
# Using with Claude Desktop

ModelContextProtocol.jl can be integrated with Anthropic's Claude Desktop application to allow Claude to access your custom tools, resources, and prompts.

## Setup Instructions

1. Launch Claude Desktop application
2. Go to `File` → `Settings` → `Developer`
3. Click the `Edit Config` button
4. A configuration file will open in your default editor

## Configuration

To register your MCP servers with Claude, modify the configuration file with entries for each server:

```json
{
  "mcpServers": {
    "time": {
      "command": "julia",
      "args": [
        "/path/to/ModelContextProtocol/examples/time_server.jl"
      ],
      "env": {}
    },
    "mcp_tools_example": {
      "command": "julia",
      "args": [
        "/path/to/ModelContextProtocol/examples/reg_dir.jl"
      ],
      "env": {}
    },
    "http_server": {
      "command": "npx",
      "args": ["mcp-remote", "http://127.0.0.1:3000", "--allow-http"],
      "env": {}
    }
  }
}
```

For each server entry:

- `"time"`, `"mcp_tools_example"`: Unique identifiers for your servers
- `"command"`: The command to run (should be `"julia"` for STDIO servers, `"npx"` for HTTP servers via mcp-remote)
- `"args"`: Array of arguments, typically the path to your server script or mcp-remote parameters
- `"env"`: Optional environment variables (can be empty `{}`)

### Using HTTP Servers

For HTTP-based MCP servers, you need to:

1. Start your HTTP server separately:
   ```julia
   julia /path/to/your/http_server.jl
   ```

2. Configure Claude to connect via mcp-remote:
   ```json
   "http_server": {
     "command": "npx",
     "args": ["mcp-remote", "http://127.0.0.1:3000", "--allow-http"]
   }
   ```

Note: The `--allow-http` flag is required since ModelContextProtocol.jl currently supports HTTP only, not HTTPS.

## Applying Changes

For configuration changes to take effect:

1. Save the configuration file
2. Close all running Claude processes:
   - On Windows: Use Task Manager to end all Claude processes
   - On macOS: Quit the application
3. Restart the Claude Desktop application

## Using Your MCP Server

Once configured, you can tell Claude to use your MCP server:

```
Please connect to the MCP server named "time" and tell me the current time.
```

Claude will connect to your server, discover available tools and resources, and use them to fulfill your requests.

## Troubleshooting

If Claude cannot connect to your server:

1. Check the server name matches exactly what's in your configuration
2. Verify the path to your script is correct and accessible
3. Check that your script has all required dependencies installed and precompiled
4. Look for any error messages in the Claude Desktop console (Developer Tools)


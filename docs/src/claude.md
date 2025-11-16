# Using with Claude Desktop

ModelContextProtocol.jl can be integrated with Anthropic's Claude Desktop application to allow Claude to access your custom tools, resources, and prompts.

## Setup Instructions

1. Launch Claude Desktop application
2. Go to `File` → `Settings` → `Developer`
3. Click the `Edit Config` button
4. A configuration file will open in your default editor

## Configuration

To register your MCP servers with Claude, modify the configuration file with entries for each server.

### Important: Full Paths Required

⚠️ **You must use the full absolute path to your Julia project and scripts**. The path should include:
1. The `--project` flag pointing to your ModelContextProtocol.jl directory
2. The full path to the script file

### Example Configuration

```json
{
  "mcpServers": {
    "time": {
      "command": "julia",
      "args": [
        "--project=/home/username/ModelContextProtocol",
        "/home/username/ModelContextProtocol/examples/time_server.jl"
      ],
      "env": {}
    },
    "mcp_tools_example": {
      "command": "julia",
      "args": [
        "--project=/home/username/ModelContextProtocol",
        "/home/username/ModelContextProtocol/examples/reg_dir.jl"
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

### Platform-Specific Path Examples

**macOS/Linux:**
```json
"args": [
  "--project=/home/username/julia_projects/ModelContextProtocol",
  "/home/username/julia_projects/ModelContextProtocol/examples/time_server.jl"
]
```

**Windows:**
```json
"args": [
  "--project=C:\\Users\\username\\Documents\\ModelContextProtocol",
  "C:\\Users\\username\\Documents\\ModelContextProtocol\\examples\\time_server.jl"
]
```

**Note:** Julia packages are typically cloned without the `.jl` extension. If you cloned via `Pkg.dev("ModelContextProtocol")`, check your `.julia/dev/` directory for the exact path.

Note: On Windows, use double backslashes (`\\`) in JSON strings.

For each server entry:

- `"time"`, `"mcp_tools_example"`: Unique identifiers for your servers (you choose these names)
- `"command"`: The command to run (should be `"julia"` for STDIO servers, `"npx"` for HTTP servers via mcp-remote)
- `"args"`: Array of arguments:
  - First argument: `"--project=/full/path/to/ModelContextProtocol"` (the package directory)
  - Second argument: Full path to your server script
- `"env"`: Optional environment variables (can be empty `{}`)

### Using HTTP Servers

For HTTP-based MCP servers, you need to:

1. Start your HTTP server separately:
   ```bash
   cd /path/to/ModelContextProtocol
   julia --project=. examples/simple_http_server.jl
   ```

   Or with full paths:
   ```bash
   julia --project=/home/username/ModelContextProtocol /home/username/ModelContextProtocol/examples/simple_http_server.jl
   ```

   Note: The directory is typically `ModelContextProtocol` without `.jl` extension.

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

1. **Verify full paths**: Ensure you're using absolute paths for both `--project` and the script file
2. **Check directory name**: Julia packages are cloned without `.jl` extension (e.g., `ModelContextProtocol` not `ModelContextProtocol.jl`)
3. **Check the server name**: Must match exactly what's in your configuration
4. **Verify the paths**:
   - Test your command in a terminal first:
     ```bash
     julia --project=/your/full/path/ModelContextProtocol /your/full/path/ModelContextProtocol/examples/time_server.jl
     ```
   - If this works in terminal, it should work in Claude
5. **Precompile dependencies**: Run this first to avoid timeout issues:
   ```bash
   cd /path/to/ModelContextProtocol
   julia --project=. -e "using Pkg; Pkg.instantiate(); using ModelContextProtocol"
   ```
6. **Check Claude's Developer Console**:
   - Open Claude Desktop
   - Press Cmd+Opt+I (Mac) or Ctrl+Shift+I (Windows/Linux)
   - Look for error messages in the Console tab

### Common Issues

- **"Package ModelContextProtocol not found"**: The `--project` path is incorrect
- **"No such file or directory"**: The script path is incorrect (check if directory has `.jl` extension or not)
- **Server timeout**: Julia compilation is slow on first run - precompile first
- **Windows path issues**: Remember to use double backslashes in JSON
- **Wrong directory name**: Package directories typically don't include `.jl` (use `ModelContextProtocol` not `ModelContextProtocol.jl`)


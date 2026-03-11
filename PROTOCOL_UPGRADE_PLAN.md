# MCP Protocol 2025-11-25 Upgrade Plan

## Vision

**Goal:** Make ModelContextProtocol.jl the defacto, full-featured MCP server package for Julia.

**Primary Use Case:** Remote MCP server for data analysis via Claude Desktop over public internet with GitHub OAuth authentication.

**Auth Model:** GitHub OAuth + allowlist of authorized GitHub usernames.

---

## Branch Strategy

```
main
 └── feature/protocol-2025-11-25 (base for all 2025-11-25 work)
      ├── feature/oauth-framework (OAuth 2.0 infrastructure)
      │    └── feature/github-oauth (GitHub provider + allowlist)
      ├── feature/tasks (experimental long-running operations)
      ├── feature/icon-metadata
      ├── feature/elicitation-enhancements
      └── ... (other features)
```

---

## Track A: Authorization (Critical Path)

### A1: OAuth 2.0 Framework

**Branch:** `feature/oauth-framework` (off protocol-2025-11-25)

**Goal:** Implement MCP authorization spec as Resource Server (token validator).

#### New Module: `src/auth/`
```
src/auth/
├── oauth.jl           # Core OAuth types and interfaces
├── token.jl           # Token validation (JWT, introspection)
├── middleware.jl      # HTTP middleware for auth
├── discovery.jl       # RFC 8414 / OpenID Connect discovery
└── metadata.jl        # Protected Resource Metadata (RFC 9728)
```

#### New Types
```julia
abstract type AuthProvider end
abstract type TokenValidator end

struct OAuthConfig
    issuer::String                    # Auth server URL
    audience::String                  # Expected audience claim
    allowed_scopes::Vector{String}    # Required scopes
    jwks_uri::Union{String,Nothing}   # For JWT validation
end

struct AuthenticatedUser
    subject::String                   # Unique user ID
    provider::String                  # "github", "google", etc.
    username::Union{String,Nothing}   # Human-readable name
    scopes::Vector{String}            # Granted scopes
    claims::Dict{String,Any}          # Raw token claims
end

struct AuthMiddleware
    config::OAuthConfig
    validator::TokenValidator
    allowlist::Union{Set{String},Nothing}  # Optional user allowlist
end
```

#### Tasks
1. Define auth types and interfaces
2. Implement JWT validation (using existing Julia JWT libraries)
3. Implement token introspection endpoint support
4. Add auth middleware for HTTP transport
5. Implement `.well-known/oauth-protected-resource` metadata endpoint
6. Add authorization error responses per MCP spec
7. Tests with mock tokens

#### Files to Create/Modify
- `src/auth/*.jl` - New auth module
- `src/transports/http.jl` - Integrate auth middleware
- `src/ModelContextProtocol.jl` - Export auth types
- `Project.toml` - Add JWT dependency

---

### A2: GitHub OAuth Provider

**Branch:** `feature/github-oauth` (off oauth-framework)

**Goal:** GitHub-specific OAuth with username allowlist.

#### New Types
```julia
struct GitHubAuthConfig <: AuthProvider
    client_id::String
    client_secret::String
    allowed_users::Set{String}        # GitHub usernames
    org_membership::Union{String,Nothing}  # Optional: require org membership
end
```

#### Flow
```
Claude Desktop                    Your MCP Server                GitHub
     │                                  │                           │
     │ 1. Connect                       │                           │
     │ ─────────────────────────────────▶                           │
     │                                  │                           │
     │ 2. 401 + WWW-Authenticate        │                           │
     │    (GitHub OAuth URL)            │                           │
     │ ◀─────────────────────────────────                           │
     │                                  │                           │
     │ 3. User authorizes via browser ──────────────────────────────▶
     │                                  │                           │
     │ 4. GitHub redirects with code    │                           │
     │ ◀────────────────────────────────────────────────────────────│
     │                                  │                           │
     │ 5. Exchange code for token       │                           │
     │ ─────────────────────────────────▶ ─────────────────────────▶│
     │                                  │                           │
     │ 6. Validate token + check        │                           │
     │    allowlist                     │◀─────────────────────────│
     │                                  │                           │
     │ 7. MCP session established       │                           │
     │ ◀─────────────────────────────────                           │
```

#### Tasks
1. GitHub OAuth token exchange
2. GitHub API integration (get username, check org membership)
3. Username allowlist checking
4. Configuration file format for allowed users
5. Token caching/refresh
6. Example server with GitHub auth

#### Files to Create
- `src/auth/providers/github.jl` - GitHub provider
- `examples/github_auth_server.jl` - Example
- `docs/src/authentication.md` - Auth documentation

---

## Track B: Protocol Compliance (2025-11-25)

### B1: Base Protocol Version Update

**Branch:** `feature/protocol-2025-11-25` (current)

#### Tasks
1. Update `SERVER_PROTOCOL_VERSION` to "2025-11-25"
2. Update HttpTransport default protocol_version
3. Update all tests
4. Support version negotiation (accept 2025-06-18 clients gracefully)
5. Bump package to 0.5.0

---

### B2: Tasks Support (Experimental) - SEP-1686

**Branch:** `feature/tasks` (off protocol-2025-11-25)

**Priority:** High - Enables long-running data analysis operations

#### New Types
```julia
@enum TaskState working input_required completed failed cancelled

struct MCPTask
    id::String
    state::TaskState
    progress::Union{Float64,Nothing}  # 0.0-1.0
    message::Union{String,Nothing}
    result::Union{Any,Nothing}
    error::Union{ErrorInfo,Nothing}
    created_at::DateTime
    updated_at::DateTime
end
```

#### New Methods
- `tasks/list` - List tasks for session
- `tasks/get` - Get task by ID
- `tasks/cancel` - Cancel task

#### Use Case
```julia
# Long-running analysis tool
tool = MCPTool(
    name = "analyze_dataset",
    handler = function(params, ctx)
        # Create task for long-running work
        task = create_task(ctx)

        @async begin
            update_task(task, state=working, message="Loading data...")
            # ... do work ...
            update_task(task, state=completed, result=analysis_result)
        end

        return TaskReference(task_id=task.id)
    end
)
```

---

### B3: Icon Metadata - SEP-973

**Branch:** `feature/icon-metadata` (off protocol-2025-11-25)

Add optional `icon` field to tools, resources, prompts.

---

### B4: Implementation Description

**Branch:** `feature/implementation-description` (off protocol-2025-11-25)

Add optional `description` field to server Implementation.

---

### B5: Elicitation Enhancements - SEP-1034, SEP-1036, SEP-1330

**Branch:** `feature/elicitation-enhancements` (off protocol-2025-11-25)

- Default values in primitives
- URL mode for OAuth flows (ties into Track A)
- Enhanced enum schema

---

### B6: Tool Calling in Sampling - SEP-1577

**Branch:** `feature/sampling-tools` (off protocol-2025-11-25)

Add `tools` and `toolChoice` to sampling requests.

---

### B7: SSE Stream Polling - SEP-1699

**Branch:** `feature/sse-polling` (off protocol-2025-11-25)

Server-initiated disconnect for polling support.

---

### B8: JSON Schema 2020-12 - SEP-1613

**Branch:** `feature/schema-dialect` (off protocol-2025-11-25)

Default schema dialect declaration.

---

## Implementation Order

### Sprint 1: Foundation
1. **B1** - Base protocol version update
2. **B4** - Implementation description (quick win)
3. **B3** - Icon metadata (quick win)

### Sprint 2: Authorization (Critical for Remote Use)
4. **A1** - OAuth framework
5. **A2** - GitHub OAuth provider

### Sprint 3: Long-Running Operations
6. **B2** - Tasks support
7. **B5** - Elicitation (URL mode needed for auth UX)

### Sprint 4: Polish
8. **B6** - Sampling tools
9. **B7** - SSE polling
10. **B8** - JSON Schema dialect

---

## Example: Complete Remote Server

```julia
using ModelContextProtocol

# GitHub OAuth configuration
auth = GitHubAuthConfig(
    client_id = ENV["GITHUB_CLIENT_ID"],
    client_secret = ENV["GITHUB_CLIENT_SECRET"],
    allowed_users = Set(["user1", "user2", "user3"])
)

# Create authenticated server
server = create_mcp_server(
    name = "DataAnalysis",
    version = "1.0.0",
    description = "Remote data analysis server for LidkeLab"
)

# Add data analysis tools
register_tool!(server, MCPTool(
    name = "query_database",
    description = "Query the analysis database",
    handler = (params, ctx) -> run_query(params["sql"])
))

# Start with HTTPS + GitHub auth
start_server(server, HttpTransport(
    host = "0.0.0.0",
    port = 443,
    tls = true,
    auth = auth
))
```

---

## Claude Desktop Configuration

```json
{
  "mcpServers": {
    "lidkelab-analysis": {
      "url": "https://analysis.lidkelab.org/mcp",
      "auth": {
        "type": "oauth",
        "provider": "github"
      }
    }
  }
}
```

---

## Dependencies to Add

```toml
[deps]
# Existing
HTTP = "..."
JSON3 = "..."

# New for auth
JWTs = "..."           # JWT parsing/validation
OAuth2 = "..."         # OAuth client (or implement minimal)
```

---

## Testing Strategy

### Auth Testing
1. Mock GitHub OAuth responses
2. Test token validation with valid/invalid/expired tokens
3. Test allowlist enforcement
4. Integration test with real GitHub (manual/CI secret)

### Protocol Testing
1. MCP Inspector validation
2. Claude Desktop integration testing
3. Python SDK interop tests

---

## Documentation Plan

1. **Getting Started** - Simple local server
2. **Remote Deployment** - HTTPS, reverse proxy, systemd
3. **Authentication** - GitHub OAuth setup guide
4. **API Reference** - All types and functions
5. **Examples** - Common patterns
6. **Troubleshooting** - Common issues

---

## Success Criteria

- [ ] Claude Desktop can connect to remote server over HTTPS
- [ ] GitHub OAuth flow works end-to-end
- [ ] Only allowlisted users can access
- [ ] Full 2025-11-25 protocol compliance
- [ ] Comprehensive documentation
- [ ] Published to Julia General registry

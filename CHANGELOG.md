# Changelog

All notable changes to ModelContextProtocol.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`JWKSValidator` — JWT signature verification against a JWKS endpoint (RFC 7517)**:
  the recommended validator for tokens from external authorization servers (Keycloak,
  Auth0, …). Verifies RSA signatures (`RS256`/`RS384`/`RS512` allowlist; `alg=none` and
  non-allowlisted algorithms rejected before any cryptography), then applies the same
  fail-closed claim checks as `JWTValidator` (iss, aud, exp, nbf, scopes). Keys load
  lazily and re-fetch on unknown `kid` (rotation), rate-limited to one fetch per
  `refresh_interval_seconds` (default 300) so attacker-supplied `kid` values cannot
  hammer the JWKS endpoint; fetches use bounded HTTP timeouts, a streaming response
  size cap (1 MB), and happen outside the validator lock. Plaintext `http://` JWKS
  URLs are rejected at construction (a MITM could swap signing keys) unless
  `allow_insecure_http=true` is passed for localhost/testing; `https://` and `file://`
  key sets plus pre-built `JWTs.JWKSet` injection are supported. A malformed upstream
  JWKS document fails authentication closed (retaining cached keys) rather than
  erroring the request. New dependency: JWTs.jl.

## [0.5.4] - 2026-06-10

### Added

- **Resource URI templates** (closes #63): `ResourceTemplate` now carries a
  `data_provider`, and a `resources/read` whose URI matches no exact resource is routed
  through the registered templates (RFC 6570 level-1 `{var}` placeholders, one path
  segment each). The provider receives the requested URI — `provider(uri)` — or opts
  into `provider(uri, vars)` for the extracted placeholder values; return values follow
  the same contract as resource providers. Templates are advertised via the spec's
  `resources/templates/list`, registered through `mcp_server(resource_templates=…)` or
  `register!(server, template)`. Exact-URI resources take precedence. Requested by the
  aimg downstream for content-addressed artifact namespaces.
- **Binary and rich resource contents** (closes #59): `resources/read` now serializes
  `TextResourceContents`/`BlobResourceContents` (or a vector of them) returned from a
  resource's `data_provider` directly to the spec wire shape — `BlobResourceContents`
  makes binary resources servable for the first time (base64 `blob` contents entry,
  per-entry `uri`/`mimeType`). Plain data keeps the JSON-encoded text fallback. This
  pairs with `ResourceLink` tool results: link to a large artifact, read the binary
  via `resources/read`.

### Fixed

- A `String` returned from a `data_provider` is now used as the text contents verbatim
  instead of arriving JSON-quoted (`"\"…\""`).

## [0.5.3] - 2026-06-10

### Added

- **MCP Tasks (SEP-1686, experimental)** — spec-native support for long-running tool
  calls (protocol 2025-11-25). Clients augment `tools/call` with `"task": {"ttl": …}`;
  the server answers immediately with a `CreateTaskResult` while the handler runs in a
  background Julia task, then serves `tasks/get` (status polling), `tasks/result`
  (blocks until terminal, then returns exactly what the call would have returned, with
  the spec's `io.modelcontextprotocol/related-task` `_meta`), `tasks/cancel`
  (terminal-state cancels rejected with -32602), and cursor-paginated `tasks/list`.
  Optional `notifications/tasks/status` fire on terminal transitions over the
  transport-correct channel (stdout / SSE).
  - Tools opt in via `MCPTool(task_support = :optional)` (or `:required`); the default
    `:forbidden` rejects task-augmented calls with -32601 per spec, and `:required`
    tools reject synchronous calls likewise. Advertised per tool as
    `execution.taskSupport` in `tools/list`.
  - The `tasks` capability (with the spec's `requests.tools.call` shape) is only
    advertised to clients that negotiated 2025-11-25; older sessions get the
    spec-mandated fallback — task metadata ignored, synchronous execution.
  - Security per spec: tasks are bound to the authenticated principal when HTTP auth
    is enabled (cross-principal access is indistinguishable from not-found), task ids
    are cryptographically random, and `tasks/list` is withheld on unauthenticated HTTP
    where requestors cannot be identified.
  - TTLs are clamped to a server maximum (1h; default 5min), expired terminal tasks
    are swept, and a cancelled task stays cancelled even if its work later completes
    (the late result is discarded).
  - New exported helper `task_cancelled(ctx)` lets context-aware handlers observe
    cancellation cooperatively; `send_progress(ctx, …)` keeps working for the task's
    lifetime via the original request's `progressToken`.
  - Internals: a blocking `tasks/result` cannot occupy the serial server loop (it
    would deadlock against the very `tasks/cancel` that unblocks it), so handlers can
    now defer a response and deliver it out-of-loop via the new transport pair
    `capture_response_route`/`deliver_response` — on HTTP the original POST simply
    stays open (spec-blocking for free); on stdio writes are serialized by a new
    transport write lock, and the HTTP per-request channel registry is lock-guarded
    against concurrent access from connection tasks and waiters. Disconnect-driven
    cleanup of a blocked `tasks/result` is tracked in #61 (retention is bounded by
    task lifetime).

### Documentation

- Fixed the documented MCP Inspector invocation: `inspector stdio -- <command>` made the
  Inspector spawn a program literally named `stdio` (`spawn stdio ENOENT`, #53); the
  server command is now passed directly (UI mode) or after `--cli`.
- Docs audit pass against 0.5.2 reality (fixes #53 fallout plus staleness the 0.5.2
  refresh missed): `api_overview.md` no longer claims 2025-06-18-only/no-negotiation,
  teaches the current `ResourceLink` shape (`uri`/`name`, wire type `resource_link`),
  documents `AudioContent`, `CallToolResult.structured_content`/`_meta`, OAuth kwargs on
  `HttpTransport`, and the two-arg `(args, ctx)` handler form it previously called
  invalid; `docs/src/api.md` drops the stale "ResourceLink not yet exported" note;
  `examples/README.md` drops references to example files that don't exist;
  `examples/CLAUDE.md` and `docs/CLAUDE.md` templates rewritten from the fictional
  `Server(...)`/`add_tool!` API to the real `mcp_server`/`register!` API.
- Resource docs now state the actual `data_provider` contract (called with no arguments,
  return value JSON-encoded into text contents) and the current limitations (exact-URI
  matching only; no binary contents via `resources/read` — see #59); the previous
  `data_provider = function(uri)` examples returning `TextResourceContents`/
  `BlobResourceContents` never worked.
- `simple_http_server.jl` and `reg_dir_http.jl` no longer print a hardcoded stale
  protocol version; they report `LATEST_PROTOCOL_VERSION`.

## [0.5.2] - 2026-06-09

### Added

- **PrecompileTools workload** covering the request hot path (`parse_message` → dispatch
  for initialize / tools / prompts / resources / ping → serialize), so a fresh server
  answers its first request without runtime JIT. Cold start-to-first-`tools/call`
  drops ~2.7× (≈4.2s → ≈1.5s measured over stdio; remainder is package load and the
  non-precompilable socket path).
- **`logging/setLevel`** (closes #24, finishing the intent of #17): clients adjust the
  installed `MCPLogger`'s minimum level at runtime using the eight MCP/RFC-5424 levels;
  unknown levels return `INVALID_PARAMS`. The `logging` capability is now advertised by
  default.
- **Request-lifecycle logging**: every request emits a `request completed` log line with
  `method`, `id`, `duration_ms`, and `ok` — at Debug level, so servers stay quiet by
  default; enable at runtime with `logging/setLevel "debug"`.

### Fixed

- `logging/setLevel` re-installs the logger so the change actually reaches the log
  macros: `global_logger` caches `min_enabled_level` at install time, so mutating the
  logger's field alone is silently ignored (found by live-server testing; now also
  covered by a wire-conformance e2e test).

### Documentation

- README, `docs/src` guides, and `api_overview.md` refreshed to 0.5.x reality, including
  fixes for examples that never worked (`MCPResource(handler=…)` → `data_provider`,
  `MCPPrompt(handler=…)` → `messages`, `mcp_server(transport=…)` → set `server.transport`),
  a new HTTP authentication section, and tools-guide sections for structured output,
  annotations, context-aware handlers + progress, and audio/resource_link results.

## [0.5.1] - 2026-06-09

### Added

- `AudioContent` — the third media content type (`{"type": "audio", "data": ..., "mimeType": ...}`),
  usable in tool results and prompt messages.
- `PromptMessage` content accepts the full spec ContentBlock union: `AudioContent` and
  `ResourceLink` joined `TextContent`/`ImageContent`/`EmbeddedResource`.
- `ResourceLink` gained the spec's optional `size` field (bytes).
- `serverInfo.description`: `mcp_server(; description = ...)` is now emitted in the initialize
  response (MCP 2025-11-25). The `Implementation` type (clientInfo) gained optional
  `title`/`description` fields.
- `_meta` on component definitions — `MCPTool`, `MCPResource`, and `MCPPrompt` accept
  `_meta::Dict{String,Any}`, emitted verbatim in the corresponding `*/list` entries — and on
  `CallToolResult` (omitted when unset).
- Tool input schemas generated from `ToolParameter` lists now declare the JSON Schema
  **2020-12** dialect via `"$schema"`; a raw `input_schema` still passes through verbatim.

### Fixed

- **`ResourceLink` now serializes to the MCP spec wire format**
  `{"type": "resource_link", "uri": ..., "name": ..., "description": ..., "mimeType": ...}`.
  Previously it emitted a non-spec `{"type": "link", "href": ...}` shape that compliant clients
  ignored, so the type never interoperated. The Julia struct changed accordingly
  (`href` → `uri`, new required `name`, optional `description`/`mime_type`) — technically a
  field change, shipped as a patch because the old form was unusable with any compliant client
  and had no observed usage. Found via AIMicroGraph remote-demo field feedback.
- The HTTP `MCP-Protocol-Version` **response header now echoes the negotiated version** after
  `initialize` (previously a static per-transport default, so a client negotiating an older
  version saw a mismatched header). New transport hook: `set_negotiated_version!`.
- **`prompts/get` now serializes media content in the spec wire format** (base64 `data` +
  `mimeType`, via `content2dict`) — previously image (and would-be audio) prompt messages
  leaked raw Julia struct fields (`mime_type`, integer byte arrays), which compliant clients
  could not consume. `prompts/get` results are now plain JSON objects rather than
  `GetPromptResult` structs.
- **`prompts/get` without `arguments` no longer errors.** The no-arguments path passed a
  `LittleDict` to `process_template`, which was typed `::Dict` and threw a `MethodError`
  (surfacing to clients as an internal error for any text prompt fetched argument-free).
  Found by live-server testing; affected 0.5.0 and earlier.

### Notes

- Docstring guidance added: a tool returning `structuredContent` SHOULD also include a
  human-readable serialization in `content` for clients that don't consume structured output.

## [0.5.0] - 2026-06-09

### Added

#### Protocol Version Negotiation (MCP 2025-11-25)
- Server now advertises and negotiates the **2025-11-25** protocol version, with backward
  compatibility for `2025-06-18`, `2025-03-26`, and `2024-11-05`.
- New `src/protocol/versioning.jl` module providing the negotiation/feature-gating framework:
  - `LATEST_PROTOCOL_VERSION`, `SUPPORTED_PROTOCOL_VERSIONS`, `FEATURE_VERSIONS`
  - `negotiate_version(client_version)` — echo a supported version, else fall back to latest
  - `supports(version, feature)` — feature gating by negotiated version
  - `is_supported_version(version)`
- All six symbols are exported for use in handlers and downstream code.

#### OAuth Resource Server (MCP 2025-11-25 authorization)
- Optional bearer-token authentication for the Streamable HTTP transport via new
  `HttpTransport(; auth, resource_metadata)` keywords. The default is unauthenticated (unchanged).
- Token validators: `SimpleTokenValidator` (static dev tokens), `JWTValidator` (validates JWT
  *claims* — **does not verify signatures**; see its docstring warning), `IntrospectionValidator`
  (RFC 7662), and `GitHubOAuthValidator` (validates GitHub tokens via the API, with optional
  username allowlist and org-membership check).
- Protected Resource Metadata discovery (RFC 9728) at `/.well-known/oauth-protected-resource`
  (served publicly); `401`/`403` responses carry an RFC 6750 `WWW-Authenticate` header pointing to it.
- **Per-request auth context**: the authenticated user is threaded per request into
  `RequestContext.authenticated_user` (no shared transport state, so concurrent requests can't
  race on identity). Tool handlers may opt into a context-aware form `handler(args, ctx)` (plain
  `handler(args)` still works) to read it.
- Helpers exported: `create_simple_auth`, `create_auth_middleware` (requires an explicit
  validator — no unsafe default), `disable_auth`, `create_protected_resource_metadata`,
  `create_github_resource_metadata`, `authenticate_request`, `extract_bearer_token`, `is_auth_enabled`.
- **Security posture** (validators fail closed): `JWTValidator` rejects `alg=none`, requires a
  valid `exp`, and enforces `iss`/`aud` when configured; `IntrospectionValidator` binds `iss`/`aud`
  when present; `GitHubOAuthValidator` requires `state == "active"` for org membership; auth error
  responses are generic (no token/policy oracle).
- This is the **Resource Server** slice of the OAuth work (PR #27). Deferred follow-ups: JWKS
  signature verification for `JWTValidator`, SSE session-principal binding + stream expiry,
  per-tool scope enforcement, case-insensitive allowlists, and the OAuth 2.1 **Authorization
  Server** (token issuance — DCR, PKCE; tracked in #51).

#### Tool Annotations (#44 — thanks @samtalki)
- `MCPTool(; annotations = Dict("readOnlyHint" => true, ...))` — optional behavioral-hint
  object (`readOnlyHint` / `destructiveHint` / `idempotentHint` / `openWorldHint`) emitted
  verbatim in `tools/list` for client trust and approval decisions.

#### Structured Tool Output (#45, #49 — thanks @samtalki)
- `MCPTool(; output_schema = Dict(...))`, emitted as `outputSchema` in `tools/list`.
- `CallToolResult(; structured_content = Dict(...))`, serialized as `structuredContent` and
  omitted when `nothing`. Typed as a JSON object (`AbstractDict`) per the spec. Pair the two
  so clients can validate and consume tool results programmatically.

#### Progress Notifications from Tool Handlers (#50, from #46 — thanks @samtalki; closes #33)
- Tool handlers may opt into the context-aware form `(args, ctx)` and call
  `send_progress(ctx, progress; total, message)` to emit `notifications/progress` during a
  long-running call. Returns `false` as a safe no-op when the client sent no `progressToken`
  or no transport is connected, so it can be called unconditionally.
- `parse_request` now extracts `params._meta.progressToken` into the request metadata
  (previously dropped), so the token actually reaches handlers.
- New transport-polymorphic `send_notification`: stdio writes to stdout (notifications and
  responses share one stream); Streamable HTTP queues to the SSE notification stream —
  out-of-band from request/response, so a mid-request notification cannot corrupt that
  request's response.

#### Feature Gating in Handlers (#39)
- The negotiated protocol version is persisted in `ServerState.protocol_version` and exposed
  to handlers as `ctx.state`, enabling `supports(ctx.state.protocol_version, :feature)`.

#### End-to-End Test Harness (#40)
- `test/e2e/` spawns the shipped example servers as real subprocesses (stdio + Streamable
  HTTP) and drives the MCP handshake against them. Runs locally by default, skipped on the
  PR CI matrix, exercised nightly by `.github/workflows/e2e.yml`; force either way with
  `MCP_TEST_E2E=true|false`.

### Changed

- `handle_initialize` now responds with the **negotiated** protocol version instead of a
  hardcoded `2025-06-18`. Clients requesting a supported version get it echoed back; unknown
  versions fall back to `LATEST_PROTOCOL_VERSION`.
- `HttpTransport` now defaults `protocol_version` to `LATEST_PROTOCOL_VERSION` (`2025-11-25`)
  and accepts any version in `SUPPORTED_PROTOCOL_VERSIONS` for the `MCP-Protocol-Version` header.

### Fixed

- Tool handlers returning a `Dict`, `String`, or `Tuple{Vector{UInt8},String}` are now
  auto-wrapped into `Content` regardless of the declared `return_type`, matching the
  documented contract — previously these converted only when `return_type == TextContent`,
  so the default `Vector{Content}` raised `ArgumentError`. Fixes #34.
- `CallToolResult` now serializes its error flag under the MCP wire key **`isError`**
  (previously `is_error`, which spec-compliant clients do not read — tool errors looked
  like successes to them). The Julia field name is unchanged. (#49)

### Notes

- 0.5.0 was assembled incrementally from the larger OAuth 2.1 / 2025-11-25 work (PR #27):
  protocol negotiation, `ServerState`-based feature gating, and the OAuth Resource Server have
  landed. The OAuth 2.1 **Authorization Server** (token issuance — DCR, PKCE) remains a
  follow-up, tracked in #51.
- Tool annotations, structured output, and progress notifications were community
  contributions by @samtalki (#44, #45, #46/#50). Thank you!

## [0.4.1] - 2026-03-12

### Added

- `title` and `icons` metadata (MCP 2025-11-25) on servers, tools, resources, and prompts via
  new `MCPIcon` type; emitted in `serverInfo` and the `*/list` responses, omitted when unset. (#28)

### Fixed

- HTTP transport accepts health-check style requests more leniently, for Claude Code
  compatibility (thanks @GiggleLiu, #26).

## [0.4.0] - 2025-12-14

### Added

- `MCPTool(; input_schema = Dict(...))` — raw JSON Schema for complex tool parameter types,
  as an alternative to the `ToolParameter` list. (#23)

### Fixed

- Protocol version negotiation corrected per the MCP spec. (#21)

## [0.3.0] - 2025-11-16

### Breaking Changes

#### Server Version Default
- **BREAKING**: `mcp_server(...)` `version` parameter default changed from `"2024-11-05"` to `"1.0.0"`
  - **Rationale**: The version field represents YOUR server's implementation version, not the MCP protocol version
  - **Migration**: If you relied on the default, explicitly specify `version = "2024-11-05"` or update to semantic versioning
  - **Example**:
    ```julia
    # Old (implicit default)
    server = mcp_server(name = "my-server")  # version was "2024-11-05"

    # New (explicit version recommended)
    server = mcp_server(name = "my-server", version = "1.0.0")
    ```

#### Protocol Version Enforcement
- **BREAKING**: MCP protocol version `2025-06-18` is now strictly enforced
  - Only accepts `MCP-Protocol-Version: 2025-06-18` header
  - Returns error `-32600` (INVALID_REQUEST) for unsupported versions
  - **Migration**: Ensure clients send correct protocol version header

#### JSON-RPC Batching Removed
- **BREAKING**: JSON-RPC batch requests now return error per MCP 2025-06-18 specification
  - Batch arrays are explicitly rejected with error code `-32600`
  - **Migration**: Send requests one at a time instead of batching
  - **Example**:
    ```julia
    # Old (no longer supported)
    [{"jsonrpc":"2.0","method":"tools/list","id":1},
     {"jsonrpc":"2.0","method":"resources/list","id":2}]

    # New (send separately)
    {"jsonrpc":"2.0","method":"tools/list","id":1}
    # then
    {"jsonrpc":"2.0","method":"resources/list","id":2}
    ```

#### Auto-Registration File Format
- **BREAKING**: Auto-registered component files must have the component as the **last expression**
  - Old behavior: Searched all module variables for matching types
  - New behavior: Uses `include()` return value (last expression)
  - **Migration**: Ensure your component definition is the last line in the file
  - **Example**:
    ```julia
    # Old (may have worked)
    using ModelContextProtocol
    const my_tool = MCPTool(...)
    println("Tool loaded")  # Last expression

    # New (required format)
    using ModelContextProtocol  # Auto-imported by auto_register!
    println("Loading tool...")

    MCPTool(...)  # Must be last expression
    ```

### Added

#### HTTP Transport with SSE
- Full Streamable HTTP transport implementation following MCP specification
- Server-Sent Events (SSE) for real-time streaming via GET requests
- Session management with `Mcp-Session-Id` headers
- Origin validation and security features
- Connection lifecycle management
- Example: `examples/simple_http_server.jl`

#### Auto-Registration System
- Directory-based component organization (`tools/`, `resources/`, `prompts/`)
- Automatic discovery and loading of components
- Proper error handling and logging
- Support for both stdio and HTTP transports
- Example: `examples/reg_dir.jl`, `examples/reg_dir_http.jl`

#### New Content Types
- `ResourceLink`: Reference resources in tool results (MCP 2025-06-18 feature)
- Enhanced content serialization with `content2dict()`

#### Documentation
- Comprehensive transport documentation (`docs/src/transports.md`)
- Auto-registration guide (`docs/src/auto-registration.md`)
- Claude Desktop integration guide (`docs/src/claude.md`)
- Improved API documentation with multi-transport examples
- Fixed broken examples in documentation

### Changed

#### Transport Abstraction
- Introduced `Transport` abstract type with `StdioTransport` and `HttpTransport` implementations
- `start!(server)` now accepts optional `transport` parameter (defaults to `StdioTransport()`)
- **Note**: This is NOT a breaking change - `start!(server)` still works as before
- Server loop now uses transport abstraction (`read_message`, `write_message`)

#### Improved Error Handling
- Better error messages for protocol violations
- Proper error responses for unsupported features
- Enhanced logging with structured metadata

#### Test Suite
- Added comprehensive HTTP transport tests
- Added protocol compliance tests
- All 233 tests passing

### Fixed

- Auto-registration for Julia 1.12+ world age changes (backward compatible)
- SSE streaming test failures
- Inspector CLI compatibility issues
- Examples now work correctly in stdio mode
- Documentation examples now execute successfully

### Internal

- Refactored type system consolidation
- Improved server lifecycle management
- Enhanced MCP-compliant logging
- Better separation of protocol vs server version

## [0.2.1] - 2025-08-01

### Changed
- Reorganized test suite following Julia conventions
- Integrated API documentation into help system
- Bump version for API documentation improvements

## [0.2.0] - 2025-07-28

### Changed
- Changed default `MCPTool` `return_type` to `Vector{Content}` (breaking change for tools expecting single content validation)
- Updated tool handler system to support multi-content returns

## [0.1.0] - 2025-06-18

### Added
- Initial release
- Core MCP server implementation
- Tools, Resources, and Prompts support
- stdio transport
- Basic protocol compliance

[Unreleased]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.5.4...HEAD
[0.5.4]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.3.1...v0.4.0
[0.3.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/releases/tag/v0.1.0

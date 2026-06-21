# Authentication

This page documents how `ModelContextProtocol.jl` authenticates HTTP requests. It is
precise about what the package does and — just as importantly — what it does **not**
do, because the security of your server depends on understanding the boundary.

## What this package is, and is not

The package implements an **OAuth 2.1 *Resource Server* (RS)** for the Streamable HTTP
transport, per the MCP 2025-11-25 authorization specification:

- It **validates** bearer tokens presented on incoming requests (signature and/or
  claims, or remote introspection).
- It advertises where tokens come from via **RFC 9728 Protected Resource Metadata**.
- It attaches the authenticated principal to each request so tool handlers can make
  authorization decisions.

It is **not an Authorization Server (AS)**. It does not issue tokens, run login or
consent screens, implement Dynamic Client Registration, or handle PKCE redirects. Those
are the job of an external AS — Keycloak, Auth0, Okta, an in-house IdP, or GitHub. The
[Deployment](@ref) guide walks through standing one up end-to-end. The division is
deliberate: a Resource Server is a small, auditable surface; an Authorization Server is
thousands of lines of security-critical token machinery that you should not hand-roll.

The stdio transport is unauthenticated by design — it is a local subprocess pipe, so
the trust boundary is the operating system, not a token. Everything below concerns the
HTTP transport.

## The request lifecycle

When auth is configured on the HTTP transport, every request (except the public
metadata endpoint, below) goes through `authenticate_request`:

1. **Extract** the bearer token from the `Authorization: Bearer <token>` header.
   A missing header → `401`; a malformed header → `401`.
2. **Validate** the token with the configured [`TokenValidator`](@ref). What this
   checks depends on the validator (signature, claims, or remote introspection).
3. **Allowlist** (optional): if an allowlist is set, the authenticated principal's
   username *or* subject must be in it, otherwise `403`.
4. On success, the [`AuthenticatedUser`](@ref) is carried to the tool handler as
   `ctx.authenticated_user`.

Failures never reveal *why* a token was rejected (expired vs. wrong issuer vs. bad
signature vs. which scope is missing). The client receives a fixed, generic OAuth error
so the endpoint cannot be used as a token/policy oracle; the specific reason is retained
only for server-side logging.

| Outcome | HTTP status | `WWW-Authenticate` |
|---|---|---|
| No token | `401` | `Bearer resource_metadata="…"` |
| Invalid/expired/forged token | `401` | `Bearer error="invalid_token", …` |
| Valid token, missing scope or not allowlisted | `403` | `Bearer error="insufficient_scope", …` |

When `resource_metadata` is configured on the transport (strongly recommended whenever
auth is enabled), the `WWW-Authenticate` header points the client at the Protected
Resource Metadata document (below) — how a compliant client discovers your Authorization
Server and starts a token flow. Without it the header still signals the error but carries
no discovery pointer.

## Wiring auth into the HTTP transport

Two keyword arguments on the HTTP transport turn auth on:

```julia
using ModelContextProtocol

auth = create_auth_middleware(
    OAuthConfig(
        issuer   = "https://auth.example.org/realms/main",   # expected `iss`
        audience = "https://mcp.example.org/mcp",             # expected `aud`
        required_scopes = ["mcp:read"],                       # required on every request
    ),
    validator = JWKSValidator("https://auth.example.org/realms/main/protocol/openid-connect/certs"),
    allowlist = Set(["alice", "bob"]),                        # optional
)

meta = ProtectedResourceMetadata(
    resource = "https://mcp.example.org/mcp",
    authorization_servers = ["https://auth.example.org/realms/main"],
    scopes_supported = ["mcp:read"],
)

server = mcp_server(name = "secure-server", tools = [...])
server.transport = HttpTransport(host = "127.0.0.1", port = 8080,
                                 auth = auth, resource_metadata = meta)
connect(server.transport)
start!(server)
```

- `auth::Union{AuthMiddleware,Nothing}` — `nothing` (the default) disables auth.
- `resource_metadata::Union{ProtectedResourceMetadata,Nothing}` — served, unauthenticated,
  at the transport's `/.well-known/oauth-protected-resource` path (clients must read it
  *before* they have a token). Note the distinction between that backend path and the
  **advertised** URL: the URL in `WWW-Authenticate` is built from the metadata's `resource`
  field — `<resource>/.well-known/oauth-protected-resource` — so with
  `resource = "https://mcp.example.org/mcp"` clients are pointed at
  `https://mcp.example.org/mcp/.well-known/oauth-protected-resource`. Make sure your proxy
  routes that public path back to the transport (see [Deployment](@ref)).

!!! warning "Bind address vs. exposure"
    `HttpTransport` does not terminate TLS and does no network-level access control.
    Put it behind a TLS-terminating reverse proxy (see [Deployment](@ref)) and bind it
    to `127.0.0.1` (or a LAN address the proxy can reach), never directly to a public
    interface.

## `OAuthConfig`

`OAuthConfig` describes what a *valid* token must look like, independent of how it is
verified:

```julia
OAuthConfig(;
    issuer::String,                                   # expected `iss` claim
    audience::String,                                 # expected `aud` claim (your resource)
    required_scopes::Vector{String} = String[],       # all must be present on every request
    jwks_uri::Union{String,Nothing} = nothing,        # informational
    introspection_endpoint::Union{String,Nothing} = nothing,  # used by IntrospectionValidator
)
```

`issuer` and `audience` are **fail-closed**: when set, a token that lacks a matching
`iss`/`aud` is rejected (a forged token cannot pass by simply *omitting* the claim).
`audience` matches a string `aud` exactly, or membership when `aud` is an array. Leave a
field empty (`""`) only if you deliberately want to skip that check.

`required_scopes` is checked on every request by the claims-based validators —
`JWTValidator`, `JWKSValidator`, and `IntrospectionValidator` (they read the token's
`scope`/`scp`). The `SimpleTokenValidator` and `GitHubOAuthValidator` do **not** consult
`OAuthConfig.required_scopes`; with those, enforce authorization through the allowlist or
in your handlers. For *per-tool* scopes (a write tool that needs `mcp:write` while reads
need only `mcp:read`), declare `MCPTool(required_scopes = [...])` — see
[Per-tool authorization](@ref) below.

## The validator ladder

A [`TokenValidator`](@ref) decides whether a token is genuine. Pick by token type and
trust model — they are ordered here from least to most appropriate for tokens from an
*external* issuer.

| Validator | Token type | Verifies | Use when |
|---|---|---|---|
| `SimpleTokenValidator` | opaque string | static map lookup | dev / trusted static API keys |
| `JWTValidator` | JWT | claims only — **no signature** | dev/test, or behind a gateway that already verified the signature |
| `JWKSValidator` | JWT | **signature (JWKS) + claims** | tokens from an external AS — **recommended** |
| `IntrospectionValidator` | opaque or JWT | remote call to the AS (RFC 7662) | opaque tokens you can't verify locally |
| `GitHubOAuthValidator` | GitHub access token | GitHub `/user` API call | authenticating GitHub users directly |

### `JWKSValidator` — signature verification (recommended)

```julia
JWKSValidator(jwks_uri::String;
              allowed_algs = ["RS256", "RS384", "RS512"],
              clock_skew_seconds = 60,
              refresh_interval_seconds = 300,
              allow_insecure_http = false)
JWKSValidator(keyset::JWTs.JWKSet; kwargs...)   # pre-built / static key set
```

Verifies the token's RSA signature against the issuer's JSON Web Key Set
([RFC 7517](https://datatracker.ietf.org/doc/html/rfc7517)), then applies the same fail-closed
claim checks as `JWTValidator`. This is the correct choice for any token minted by an
external Authorization Server. Security-relevant behavior, in order:

- **Algorithm allowlist, before any cryptography.** A token whose header `alg` is not in
  `allowed_algs` is rejected immediately. This is what blocks the classic `alg=none`
  bypass and the RS256→HS256 key-confusion attack. The default permits the RSA family
  only; do **not** add `HS*` (HMAC) algorithms for keys published in a public JWKS.
- **`kid` required.** Tokens without a key id are rejected — the validator never guesses
  which key to use.
- **Lazy, rate-limited key loading.** Construction never touches the network, so the
  server starts even while the AS is down (requests fail closed until keys load). An
  unknown `kid` triggers at most one JWKS re-fetch per `refresh_interval_seconds`
  (default 300), so an attacker spraying random `kid` values cannot hammer the JWKS
  endpoint. Fetches use bounded timeouts, a 1 MB response cap, and never hold the
  validator's lock during network I/O.
- **Plaintext rejected.** An `http://` JWKS URL is refused at construction (a network
  attacker could swap in their own signing key) unless you pass `allow_insecure_http =
  true` for localhost/testing. `https://` and `file://` URLs, and a directly-injected
  `JWTs.JWKSet`, are supported.
- **Malformed upstream fails closed.** A garbage or oversized JWKS document fails
  authentication while *retaining* the previously cached keys, rather than erroring the
  request or dropping all keys.

`clock_skew_seconds` (default 60) is the tolerance applied to `exp`/`nbf`: a token is
only rejected once it is more than `clock_skew_seconds` past its expiry. This is
standard practice for cross-host clock drift; lower it if your RS and AS share a clock.

### `JWTValidator` — claims only (no signatures)

```julia
JWTValidator(; insecure_skip_signature_verification = true, clock_skew_seconds = 60)
```

!!! danger "No signature verification — explicit opt-in required"
    `JWTValidator` decodes and validates JWT claims but does **not** verify the
    cryptographic signature. Because the signature is unchecked, *any* caller can forge a
    token carrying the expected `iss`/`aud`/scopes — "trusting the issuer" is not, by
    itself, enough (it rejects `alg=none`, but that is no substitute for verification). To
    prevent accidental insecure deployment it **refuses to construct** unless you pass
    `insecure_skip_signature_verification = true`. Use it only in development/testing, or
    when a trusted component in front of the server (e.g. a gateway) has *already* verified
    the signature. For tokens that arrive directly from a client, use [`JWKSValidator`](@ref).

### `IntrospectionValidator` — RFC 7662

```julia
IntrospectionValidator(; client_id = nothing, client_secret = nothing)
```

POSTs the token to the AS's introspection endpoint (`OAuthConfig.introspection_endpoint`)
and trusts the AS's verdict. Appropriate for **opaque** tokens that cannot be validated
locally. It enforces `active == true`, and binds `iss`/`aud` fail-closed when those are
configured (so a token active at a shared AS but minted for a different resource cannot be
replayed against yours). A numeric `exp` in the response, if present, must be in the
future — but the validator does **not** *require* the AS to return `exp`. Each request is a
network round-trip to the AS.

### GitHub

```julia
auth = create_github_auth(;
    allowed_users = ["alice", "bob"],   # GitHub logins; empty = any authenticated user
    required_org  = "JuliaSMLM",         # optional: require *active* org membership
    cache_ttl_seconds = 300)
```

Validates a GitHub access token by calling GitHub's `/user` API, with a short-lived
cache. `required_org` additionally requires **active** (not pending) membership in the
named organization. This authenticates GitHub users *directly* against the package — a
different model from brokering GitHub through an Authorization Server (which is what the
[Deployment](@ref) guide does, and which the package sees as ordinary JWTs).

## Assembling the middleware

[`create_auth_middleware`](@ref) ties an `OAuthConfig` to a validator:

```julia
create_auth_middleware(config::OAuthConfig;
                       validator::TokenValidator,                 # REQUIRED — no default
                       allowlist::Union{Set{String},Nothing} = nothing,
                       enabled::Bool = true) -> AuthMiddleware
```

`validator` is **required and has no default** — the package will never silently select
an unsafe validator for you. Two convenience constructors exist:
[`create_simple_auth`](@ref) (a `Dict` of API keys → usernames) and
[`disable_auth`](@ref) (an explicit, clearly-named no-op for development).

## Allowlists

When an `allowlist::Set{String}` is configured, a successfully authenticated principal
must additionally have its **username or subject** in the set, or the request is `403`.
This is the simplest authorization model: "valid token *and* on the list."

!!! note "Username matching is case-insensitive; subjects are exact"
    By default the `username` comparison is **case-insensitive**
    (`case_insensitive_allowlist = true`), because brokered identity normalizes case —
    Keycloak, for example, lowercases federated usernames, so a GitHub login `Alice`
    arrives as `alice` in the token. The opaque OAuth `subject` is **always** matched
    exactly (case-folding a stable identifier could collide two principals). Pass
    `case_insensitive_allowlist = false` (on `AuthMiddleware` or any `create_*_auth`
    constructor) for exact username matching.

## Per-tool authorization

`OAuthConfig.required_scopes` gates the *whole server*. To require a scope for a
*specific* tool, declare `required_scopes` on the tool:

```julia
MCPTool(
    name = "delete_record",
    description = "Delete a record.",
    parameters = [ToolParameter(name = "id", description = "record id", type = "string", required = true)],
    required_scopes = ["mcp:write"],
    handler = (args) -> TextContent(text = "deleted $(args["id"])"),
)
```

At `tools/call` dispatch — before the handler runs, and before the task/sync split so
both execution paths are gated — every scope in `required_scopes` must be present on the
authenticated principal's `scopes`. On a miss the call is refused with a JSON-RPC `-32004`
(`INSUFFICIENT_SCOPE`) error naming the missing scope(s), and the handler never runs.
`required_scopes` is server-side policy and is **not** emitted in `tools/list`.

This applies only when the request carries an authenticated principal (HTTP auth active).
When the transport has no `auth` configured, `ctx.authenticated_user` is `nothing` and the
check is **skipped** — the server performs no authorization at all, matching how
`OAuthConfig.required_scopes` is only enforced when a validator runs. So `required_scopes`
is meaningful only alongside an `auth` middleware whose validator populates scopes (the
claims-based validators — JWT/JWKS/introspection — parse them from the token's
`scope`/`scp`).

For authorization that depends on the *arguments* rather than a static scope set, inspect
the principal inside a context-aware handler and return a tool-level error instead:

```julia
MCPTool(
    name = "transfer",
    description = "Move funds; large transfers also need 'mcp:admin'.",
    parameters = [ToolParameter(name = "amount", description = "amount", type = "number", required = true)],
    required_scopes = ["mcp:write"],   # baseline gate, enforced at dispatch
    handler = (args, ctx) -> begin
        scopes = ctx.authenticated_user === nothing ? String[] : ctx.authenticated_user.scopes
        if args["amount"] > 10_000 && !("mcp:admin" in scopes)
            return CallToolResult(
                content = [TextContent(text = "insufficient_scope: transfers over 10000 require 'mcp:admin'")],
                is_error = true)
        end
        TextContent(text = "transferred $(args["amount"])")
    end,
)
```

The principal is available as `ctx.authenticated_user` (an [`AuthenticatedUser`](@ref),
or `nothing` when the transport has no `auth` configured; `disable_auth()` instead yields
an anonymous `AuthenticatedUser`) with `.username`, `.subject`, `.scopes`, `.provider`,
and the raw `.claims`. A declarative `required_scopes` miss surfaces as a JSON-RPC error
(the call was refused before running); a handler returning `CallToolResult(is_error =
true)` reports a *tool-level* failure to the model — both are distinct from the
transport-level `403` a client gets for a server-wide scope/allowlist failure, which the
model never sees.

## Protected Resource Metadata (RFC 9728)

A compliant MCP client that hits a `401` reads the `WWW-Authenticate: …
resource_metadata="<url>"` header, fetches that document, and learns which Authorization
Server to obtain a token from. Construct it directly or with a helper:

```julia
meta = create_protected_resource_metadata(
    "https://mcp.example.org/mcp",                       # this resource
    ["https://auth.example.org/realms/main"],            # its authorization server(s)
    scopes = ["mcp:read"])
```

It is served, unauthenticated, at `/.well-known/oauth-protected-resource`. For GitHub,
`create_github_resource_metadata` fills in GitHub's authorization server URL.

## Security checklist

- Prefer [`JWKSValidator`](@ref) for external tokens; reach for `JWTValidator` only in
  dev/test or behind a component that has already verified the signature.
- Always set `issuer` and `audience` in `OAuthConfig` — they are the difference between
  "a valid token" and "a valid token *for this server*."
- Terminate TLS in front of the transport; never expose the plaintext HTTP port. Never
  log bearer tokens.
- Do not pass a client's token through to an upstream API. If you must call an upstream,
  exchange the token (RFC 8693) or use the server's own credentials.
- Keep the error surface generic (the package already does this) — don't add tool output
  that leaks *why* authentication failed.

See [Deployment](@ref) for a complete, reproducible setup behind a reverse proxy with a
real Authorization Server.

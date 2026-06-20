# Deployment

This guide is a reproducible recipe for exposing an **authenticated remote MCP server**
to Claude clients. It assumes you have read [Authentication](@ref) and have a working
HTTP server; here we cover the parts *outside* the Julia process — how Claude reaches
your server, how to front it with TLS, and how to stand up the Authorization Server that
mints the tokens your [`JWKSValidator`](@ref) verifies.

Every hostname, IP, and port below is a placeholder (`example.org`, RFC 5737
documentation addresses). Substitute your own.

## First, decide who connects — it changes everything

The single most important fact, and the one most likely to waste an afternoon if you get
it wrong: **for Claude's remote *connectors*, the MCP requests do not come from your
machine — they come from Anthropic's cloud.**

| Client | Data plane originates from | Implication |
|---|---|---|
| Claude **Desktop / web / mobile / Cowork** custom connectors | **Anthropic's cloud** | Server must be reachable over the **public internet** from Anthropic's egress range. LAN-only / VPN-only / `localhost` **cannot** work. |
| **claude.ai account connectors** surfaced in Claude Code | **Anthropic's cloud** | Same as above. |
| **Claude Code** servers added with `claude mcp add` / `.mcp.json` (stdio or remote HTTP/SSE) | **your local machine** | Direct from the CLI; `localhost`, LAN, and VPN targets all work; no public exposure needed. |

This is documented by Anthropic: a custom connector "connects to your remote MCP server
from Anthropic's cloud infrastructure, rather than from your local device," and a server
"behind a VPN, or blocked by a firewall won't connect, even if you can reach it from your
own machine."

Consequences for a connector deployment:

- The server **must** have a public, TLS-terminated HTTPS URL.
- "It works from my laptop" proves nothing — test from off-network.
- Anthropic publishes a **stable egress range** for these outbound calls
  (`160.79.104.0/21` at the time of writing; confirm against Anthropic's current
  *IP addresses* documentation). You can allowlist it (see
  [Locking the data plane to Anthropic](@ref)).

If your *only* consumer is Claude Code via `claude mcp add`, you can skip all of the
public-fronting machinery and point it straight at `http://localhost:PORT` — but you
still want auth if the port is reachable by anyone else.

## Architecture

```
                          PUBLIC INTERNET (HTTPS only)
  ┌───────────────┐                                   ┌──────────────────────┐
  │ Claude client │ ── HTTPS ───────────────────────▶ │  TLS-terminating      │
  │ (or Anthropic │   bearer token                    │  front:               │
  │  cloud)       │                                   │  reverse proxy / tunnel│
  └───────────────┘                                   └───────────┬──────────┘
                                                                   │ plaintext, on
                                                                   │ loopback or trusted LAN
                          ┌────────────────────────────┬──────────┴──────────┐
                          ▼                             ▼
                ┌───────────────────┐        ┌──────────────────────┐
                │ Authorization     │        │ MCP server           │
                │ Server (Keycloak) │◀──────▶│ (ModelContextProtocol│
                │ issues + signs    │  JWKS  │  validates tokens)    │
                │ tokens            │        └──────────────────────┘
                └───────────────────┘
```

The MCP server is an OAuth **Resource Server**: it never issues tokens, only validates
them. Both the MCP server *and* the Authorization Server must be publicly reachable, but
the traffic splits across parties — be precise about who calls what:

- the **user's browser** hits the AS's *authorize* endpoint to log in;
- **Anthropic's cloud** exchanges the authorization code at the AS's *token* endpoint and
  makes the MCP requests (the data plane);
- the **MCP server itself** fetches the AS's *JWKS* (and, for `IntrospectionValidator`,
  calls the AS) to verify tokens.

JWKS is pulled **by your server**, not by Anthropic — which matters for firewalling (below).

You need a TLS front. Two tiers, by what you have available.

## Tier 1 — your own reverse proxy + certificate (recommended)

Best when you control a host with a public IP (or a forwarded port) and can obtain a
publicly-trusted certificate (e.g. Let's Encrypt). Lowest latency, and **no third party
ever terminates TLS on your tokens.**

Terminate TLS at a reverse proxy and route by path to the MCP server and the AS. Example
with nginx, both behind one hostname:

```nginx
# inside the server { listen 443 ssl; server_name mcp.example.org; ... } block
# (ssl_certificate / ssl_certificate_key from your ACME client)

# --- MCP server ---
location /mcp/ {
    proxy_pass http://127.0.0.1:8080/;   # trailing slash strips /mcp/ ; server is at root
    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection        "";      # keep-alive for the SSE stream
    proxy_buffering off;                         # do NOT buffer Server-Sent Events
    proxy_read_timeout 3600s;                    # long-lived SSE / Tasks
}
location = /mcp { return 308 /mcp/; }            # tolerate the no-trailing-slash form

# --- Authorization Server (Keycloak, served under /auth) ---
location /auth/ {
    proxy_pass http://127.0.0.1:8447;            # NO trailing slash: preserve the /auth prefix
    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Port  443;
}
```

!!! warning "Two `proxy_pass` slash conventions"
    The MCP block uses `proxy_pass …:8080/` **with** a trailing slash so nginx strips the
    `/mcp/` prefix (the Julia server serves at `/`). The Keycloak block uses
    `…:8447` **without** a trailing slash so the `/auth` prefix is *preserved* (Keycloak
    is configured to serve under `/auth`). Mixing these up is the most common cause of
    `404`s.

!!! warning "SSE needs `proxy_buffering off`"
    The Streamable HTTP transport uses Server-Sent Events for notifications and Tasks. If
    the proxy buffers responses, the client never sees streamed events. Turn buffering
    off and set a long read timeout on the MCP location.

If you can add DNS records, dedicated subdomains (`mcp.example.org`,
`auth.example.org`), each with its own `server` block, avoid the prefix-stripping
subtlety entirely — at the cost of a certificate that covers both names.

### Host firewall — check which one is actually active

If the MCP server and reverse proxy are on different hosts, the proxy host must be
allowed to reach the server's port. A trap we hit: `systemctl is-active ufw` reported
`active` while `ufw status` was `inactive` and **firewalld** was the real enforcer.
Verify the enforcing firewall, then scope an allow rule to the proxy's address. With
firewalld:

```bash
sudo firewall-cmd --permanent \
  --add-rich-rule='rule family="ipv4" source address="192.0.2.10" port port="8080" protocol="tcp" accept'
sudo firewall-cmd --reload
```

The MCP server must also **bind to an address the proxy can reach** (`0.0.0.0` or the
LAN IP) — not `127.0.0.1` — when the proxy is on another host.

### Locking the data plane to Anthropic

Because connector traffic arrives only from Anthropic's published egress range, you can
restrict the public MCP path to it as defense-in-depth. Do this at the layer that sees
the data plane — at the proxy, per-path, since the rest of port 443 may serve other
things:

```nginx
location /mcp/ {
    allow 160.79.104.0/21;   # Anthropic egress (verify current range)
    allow 192.0.2.0/24;      # your own test network, optional
    deny all;
    # ... proxy_pass etc. as above ...
}
```

!!! note "Scope the allowlist to the MCP path only"
    Restrict the allowlist to the MCP data plane (`/mcp`). Do **not** blanket-allowlist
    `/auth`: its *authorize* endpoint is hit by the **user's browser** (not Anthropic), and
    its *JWKS* endpoint must stay reachable from **your own MCP server** — which is what
    fetches the keys. (The AS's *token* endpoint is hit by Anthropic during the code
    exchange.) Allowlisting `/auth` to Anthropic's range would break both browser login and
    your server's key fetch.

## Tier 2 — Cloudflare named tunnel

Best when you have **no public IP**, are behind CGNAT, cannot open inbound ports, or want
to hide your origin address. A `cloudflared` tunnel makes an *outbound* connection to
Cloudflare's edge, which fronts a public HTTPS hostname for you.

- Use a **named** tunnel (requires a free Cloudflare account and a domain on Cloudflare),
  not a *quick* tunnel — quick tunnels hand out a new random hostname on every restart,
  which forces you to re-edit every callback URL each time.
- Cloudflare terminates TLS at its edge, so **Cloudflare sees your tokens in plaintext**
  there. That is the trade for not exposing an origin; if it is unacceptable, use Tier 1.
- Latency is comparable to Tier 1 for connector traffic (the client is Anthropic's cloud
  either way), so choose on reachability and trust, not speed.

## The Authorization Server

Any standards-compliant OAuth 2.x / OIDC server works. Keycloak is used here because it
is free, self-hostable, supports identity brokering, and — unlike a bare OAuth app —
implements the discovery and PKCE that Claude's connector flow expects. **Do not write
your own.**

### Minimal realm

1. Create a realm (e.g. `main`).
2. Create a user, or federate one (below).
3. Register a **public** client for Claude (PKCE, no secret):
   - redirect URIs: for setup, `https://claude.ai/*` and `https://claude.com/*`.
     **Wildcards are a testing shortcut only** — they widen redirect-abuse risk; in
     production register the exact Claude callback URL(s) and drop the wildcards.
   - In Claude Desktop, this client id goes in **Advanced → OAuth Client ID**. Claude's
     connectors accept a **pre-registered** client id, so you do **not** need Dynamic
     Client Registration.
4. Add an **audience mapper** so issued tokens carry `aud =
   https://mcp.example.org/mcp` — this must equal your `OAuthConfig.audience`.
5. Add a client scope (e.g. `mcp:read`) that appears in the token's `scope` claim.

!!! warning "Keycloak behind a sub-path"
    If Keycloak is served under `/auth` (as in the nginx example), it must both *serve*
    there and *advertise* URLs there, or the issuer in its tokens won't match what your
    server expects. Start it with **both**:
    ```
    --http-relative-path=/auth  --hostname=https://mcp.example.org/auth  --proxy-headers=xforwarded
    ```
    Setting `--hostname` to the bare origin (no `/auth`) makes Keycloak advertise an
    issuer *without* the path, and token validation then fails on `iss`. Verify with:
    ```bash
    curl -s https://mcp.example.org/auth/realms/main/.well-known/openid-configuration | jq .issuer
    # → "https://mcp.example.org/auth/realms/main"
    ```

### Optional: GitHub identity federation

To let users sign in with GitHub (so your allowlist is GitHub usernames), add GitHub as
an *identity provider* in Keycloak — the MCP server still just sees ordinary signed JWTs.

1. Create a GitHub **OAuth App** (identity scopes only).
2. Set its **Authorization callback URL** to Keycloak's broker endpoint:
   `https://mcp.example.org/auth/realms/main/broker/github/endpoint`.
3. Add a GitHub identity provider in Keycloak with that app's client id/secret.

!!! warning "The callback URL is GitHub's, not Claude's"
    `…/broker/github/endpoint` goes in the **GitHub App's** callback field, never in
    Claude Desktop's *OAuth Client ID* field (that takes the Keycloak client id). And if
    Keycloak's public hostname ever changes, this callback must be updated — a stale
    value yields GitHub's *"The redirect_uri is not associated with this application"*
    error, which is a **GitHub** error, not a Keycloak one.

!!! note "Brokered usernames are normalized"
    Keycloak lowercases federated usernames, so GitHub login `Alice` arrives as `alice`.
    Put the lowercase form in your [`allowlist`](@ref AuthMiddleware), or inspect a real
    token's `preferred_username`.

## Wiring the MCP server

The Julia side is small once the AS exists — it is the example from
[Authentication](@ref), with the URLs lined up:

```julia
using ModelContextProtocol

issuer   = "https://mcp.example.org/auth/realms/main"
resource = "https://mcp.example.org/mcp"

auth = create_auth_middleware(
    OAuthConfig(issuer = issuer, audience = resource, required_scopes = ["mcp:read"]),
    validator = JWKSValidator("$issuer/protocol/openid-connect/certs"),
    allowlist = Set(["alice"]),   # token usernames; lowercase for brokered GitHub logins
)
meta = ProtectedResourceMetadata(
    resource = resource, authorization_servers = [issuer], scopes_supported = ["mcp:read"])

server = mcp_server(name = "secure-server", tools = [...])
# bind to 0.0.0.0 if the reverse proxy is on another host; 127.0.0.1 if co-located
server.transport = HttpTransport(host = "0.0.0.0", port = 8080, auth = auth, resource_metadata = meta)
connect(server.transport)
start!(server)
```

The three URLs that must agree:

| Value | Set in | Must equal |
|---|---|---|
| `issuer` | `OAuthConfig.issuer` | the AS's advertised `issuer` (check its discovery doc) |
| `audience` | `OAuthConfig.audience` | the AS audience-mapper value, and your public MCP URL |
| JWKS URL | `JWKSValidator(...)` | `$issuer/protocol/openid-connect/certs` (Keycloak) |

## Verifying end-to-end

Before involving Claude, prove the chain with `curl`. Mint a token from the AS — a
direct-grant (Resource Owner Password) client is convenient for **local verification
only**. OAuth 2.1 discourages that grant, so disable it in production and rely on the
authorization-code + PKCE flow Claude actually uses. Call the server through the *public*
URL:

```bash
# 1. mint a token (direct grant; needs a test client with that flow enabled)
TOKEN=$(curl -s -X POST \
  https://mcp.example.org/auth/realms/main/protocol/openid-connect/token \
  -d grant_type=password -d client_id=test-cli -d client_secret=… \
  -d username=alice -d password=… | jq -r .access_token)

# 2. no token → 401 with a resource_metadata pointer
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://mcp.example.org/mcp/ \
  -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'   # → 401

# 3. valid token → initialize succeeds
curl -s -X POST https://mcp.example.org/mcp/ \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1"}},"id":1}'
```

Decode the token (`jwt` payload) and confirm `iss`, `aud`, and `scope` match your
config — a `401` after a clean mint is almost always one of those three disagreeing.

Then add it in Claude Desktop: **Settings → Connectors → Add custom connector**, URL
`https://mcp.example.org/mcp/`, **Advanced → OAuth Client ID** = your Keycloak client id.

!!! note "Benign log noise"
    Connector clients open and close connections frequently; the HTTP transport may log
    `EOFError`/broken-pipe on those closes. These are harmless connection teardowns, not
    request failures — confirm health with a successful tool call, not by the absence of
    such log lines.

## Security checklist

- TLS terminates on infrastructure you trust (Tier 1) or you accept Cloudflare as the
  terminator (Tier 2). Never expose the plaintext MCP port publicly.
- `issuer` and `audience` are set and verified against the AS's real discovery document.
- The AS is a battle-tested product, not hand-rolled. The MCP server only validates.
- Tokens are never logged, and never forwarded to *application* upstreams. (A validator
  may send the token to its configured introspection/JWKS AS endpoint, or to GitHub — that
  is the validation call itself, not a pass-through to your downstream APIs.)
- Optionally allowlist Anthropic's egress range on the MCP data path.
- Re-test from **off** your network — the connector data plane is not your laptop.

# Changelog

All notable changes to ModelContextProtocol.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0] - 2026-08-09

**Full server-side support for the MCP 2026-07-28 specification.** This
release completes the modern stateless era begun in 0.6.x: the tasks
extension (server-directed handoff, mid-task input, status notifications),
argument completion, and `x-mcp-header` parameter mirroring — nothing on the
2026-07-28 spec's server side remains unimplemented. The official conformance
suite passes every substantive check (modern-dated 40/40, `server-stateless`
30/30, header validation 14/14 + custom headers 10/10, all `tasks-*`
scenarios) and now runs in CI on every PR. All changes are additive, and legacy
sessions (`2024-11-05`…`2025-11-25`) remain fully compatible.


### Added

- **Tasks extension core (SEP-2663, `io.modelcontextprotocol/tasks`).** The modern
  era's replacement for the experimental SEP-1686 core tasks, served alongside the
  untouched legacy surface (era-tagged records in the shared `TaskStore`; neither
  era can see the other's tasks). Task creation is server-directed: a client
  declares the extension under `_meta`
  `clientCapabilities.extensions["io.modelcontextprotocol/tasks"]`, and a
  task-capable tool's handler — now run off the serial loop with its response
  route captured — hands off with the new exported **`task_detach(ctx)`**, which
  durably creates the task and immediately delivers the flat `CreateTaskResult`
  (`resultType:"task"`, `ttlMs`/`pollIntervalMs` wire fields) while the handler
  keeps running; the eventual return value completes the task (a tool-level
  `isError:true` result **completes** it per the extension — `failed` is reserved
  for JSON-RPC errors, inlined as the task's `error`). A handler that returns
  without detaching yields the ordinary synchronous result (the immediate-result
  shortcut), and one that returns `InputRequired` first gets the MRTR round —
  MRTR exchanges resolve before task creation, so the SEP's composition rule
  (gather input synchronously, then escalate to a task) works end-to-end.
  Surface: `tasks/get` (DetailedTask with the terminal `result`/`error` inlined —
  there is no `tasks/result`), `tasks/update` (ack-only; see the mid-task input
  flow entry below), and the idempotent ack-only `tasks/cancel` (terminal
  cancels ack instead of erroring; `-32602` is reserved for unknown ids;
  cooperative cancellation via the existing `task_cancelled(ctx)`).
  Non-declaring clients get `-32021` with `data.requiredCapabilities` on the
  `tasks/*` methods and on `tools/call` of a `task_support = :required` tool,
  while `:optional` tools fall through to synchronous execution (and the legacy
  `task` request param is tolerated and ignored). `server/discover` advertises
  the extension under `capabilities.extensions`; `tasks/result`/`tasks/list`
  stay `-32601` in the modern era; on Streamable HTTP the SEP-2243 `Mcp-Name`
  header must mirror `params.taskId` on the `tasks/*` methods. Verified against
  the official conformance suite's `tasks-*` scenarios (all substantive checks
  pass; the suite's wire-schema validator does not yet know the extension's
  `CreateTaskResult` shape, an upstream harness gap).

- **Tasks extension mid-task input flow (SEP-2663 + SEP-2322).** A detached
  handler can now ask the client for input DURING task execution with the new
  exported **`task_await_input(ctx, request)`** (single-request or vector form;
  requests are built with the existing
  `elicit_request`/`sampling_request`/`roots_request` constructors). The
  request(s) register under server-minted keys unique over the task's lifetime
  (a key is never reused after being answered), the task parks as
  `input_required`, and `tasks/get` inlines the point-in-time `inputRequests`
  snapshot on every poll. The client answers via `tasks/update`
  `inputResponses`, which now actually delivers: not-outstanding keys — never
  issued, already answered, or superseded — are ignored per spec, and a partial
  set is accepted (answered keys are removed, the task stays `input_required`
  until the rest arrive); once nothing is pending the status returns to
  `working` and the blocked handler resumes with the response values (the
  vector form returns them in request order only when all have arrived).
  `tasks/cancel` unblocks a parked waiter — the handler unwinds with the new
  exported `TaskCancelledException`, and its discarded outcome never overwrites
  the cancelled status — and an input request whose capability the creating
  request did not declare is refused (the await throws, failing the task, since
  a server must not surface requests the client cannot handle). Registered
  requests are **frozen**: params are normalized into an owned plain-JSON
  snapshot at registration (a closed whitelist — containers rebuilt, strings
  snapshotted, big numbers duplicated, exact concrete numeric types only with
  non-finite floats refused, anything exotic rejected with a clear error;
  numeric fidelity is exact, an integer beyond Int64 in a schema `const`
  survives) — so a caller-held reference can neither repurpose a key's content
  across polls (the spec's key-stability rule) nor escalate a request past the
  already-run capability check (e.g. adding sampling `tools` afterwards). A task whose ttl elapses
  while parked on client input is **failed and drained by a clock-driven
  per-wait deadline timer** (interval-retried past the wall-clock boundary,
  with the store sweep as backstop) — abandoned parked tasks cannot pin their
  spawned handler, channels, and params even when the client vanishes without
  further requests; a post-expiry poll observes the failed record briefly or
  task-not-found (timing-dependent), `working` tasks keep the existing
  retained-past-ttl behavior since their background work may still be running,
  and handlers can distinguish expiry from a client cancel via
  `task_cancelled(ctx)`. Conformance:
  the `tasks-mrtr-input` and `tasks-mrtr-composition` scenarios and the
  dispatch suite's parked-elicitation check now pass all substantive checks
  (fixtures `confirm_delete`, `multi_input`, `test_tool_with_task`).

- **Custom header parameter mirroring (`x-mcp-header`, SEP-2243).** A tool
  parameter may declare a header-mirroring suffix — `ToolParameter(header =
  "Routing-Key")`, emitted as `x-mcp-header` in the generated schema, or the
  same key in a raw `input_schema` — and modern HTTP clients mirror that
  argument as an `Mcp-Param-<suffix>` request header for transport-level
  routing. The server validates every mirror against the body as a
  transport-level preflight (before the per-request log opt-in, so a violation
  can never be committed as an SSE 200 by a preceding notification): strict
  `=?base64?...?=` sentinel decoding (invalid padding or characters rejected),
  literal comparison otherwise, annotations honored at ANY object nesting
  depth, integers compared EXACTLY through the full JSON number grammar (JSON3
  normalizes `42.0`/`1e3` to integers, distinct values beyond 2^53 never
  collapse through Float64, hex/Inf/NaN reject, and values outside the
  JavaScript-safe integer range refuse to mirror at all per the spec),
  non-integral numbers numerically (a JavaScript client's `String(1e-7)` is
  `"1e-7"`, not Julia's `"1.0e-7"`), and `-32020` (HTTP 400 — mapped reliably
  whatever the envelope size, via a structural sniff that huge echoed request
  ids cannot evade and embedded error-shaped strings cannot spoof) when the
  header is missing while its argument is in the body, duplicated, malformed,
  or mismatched. Absent arguments, explicit JSON `null` values (clients omit
  the header for null), and unrecognized `Mcp-Param-*` headers are ignored
  (forward compatibility); stdio and legacy-era requests are untouched.
  Registration refuses invalid annotations — suffixes must be nonempty HTTP
  tokens, case-insensitively unique per tool; the annotated property must
  declare type `string`, `integer`, or `boolean` (the spec excludes `number`,
  objects, and arrays); and annotations are valid only on statically reachable
  properties (never under array `items`, composition branches, or definitions)
  — instead of advertising tools clients would have to discard, and violation
  messages bound schema-derived names so the error envelope stays small. The headers travel from the connection handler to the dispatch layer
  inside the request envelope — never via shared transport state — and the
  conformance suite's `http-custom-header-server-validation` scenario passes
  10/10.

- **Tasks extension status notifications (`notifications/tasks`).** A
  `subscriptions/listen` request may now subscribe to task status updates via a
  `taskIds` filter entry: every extension-era transition — parking on input,
  resuming after `tasks/update`, completing, failing, cancelling, ttl-expiring —
  pushes a complete DetailedTask (identical to what `tasks/get` would return at
  that moment, `subscriptionId`-tagged) to the streams watching that id.
  Requesting `taskIds` without declaring the `io.modelcontextprotocol/tasks`
  extension is the extension's `-32021` (spec MUST, taking precedence over
  shape validation); the acknowledgment echoes only the ids the server agreed
  to — unknown, foreign-principal, or insufficiently-scoped ids are silently
  omitted (the same re-authorization `tasks/get` applies, so subscription
  probing leaks nothing polling would not), and each subscribed task's CURRENT
  state is pushed right after the acknowledgment, so a transition landing
  during registration can never strand a notification-only client. Deliveries
  re-check the stream's principal and scopes against the task's transition-time
  requirements (on authenticated transports — an unauthenticated stream has no
  scopes, not insufficient ones, mirroring `tasks/get`), are sequence-guarded
  so a queued backlog never replays older states to a freshly registered
  stream, and ride a bounded FIFO drained by a dispatcher task outside the
  store lock — a stalled client cannot wedge the task surface, transition order
  is preserved, and overload load-sheds (pushes are best-effort; polling stays
  authoritative). The dispatcher is closed on every server-loop exit and
  revived on restart, and the listen capacity check sweeps dead routes so
  vanished streams cannot pin the subscription surface. Legacy-era (SEP-1686)
  tasks never reach these streams.

- **Argument completion (`completion/complete`).** The completion utility,
  served in both eras: suggestions for prompt arguments (`ref/prompt`, by
  prompt name) and resource-template variables (`ref/resource`, by URI
  template). Sources are configured per component via the new `completions`
  field on `MCPPrompt` / `ResourceTemplate` — a `Vector{String}` served
  filtered by prefix against the partial value, or a function `value -> values`
  / `(value, context_args) -> values` receiving the request context's
  already-resolved arguments; components without sources serve empty
  suggestion lists. Responses cap `values` at the spec's 100 with `total` and
  `hasMore`; unknown ref types, prompt names, or template URIs are `-32602`, as
  are malformed params in EITHER era and a `context.arguments` that is not the
  schema's object-of-strings (validated and normalized to `Dict{String,String}`
  before source dispatch, so strictly typed two-argument sources work);
  misconfigured sources — non-vector values, non-string elements, a function
  returning a lone string — fail loudly with `-32603` naming the cause instead
  of silently coercing.
  The new `CompletionCapability` (in the defaults) advertises `completions` in
  the legacy initialize response and in `server/discover`, and gates the
  modern-era method surface. This clears the last modern-dated conformance
  failure (suite now 40/40) and the legacy `completion-complete` scenario.

### Changed

- **MRTR `requestState` payload format v2.** The principal bound into a
  `requestState` (and the principal extension tasks are bound to) is now the
  canonical, collision-free `[provider, subject]` identity instead of the bare
  subject — a same-`sub` token from a different identity provider can no longer
  redeem another principal's state or resolve its tasks. The payload version is
  bumped to 2 so a v1 token fails explicitly as "unsupported version". Operators
  running shared-`mrtr_state_key` replica fleets should drain in-flight MRTR
  exchanges (bounded by the 600 s state TTL) when rolling across this upgrade;
  single-instance deployments with the default ephemeral key are unaffected.

- **Per-request `logLevel` (SEP-2575, 2026-07-28).** The modern era's replacement
  for `logging/setLevel`: a request whose `_meta` carries
  `io.modelcontextprotocol/logLevel` opts into `notifications/message` delivery
  for that request only — records at or above the requested RFC-5424 level are
  delivered on the request's own response stream (stdio stdout / the POST's SSE
  response stream on Streamable HTTP), before the final response, and never on
  any other stream (a dead response stream drops the records rather than
  diverting them to the legacy GET stream; `subscriptions/listen` never honors
  the opt-in, since its response stream is the subscription stream). Requests
  without the field get no `notifications/message` (the existing modern-era
  suppression, now the spec's MUST); an unrecognized level value is rejected
  with `-32602`. Delivery requires the server to declare the logging capability
  (a spec MUST for emitters, on by default), which `server/discover` now
  advertises. Every guarantee is carried by a request-scoped
  `ModernRequestLogger` installed with `with_logger` around the serve path —
  logstate, unlike task-local storage, is inherited by handler-spawned child
  tasks, so suppression, severity filtering, and stream confinement hold for
  `@async`/`@spawn` records too, and delivery authorization is bound to the
  serving transport rather than ambient state (an `MCPLogger` wired to a
  different server keeps its own legacy gates). Records arriving after the
  response is under way are dropped, not delivered late. A `debug` opt-in
  delivers records below the operator's installed logger level for the
  request's duration — the wrapper's installation rebuilds Julia's cached
  `LogState` enablement with the per-request level, without mutating any global
  state — while the operator's fallback stream stays governed by the installed
  level. Works for pure modern stateless sessions: the legacy
  initialize-activation gate does not apply to the per-request opt-in.

- **MRTR / `input_required` (SEP-2322, 2026-07-28).** The modern era's replacement
  for server-initiated requests, which finally makes elicitation implementable on
  the serial loop: a tool handler that needs client input returns
  `InputRequired(Dict(key => elicit_request(...)/sampling_request(...)/roots_request());
  state=...)` and the server answers with an `InputRequiredResult`
  (`resultType: "input_required"`, the `inputRequests` map, and an opaque
  `requestState`). The client retries with a new id, the ORIGINAL params, its
  `inputResponses`, and the echoed `requestState`; the handler simply runs again,
  reading `input_responses(ctx)` and `input_state(ctx)` (all exported). A still-
  missing response re-issues the `InputRequiredResult` rather than erroring, per
  spec. Capability enforcement: input requests whose capability
  (`elicitation`/`sampling`/`roots`) the request's `_meta` capabilities did not
  declare are rejected with `-32021 MissingRequiredClientCapability`
  (`error.data.requiredCapabilities` is a ClientCapabilities object, HTTP 400).
  `requestState` is treated as attacker-controlled input: it is HMAC-SHA256-signed
  over a payload embedding issue time + TTL (10 min), the authenticated principal,
  and a canonical sorted-key digest of the original params — signature
  (constant-time), expiry, principal, and params-digest are all verified before any
  handler runs (`-32602` on any mismatch), with a per-server ephemeral signing key.
  Scope: `tools/call` handlers (sync only — `input_required` inside task-augmented
  executions fails the task pending the tasks extension, and legacy sessions get an
  error since they have no wire shape for it); `resources/read`/`prompts/get`
  retry-field parsing is in place for when their providers gain the return type.
  With this, the draft `server-stateless` conformance scenario passes completely
  (30/30).

- **`subscriptions/listen` (2026-07-28).** The modern-era replacement for the legacy
  GET SSE endpoint and `resources/subscribe`/`unsubscribe`: a long-lived POST response
  stream carrying only the notification types the client opted into. The request never
  completes normally — its response route is captured and notifications are pushed onto
  it as changes occur, so the server loop stays free. `notifications/subscriptions/acknowledged`
  is always the stream's first message and reports the honored subset of the requested
  filter (types whose capability the server does not declare are omitted rather than
  silently accepted); every message on the stream — acknowledgment, notifications, and
  the closing result — carries `io.modelcontextprotocol/subscriptionId`, which is how
  clients demultiplex concurrent subscriptions on stdio. Server shutdown ends each
  stream gracefully by answering its listen request with an empty complete result, so
  clients can distinguish an orderly close from a dropped connection. Filters cover
  `toolsListChanged`, `promptsListChanged`, `resourcesListChanged`, and
  `resourceSubscriptions` (per-URI `notifications/resources/updated`); a server never
  sends a type the client did not request. `server/discover` now advertises the
  `listChanged`/`subscribe` flags again, since there is finally a modern mechanism to
  deliver them. Hardened for long-lived use: malformed filters are rejected with
  `-32602` (they must not silently establish streams that can never deliver);
  active subscriptions are capped (64, with 128-byte ids that must not duplicate an
  active subscription's, and at most 256 watched resource URIs per stream); a stream
  whose client stops reading is load-shed at a bounded backlog instead of buffering
  forever; idle HTTP streams carry periodic SSE keepalive comments
  (`HttpTransport(sse_keepalive_secs=...)`, default 15s) so a silently-dead peer is
  detected within about two intervals, and dead records are swept both on broadcast
  and at registration time (they never pin the cap or their id against a reconnect);
  `notifications/cancelled` with the listen request's id cancels the subscription on
  stdio only (HTTP clients close the response stream instead — honoring an in-band
  cancellation there would let one client end another's stream by guessing its id);
  and `stop!(server)` now ends the server loop with the transport still open, so
  shutdown delivers each stream's graceful closing result before the connections
  tear down.
- **`notify_list_changed(server, kind)` and `notify_resource_updated(server, uri)`**
  (exported): announce runtime changes to open subscription streams. Call them after
  mutating `server.tools`/`server.prompts`/`server.resources` or a resource's contents;
  each returns how many streams were notified. Streams whose client has gone away are
  pruned automatically.

- **Modern-era HTTP transport layer (2026-07-28).** Streamable HTTP now applies the
  modern transport rules to modern-marked requests, while legacy traffic keeps its
  existing behavior (dual-era): SEP-2243 standard header validation —
  `MCP-Protocol-Version` and `Mcp-Method` required and mirroring the body,
  `Mcp-Name` required on `tools/call`/`prompts/get`/`resources/read` (with the
  `=?base64?…?=` sentinel decoded before comparison) — rejected with
  `400` + `-32020 HeaderMismatch`; protocol-error HTTP status mapping (`404` for
  `-32601`, `400` for `-32020`/`-32021`/`-32022` and for missing required `_meta`
  fields); modern responses echo the request's own protocol version, never carry an
  `Mcp-Session-Id` header, are exempt from legacy session validation
  (`session_required` no longer rejects stateless requests), and never mint
  sessions. `server/discover` without `_meta` gets `400` + `-32602` at the
  transport. Custom `x-mcp-header`/`Mcp-Param-*` mirroring is not yet implemented
  (servers designate no such parameters, and emission is optional).

- **Modern-era (2026-07-28) stateless core.** The server is now dual-era per the
  2026-07-28 spec's backward-compatibility model: a request carrying
  `io.modelcontextprotocol/protocolVersion` in its params `_meta` is served
  statelessly (no `initialize` handshake; version and `clientCapabilities`
  validated per request), while `initialize` continues to select legacy semantics —
  both eras interleave on one server without touching each other's state. Includes:
  `server/discover` (spec MUST; advertises versions of both eras, capabilities,
  instructions, and `ttlMs`/`cacheScope` caching hints); the modern result envelope
  (`resultType: "complete"` plus `io.modelcontextprotocol/serverInfo` in every
  result `_meta`, merged into handler-provided `_meta`); the 2026-07-28 error codes
  (`UnsupportedProtocolVersionError` -32022 with `supported`/`requested` data,
  `MissingRequiredClientCapability` -32021, `HeaderMismatch` -32020) with the
  reserved legacy `-32002` remapped to `-32602` on modern responses; and the modern
  method surface (methods removed by the spec — `ping`, `logging/setLevel`,
  `resources/subscribe`/`unsubscribe`, core `tasks/*` — answer -32601 on modern
  requests, and task-augmentation metadata is ignored pending the tasks extension).
  Modern requests never receive `notifications/message` (per-request `logLevel`
  support to follow). `mcp_server` gains an `instructions` kwarg, surfaced by both
  `initialize` and `server/discover`.

- **`resources/subscribe` and `resources/unsubscribe` wire handlers.** The server
  advertised `resources: { subscribe: true }` but answered both methods with
  "Unknown method" (found by the official MCP conformance suite). They are now
  handled per spec: the URI is tracked in the session's subscription set and an
  empty result is returned; both are idempotent.
- **DNS-rebinding protection** (GHSA-w48q-cv73-mx4w class): a loopback-bound
  `HttpTransport` without *enabled* bearer auth now rejects requests whose `Host` or
  `Origin` header is neither local nor allowlisted with `403 Forbidden`. Loopback is
  classified by parsing (any 127.0.0.0/8 address, `::1`, IPv4-mapped IPv6 loopback,
  `localhost` with optional trailing dot) for both the bind host and header values;
  malformed `Host` values (userinfo, junk after an IPv6 literal, multiple colons)
  and duplicate `Host`/`Origin` headers are rejected rather than leniently parsed.
  New `allowed_hosts` kwarg admits extra hostnames in `Host` only (e.g. a reverse
  proxy's public domain); browser origins are admitted solely by loopback hostname
  or an exact `allowed_origins` match. `disable_auth()` counts as no auth — the
  guard stays active. (Hardened per security review.)

### Changed

- **Request-scoped notifications now ride the originating POST's SSE response
  stream** on Streamable HTTP, as the spec (and standard clients: TypeScript SDK,
  Inspector, conformance suite) expect. Previously `notifications/progress` emitted
  by a ctx-aware tool was queued to the standalone GET stream — which mainstream
  clients never open — and was effectively lost. A request that emits notifications
  during handling now receives a `text/event-stream` response carrying the
  notifications followed by the final response; a quiet request still gets a plain
  `application/json` response. Out-of-band notifications (background MCP Tasks
  status updates) keep flowing on the GET stream. Clients whose `Accept` lacks
  `text/event-stream` receive the plain JSON response with request-scoped
  notifications dropped.
- **MCP log notifications are now actually delivered to the client.** `MCPLogger`
  wrote `notifications/message` as JSON lines to stderr, so no client ever received
  them regardless of `logging/setLevel`. Once the client has initialized, log
  records now go over the transport: stdout on stdio (interleaved with responses
  per spec), the originating request's SSE response stream on HTTP. Before
  initialization — and whenever transport delivery is unavailable — records still
  fall back to stderr. Records below `Info` now map to the MCP `"debug"` level
  (previously `"info"`).

### Fixed

- **Client-sent JSON-RPC responses over HTTP now receive `202 Accepted`** per the
  Streamable HTTP spec; previously they were misclassified as requests ("no `id`
  field" was the notification test) and stranded the connection waiting for a reply
  the server never sends. Invalid objects that are neither request, notification,
  nor response (e.g. `{}`) now get `400` with a `-32600` Invalid Request error
  instead of a blanket `202`.
- **The single server loop can no longer stall on notification delivery.** The
  out-of-band notification queue is unbounded with a drop-new soft cap (the GET SSE
  consumer is optional per spec, so a bounded queue with blocking `put!` let a
  POST-only client freeze the loop — trivially reachable at `logging/setLevel`
  `debug`); per-request response channels are unbounded so a slow reader of one SSE
  response cannot backpressure other clients' requests; and the loop's own lifecycle
  log records are routed to the originating request's stream rather than the shared
  queue. Transport shutdown now closes the notification queue and atomically fences
  new response-channel registration (late connections get `503`), eliminating a
  shutdown race that could strand a connection handler.

## [0.6.1] - 2026-07-30

### Changed

- Widened `OrderedCollections` compat to `"1, 2"`. This was previously untestable —
  DataStructures capped `OrderedCollections` at 1.x, so the widened bound could not
  resolve — and became possible once DataStructures 0.19.6 widened its own bound to
  `"1.1, 2"`. Purely additive for downstream resolution; the suite passes on
  OrderedCollections 2.0.1 (which supplies `LittleDict`, used in the protocol layer).
- Widened `JWTs` compat to `"0.3, 1"`. JWTs 1.0 replaced its MbedTLS crypto backend
  with OpenSSL_jll; the package's own use of JWTs (`JWKSValidator`) is entirely
  public API (`JWKSet`, `refresh!`, `JWT`, `issigned`, `validate!(; algorithms)`)
  and needed no changes. The JWKS test fixtures are now signed with MbedTLS
  directly (a test-only dependency) instead of borrowing `JWTs.MbedTLS`, which no
  longer exists — decoupling the test signer from JWTs' backend. The full suite
  passes on both JWTs 0.3.2 and 1.0.0, including the RFC 7517 signature-verification
  tests (under 1.0, OpenSSL verifies what MbedTLS signed).

### Fixed

- **HTTP SSE notification delivery** (fixes #71): server-to-client notifications over
  the Streamable HTTP GET stream (progress, `notifications/tasks/status`, logging)
  were not delivered. Two defects compounded: bare `close(timer)` / `flush(sse_stream)`
  calls resolved to this package's own `Transport`-only methods instead of `Base`,
  throwing a swallowed `MethodError` that dropped the SSE stream ~100ms after connect;
  and the notification loop spawned a fresh `@async take!` waiter every iteration and
  abandoned the old one, so arriving notifications woke an orphaned waiter (Channel
  waiters are FIFO) and were silently lost. The loop now polls `isready` directly —
  no waiter tasks, no `Timer` — and qualifies `Base.flush`. A regression test asserts
  a `notifications/progress` emitted by a ctx-aware tool actually arrives at a
  connected SSE client after an idle window; the pre-existing SSE test read its
  stream to EOF, which only ever terminated *because* the broken loop killed the
  connection, and was rewritten to a deadline-based reader.

## [0.6.0] - 2026-06-21

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
- **Per-tool scope enforcement**: `MCPTool(required_scopes = [...])` gates an individual
  tool on OAuth scopes. At `tools/call` dispatch, when the request carries an
  authenticated principal (HTTP auth active), every listed scope must be present on
  `ctx.authenticated_user.scopes` or the call is refused with a JSON-RPC `-32004`
  (`INSUFFICIENT_SCOPE`) error naming the missing scope(s) — checked before the task/sync
  split so both execution paths are gated. Empty (default) means no per-tool requirement;
  with no authenticated user (auth not configured) the check is skipped. `required_scopes`
  is server-side policy and is not emitted in `tools/list`.

### Changed

- **Breaking — allowlist username matching is now case-insensitive by default**:
  `check_allowlist` (and the `allowlist` on `AuthMiddleware`, `create_auth_middleware`,
  `create_simple_auth`, and `create_github_auth`) compares **usernames** case-insensitively,
  because identity providers vary or normalize case (e.g. Keycloak lowercases GitHub
  logins). The opaque OAuth `subject` is still matched exactly. Pass
  `case_insensitive_allowlist = false` to restore exact username matching; servers whose
  allowlists relied on case-sensitive username distinctions must opt out.
- **Breaking — `JWTValidator` requires explicit opt-in to its unsigned mode**: because it
  validates claims but does **not** verify token signatures (any caller can forge
  `iss`/`aud`/scopes), it now refuses to construct unless you pass
  `insecure_skip_signature_verification = true`. Use `JWKSValidator` for tokens from an
  authorization server (the recommended verifying path) or `IntrospectionValidator`;
  reserve `JWTValidator` for a server behind a gateway that already verifies signatures.

## [0.5.5] - 2026-06-20

### Fixed

- **`CallToolResult` constructed with `Content` objects**: `CallToolResult.content` is
  typed `Vector{Dict{String,Any}}`, so the documented pattern
  `CallToolResult(content = [TextContent(...)], is_error = true)` threw
  `MethodError(convert, Dict{String,Any}, …)` — the per-element field conversion had no
  matching method. A new `convert(::Type{Dict{String,Any}}, ::Content)` (routing through
  `content2dict`) lets tool handlers pass `Content` objects directly; the serialized wire
  shape is unchanged.
- **Quieter HTTP transport logs**: benign client disconnects no longer spam the log. The
  `MCPLogger` no longer relays HTTP.jl's internal connection-loop logging (the `closeread`
  EOF emitted at `error` level on every connection close) into the MCP notification
  stream; the request handler treats a client-disconnect `EOFError`/`IOError` as `debug`
  rather than `error` (and no longer attempts to write a `500` to an already-closed
  stream); and the GitHub validator's network-failure warnings drop their full backtrace.
  The package's own transport errors are still logged.

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

[Unreleased]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/JuliaSMLM/ModelContextProtocol.jl/compare/v0.6.0...v0.6.1
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

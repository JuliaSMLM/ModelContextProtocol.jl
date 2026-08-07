# The Modern Era (2026-07-28)

ModelContextProtocol.jl is a **dual-era** server. Alongside the classic
`initialize`-handshake sessions (protocol versions `2024-11-05` through
`2025-11-25`), it serves the **2026-07-28 specification's stateless modern
era**: any request whose params `_meta` carries
`io.modelcontextprotocol/protocolVersion` is validated and answered as a
self-contained exchange — no handshake, no session state — on the same
endpoint. Both eras share your tools, resources, prompts, and templates; you
register components once and clients of either generation are served.

Nothing on the 2026-07-28 spec's server side is unimplemented: the sections
below tour the modern surface and the handler APIs that drive it.

## Stateless requests and `server/discover`

A modern request carries three `_meta` fields — the protocol version, the
client's capabilities, and (optionally) client info:

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "tools/list",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

Validation is per-request: a missing required field is `-32602`, an
unsupported version is `-32022` with the supported list, and methods removed
from the modern era (`ping`, `logging/setLevel`, `resources/subscribe`,
`tasks/result`, `tasks/list`) are `-32601`. `server/discover` replaces the
handshake for capability discovery — it returns supported versions across
both eras, the modern capability set (including declared extensions), and the
CacheableResult fields (`ttlMs`, `cacheScope`) the spec requires. Every
modern result carries a `resultType` and identifies the server via
`io.modelcontextprotocol/serverInfo` in its `_meta`.

Over Streamable HTTP, modern requests are validated against the SEP-2243
standard headers — `MCP-Protocol-Version` and `Mcp-Method` on every request,
`Mcp-Name` mirroring the body on `tools/call`, `prompts/get`,
`resources/read`, and the `tasks/*` methods — with `-32020` (HTTP 400) on any
mismatch, 404 for unknown methods, and sessions ignored (never minted).

## Multi round-trip requests (MRTR)

The modern era has no server-initiated requests. A handler that needs client
input (elicitation, sampling, roots) **returns** an [`InputRequired`](@ref)
value; the server answers with `resultType: "input_required"`, the requests to
fulfill, and an integrity-protected `requestState`; the client retries the
original method with its `inputResponses` and the echoed state, and the
handler simply runs again:

```julia
tool = MCPTool(
    name = "greeter",
    description = "Greets a confirmed user",
    parameters = ToolParameter[],
    handler = (args, ctx) -> begin
        resp = get(input_responses(ctx), "who", nothing)
        resp === nothing && return InputRequired(
            Dict("who" => elicit_request("Who should I greet?")))
        TextContent(text = "Hello!")
    end)
```

Build requests with [`elicit_request`](@ref), [`sampling_request`](@ref), or
[`roots_request`](@ref); read the retry's responses with
[`input_responses`](@ref) and carried-over handler state with
[`input_state`](@ref). A request whose input requests need capabilities the
client did not declare is rejected with `-32021` naming them. The
`requestState` token is HMAC-bound to the principal, a TTL, and a canonical
digest of the original params — pass `mrtr_state_key` to `mcp_server` when
running shared-key replicas.

## The tasks extension (`io.modelcontextprotocol/tasks`)

Long-running work moves off the serial loop through the SEP-2663 tasks
extension. Creation is **server-directed**: the client declares the extension
in its per-request capabilities, and the handler decides —
[`task_detach`](@ref) hands the running call off to a background task and
immediately answers with a flat `CreateTaskResult`; the handler's eventual
return value (or thrown error) becomes the task's terminal state, observable
via `tasks/get` (results inlined; there is no `tasks/result`):

```julia
slow = MCPTool(
    name = "slow_job",
    description = "Expensive computation",
    parameters = ToolParameter[],
    task_support = :optional,   # :required rejects non-declaring clients (-32021)
    handler = (args, ctx) -> begin
        task_detach(ctx)        # false (and the call stays synchronous) when
                                # the client did not declare the extension
        for step in 1:100
            task_cancelled(ctx) && return TextContent(text = "stopped")
            # ... work ...
        end
        TextContent(text = "done")
    end)
```

`tasks/cancel` is an idempotent empty ack (cooperative — poll
[`task_cancelled`](@ref)); a tool-level `isError` result **completes** the
task (`failed` is reserved for protocol errors); extension tasks and legacy
SEP-1686 tasks live in era-isolated stores.

### Mid-task input

After detaching, a handler can ask the client for input **during** execution
with [`task_await_input`](@ref): the task parks as `input_required`,
`tasks/get` surfaces the outstanding requests under server-minted keys, and
the client answers through `tasks/update` (partial fulfillment is accepted):

```julia
confirm = MCPTool(
    name = "confirm_delete",
    description = "Delete with confirmation",
    parameters = [ToolParameter(name = "filename", description = "Target",
                                type = "string", required = true)],
    task_support = :optional,
    handler = (args, ctx) -> begin
        task_detach(ctx)
        resp = task_await_input(ctx, elicit_request("Really delete $(args["filename"])?"))
        TextContent(text = "done")
    end)
```

Request params are frozen at registration (plain JSON data only), a task
whose ttl elapses while parked is failed and its waiters unwound, and
cancellation unwinds the handler with [`TaskCancelledException`](@ref)
(distinguish expiry from a client cancel via `task_cancelled(ctx)`).
Returning `InputRequired` *before* detaching runs the normal MRTR round, so a
tool can gather input synchronously and then escalate — the SEP-2663
composition rule.

### Status notifications

Clients subscribe to task status pushes through `subscriptions/listen` with a
`taskIds` filter: every transition — parking on input, resuming, completing,
failing, cancelling, expiring — delivers the task's complete state to
subscribed streams, tagged with the subscription id. The acknowledgment
echoes only ids the requestor could `tasks/get`, and deliveries re-check
authorization per push.

## Subscriptions

`subscriptions/listen` replaces the legacy GET stream and
`resources/subscribe`: a long-lived request whose response stream carries only
the notification types the client opted into (`toolsListChanged`,
`promptsListChanged`, `resourcesListChanged`, `resourceSubscriptions` URIs,
and `taskIds`). Announce changes server-side with
[`notify_list_changed`](@ref) and [`notify_resource_updated`](@ref).

## Argument completion

`completion/complete` serves suggestions for prompt arguments and
resource-template variables in both eras. Configure sources with the
`completions` field on `MCPPrompt` / `ResourceTemplate` — a `Vector{String}`
(served filtered by prefix) or a function receiving the partial value and the
request context's resolved arguments:

```julia
prompt = MCPPrompt(
    name = "city_report",
    arguments = [PromptArgument(name = "city", required = true)],
    messages = [PromptMessage(content = TextContent(text = "Report for {city}"))],
    completions = Dict{String,Any}("city" => ["paris", "london", "tokyo"]))
```

## Header parameter mirroring (`x-mcp-header`)

For transport-level routing, a tool parameter may declare a header-mirroring
suffix — `ToolParameter(header = "Routing-Key")`, or `x-mcp-header` in a raw
`input_schema` — and modern HTTP clients mirror the argument as an
`Mcp-Param-<suffix>` request header. The server validates every mirror
against the body (strict Base64 sentinel handling, exact numeric comparison)
and rejects violations with `-32020`/HTTP 400. Registration refuses invalid
annotations: suffixes must be HTTP tokens, unique per tool, on
`string`/`integer`/`boolean` properties reachable through plain `properties`
chains.

## Per-request logging

`logging/setLevel` does not exist in the modern era. A request opts into
`notifications/message` delivery by setting
`io.modelcontextprotocol/logLevel` in its `_meta`; records at or above that
level are delivered on that request's own response stream only — including
`debug` records below the operator's installed level — and requests without
the opt-in receive none.

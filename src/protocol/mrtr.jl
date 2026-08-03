# src/protocol/mrtr.jl
# MRTR (SEP-2322, 2026-07-28): Multi-Round-Trip Requests — the modern era's
# replacement for server-initiated requests. A handler that needs client input
# (elicitation, sampling, roots) returns an `InputRequired` value; the server
# answers the request with an `InputRequiredResult` (resultType "input_required",
# an `inputRequests` map, and an opaque integrity-protected `requestState`). The
# client retries with a NEW request id, the ORIGINAL params, its `inputResponses`,
# and the echoed `requestState` — the handler simply runs again with the responses
# available via `input_responses(ctx)`. No bidirectional plumbing, so this works on
# the serial server loop and over stateless HTTP.
#
# `requestState` is ATTACKER-CONTROLLED input: it is HMAC-signed over a payload
# embedding issue time + TTL, the authenticated principal, and a canonical digest
# of the original params, and every retry verifies all of them before any handler
# runs. The signing key is per-Server and ephemeral (`mrtr_state_key`).

using SHA: hmac_sha256, sha256

# The only methods on which the spec allows an InputRequiredResult
const MRTR_METHODS = ("tools/call", "resources/read", "prompts/get")

# How long an issued requestState stays retryable
const MRTR_STATE_TTL_SECS = 600

# inputRequests entries may only be these request types; each requires the client
# to have DECLARED the corresponding capability in this request's _meta
const MRTR_REQUEST_CAPABILITIES = Dict{String,String}(
    "elicitation/create" => "elicitation",
    "sampling/createMessage" => "sampling",
    "roots/list" => "roots",
)

"""
    InputRequest(method::String, params)

One entry of an `InputRequiredResult`'s `inputRequests` map: a request the client
should fulfill and answer in its retry's `inputResponses`. Only the three
spec-blessed request types are valid — construct via [`elicit_request`](@ref),
[`sampling_request`](@ref), or [`roots_request`](@ref).

# Fields
- `method::String`: The request method (`elicitation/create`, `sampling/createMessage`, `roots/list`)
- `params::Any`: The request's params (a Dict, or `nothing` for none)
"""
struct InputRequest
    method::String
    params::Any

    function InputRequest(method::String, params)
        haskey(MRTR_REQUEST_CAPABILITIES, method) ||
            throw(ArgumentError("inputRequests entries may only be elicitation/create, sampling/createMessage, or roots/list (got $method)"))
        new(method, params)
    end
end

"""
    elicit_request(message::String; requested_schema=nothing) -> InputRequest

Build a form-mode elicitation input request (`elicitation/create`): ask the user a
question, constraining the answer with a requested schema. The schema is REQUIRED
on the wire (`ElicitRequestFormParams.requestedSchema`, an object schema with
`properties`), so when none is given a minimal empty-object schema is synthesized —
a schema-validating client would reject the request otherwise.

# Arguments
- `message::String`: The message to present to the user
- `requested_schema`: JSON schema (Dict) for the expected response content; must be
  an object schema. Defaults to `{"type": "object", "properties": {}}`

# Returns
- `InputRequest`: The request for an `InputRequired` return
"""
function elicit_request(message::String; requested_schema=nothing)::InputRequest
    schema = requested_schema === nothing ?
        LittleDict{String,Any}("type" => "object", "properties" => LittleDict{String,Any}()) :
        requested_schema
    InputRequest("elicitation/create", LittleDict{String,Any}(
        "message" => message,
        "requestedSchema" => schema,
    ))
end

"""
    sampling_request(params::AbstractDict) -> InputRequest

Build a sampling input request (`sampling/createMessage`): ask the client's LLM for
a completion. `params` is the CreateMessageRequest params object (e.g. `messages`,
`maxTokens`).

# Arguments
- `params::AbstractDict`: The `sampling/createMessage` params

# Returns
- `InputRequest`: The request for an `InputRequired` return
"""
sampling_request(params::AbstractDict)::InputRequest =
    InputRequest("sampling/createMessage", params)

"""
    roots_request() -> InputRequest

Build a roots input request (`roots/list`): ask the client for its filesystem roots.

# Returns
- `InputRequest`: The request for an `InputRequired` return
"""
roots_request()::InputRequest = InputRequest("roots/list", nothing)

"""
    InputRequired(requests::AbstractDict; state=nothing)

The value a handler returns when it needs client input to finish (MRTR,
2026-07-28): the request is answered with an `InputRequiredResult` carrying these
input requests, and the client retries with responses under the same keys. On the
retry the handler runs AGAIN from the top — read the responses with
`input_responses(ctx)` and any carried-over state with `input_state(ctx)`.

Only meaningful on modern-era `tools/call` (legacy sessions have no wire shape for
it and get an error). If a needed response is still missing on the retry, return
another `InputRequired` — the spec says re-issue, not error.

A valid `requestState` can be replayed within its TTL (one-time semantics would
require server-side shared state, which the stateless design avoids), so handlers
should stay idempotent across retries.

# Fields
- `requests::LittleDict{String,InputRequest}`: server-assigned unique keys → input requests
- `state::Any`: JSON-serializable handler state to carry to the retry, delivered
  inside the integrity-protected `requestState` (do NOT put secrets here: it is
  signed, not encrypted)
"""
struct InputRequired <: ResponseResult
    requests::LittleDict{String,InputRequest}
    state::Any

    function InputRequired(requests::AbstractDict; state=nothing)
        reqs = LittleDict{String,InputRequest}()
        for (k, v) in requests
            v isa InputRequest ||
                throw(ArgumentError("InputRequired values must be InputRequest (use elicit_request/sampling_request/roots_request)"))
            reqs[String(k)] = v
        end
        isempty(reqs) && state === nothing &&
            throw(ArgumentError("InputRequired needs at least one input request or a state"))
        new(reqs, state)
    end
end

# Fetch a capability value by String or Symbol key; `nothing` when absent. NOTE:
# JSON null also parses to `nothing`, so use _capability_present when a
# present-but-null value must be distinguished from an absent one.
function _capability_value(caps, name::String)
    caps isa AbstractDict || return nothing
    haskey(caps, name) && return caps[name]
    haskey(caps, Symbol(name)) && return caps[Symbol(name)]
    nothing
end

_capability_present(caps, name::String)::Bool =
    caps isa AbstractDict && (haskey(caps, name) || haskey(caps, Symbol(name)))

# Whether a sampling/createMessage input request asks for tool-enabled sampling —
# either `tools` or `toolChoice` in its params requires the client's
# sampling.tools declared (the schema ties both fields to that capability)
_sampling_wants_tools(r::InputRequest)::Bool =
    r.params isa AbstractDict &&
    (haskey(r.params, "tools") || haskey(r.params, :tools) ||
     haskey(r.params, "toolChoice") || haskey(r.params, :toolChoice))

"""
    capability_satisfied(client_capabilities, r::InputRequest) -> Bool

Whether this request's declared `_meta` client capabilities cover input request
`r`. Declaration means the capability VALUE is an object (a `null` or scalar value
declares nothing — including MODE values: `{"elicitation": {"form": null}}`
declares no form support), and subfeatures are honored:

- form-mode elicitation: `form` declared with an object value covers it, and ONLY
  the bare empty `elicitation` object implies it — any other declared mode set
  (`url`, or modes from a future revision) excludes form
- tool-enabled sampling (`params.tools` OR `params.toolChoice` present): requires
  `sampling.tools` declared as an object, not just `sampling`

# Arguments
- `client_capabilities`: The request's declared client capabilities (any JSON value)
- `r::InputRequest`: The input request to check

# Returns
- `Bool`: true when `r` may be sent to this client
"""
function capability_satisfied(client_capabilities, r::InputRequest)::Bool
    if r.method == "elicitation/create"
        e = _capability_value(client_capabilities, "elicitation")
        e isa AbstractDict || return false
        _capability_present(e, "form") && return _capability_value(e, "form") isa AbstractDict
        # Without an explicit form mode, ONLY the bare empty object implies form
        # support — any other declared mode set (url, or modes from a future
        # revision) excludes it
        return isempty(e)
    elseif r.method == "sampling/createMessage"
        s = _capability_value(client_capabilities, "sampling")
        s isa AbstractDict || return false
        _sampling_wants_tools(r) || return true
        return _capability_value(s, "tools") isa AbstractDict
    elseif r.method == "roots/list"
        return _capability_value(client_capabilities, "roots") isa AbstractDict
    end
    false
end

"""
    undeclared_capability_requirements(ir::InputRequired, client_capabilities)
        -> LittleDict{String,Any}

The `requiredCapabilities` object for the capabilities `ir`'s input requests need
but this request did not declare — a ClientCapabilities-shaped object precise to
the subfeature: `{"elicitation": {"form": {}}}` for a form elicitation,
`{"sampling": {}}` for plain sampling, `{"sampling": {"tools": {}}}` for
tool-enabled sampling. A server MUST NOT send inputRequests the client did not
declare support for: a non-empty return means the request must be rejected with
-32021 carrying this object as `error.data.requiredCapabilities`.

# Arguments
- `ir::InputRequired`: The handler's input-required value
- `client_capabilities`: The request's declared client capabilities (any JSON value)

# Returns
- `LittleDict{String,Any}`: The missing requirements (empty when all declared)
"""
function undeclared_capability_requirements(ir::InputRequired,
                                            client_capabilities)::LittleDict{String,Any}
    req = LittleDict{String,Any}()
    for (_, r) in ir.requests
        capability_satisfied(client_capabilities, r) && continue
        if r.method == "elicitation/create"
            req["elicitation"] = LittleDict{String,Any}("form" => LittleDict{String,Any}())
        elseif r.method == "sampling/createMessage"
            # Merge: a tool-enabled request upgrades the requirement to
            # sampling.tools without a later plain one downgrading it
            entry = get!(req, "sampling", LittleDict{String,Any}())
            _sampling_wants_tools(r) && (entry["tools"] = LittleDict{String,Any}())
        elseif r.method == "roots/list"
            req["roots"] = LittleDict{String,Any}()
        end
    end
    req
end

"""
    canonicalize_json(x) -> Any

Rebuild a JSON value with all object keys sorted (recursively), producing a
serialization-stable structure for digesting. Non-container values pass through.

# Arguments
- `x`: Any parsed JSON value

# Returns
- The canonical structure
"""
function canonicalize_json(x)
    if x isa AbstractDict
        prs = Tuple{String,Any}[(String(k), v) for (k, v) in pairs(x)]
        sort!(prs, by = first)
        d = LittleDict{String,Any}()
        for (k, v) in prs
            d[k] = canonicalize_json(v)
        end
        d
    elseif x isa AbstractVector
        Any[canonicalize_json(v) for v in x]
    else
        x
    end
end

"""
    canonical_json_digest(x) -> String

SHA-256 hex digest of the canonical (sorted-key) JSON serialization of `x`. Used to
bind an issued `requestState` to the exact original params it may resume.

# Arguments
- `x`: Any parsed JSON value

# Returns
- `String`: The hex digest
"""
canonical_json_digest(x)::String = bytes2hex(sha256(JSON3.write(canonicalize_json(x))))

"""
    principal_identity(user::AuthenticatedUser) -> String

The canonical, collision-free identity string for an authenticated principal:
the JSON array `[provider, subject]`. Two identity providers can issue the same
`sub`, so the subject alone must never identify a principal; JSON encoding (not
delimiter concatenation) makes the pair unambiguous — `("a", "b\\x1fc")` and
`("a\\x1fb", "c")` cannot collide. `username` is display-oriented and mutable,
so it never participates.
"""
principal_identity(user::AuthenticatedUser)::String =
    JSON3.write([user.provider, user.subject])

"""
    mrtr_principal(user::Union{AuthenticatedUser,Nothing}) -> String

The principal string bound into a `requestState`: the canonical
provider-qualified identity (see [`principal_identity`](@ref)), or `""` when the
request is unauthenticated. A state issued to one principal must not be
redeemable by another — including a DIFFERENT provider's token that happens to
carry the same subject.

# Arguments
- `user::Union{AuthenticatedUser,Nothing}`: The request's authenticated user

# Returns
- `String`: The principal
"""
mrtr_principal(user::Union{AuthenticatedUser,Nothing})::String =
    user === nothing ? "" : principal_identity(user)

# Constant-time byte comparison (an early-exit == would leak how many MAC bytes
# matched)
function _ct_eq(a::AbstractVector{UInt8}, b::AbstractVector{UInt8})::Bool
    length(a) == length(b) || return false
    diff = UInt8(0)
    for i in eachindex(a)
        diff |= a[i] ⊻ b[i]
    end
    diff == 0x00
end

"""
    issue_request_state(server::Server, method::String, params_digest,
                        principal::String, handler_state) -> String

Mint an integrity-protected `requestState` token: an HMAC-SHA256-signed payload
embedding issue time + TTL, the principal, the ORIGINATING METHOD, the canonical
digest of the original request params, and the handler's carried state. Signed with
the per-server key, so a token survives neither tampering nor (with the default
ephemeral key) a server restart. Binding the method prevents cross-method state
confusion: `tools/call` and `prompts/get` params can be structurally identical, and
a token issued for one must not resume the other.

# Arguments
- `server::Server`: The server (holds the signing key)
- `method::String`: The request method the state was issued for
- `params_digest`: The request's canonical params digest (from `RequestMeta`)
- `principal::String`: The requesting principal (`mrtr_principal`)
- `handler_state`: The handler's JSON-serializable state (may be `nothing`)

# Returns
- `String`: The token (`base64(payload).base64(mac)`)
"""
function issue_request_state(server::Server, method::String, params_digest,
                             principal::String, handler_state)::String
    # v2: the principal (`sub`) is the provider-qualified principal_identity
    # encoding. The version gates the FORMAT — a v1 token (subject-only sub)
    # must fail as "unsupported version", not as a confusing principal
    # mismatch, and mixed-version replica fleets sharing a key must drain
    # in-flight exchanges (<= the state TTL) across such an upgrade.
    payload = JSON3.write(LittleDict{String,Any}(
        "v" => 2,
        "iat" => round(Int, time()),
        "ttl" => MRTR_STATE_TTL_SECS,
        "sub" => principal,
        "mth" => method,
        "dig" => something(params_digest, ""),
        "st" => handler_state,
    ))
    mac = hmac_sha256(server.mrtr_state_key, payload)
    string(base64encode(payload), ".", base64encode(mac))
end

"""
    verify_request_state(server::Server, token::AbstractString, method::String,
                         params_digest, principal::String) -> Tuple{Bool,Any}

Verify a retry's `requestState` BEFORE any handler runs: signature (constant-time),
TTL, principal, originating method, and original-params digest must all hold — the
token is attacker-controlled input. Returns `(true, handler_state)` on success or
`(false, reason)` on any failure.

# Arguments
- `server::Server`: The server (holds the signing key)
- `token::AbstractString`: The offered `requestState`
- `method::String`: THIS request's method (must equal the issuing method)
- `params_digest`: THIS request's canonical params digest (must equal the original's)
- `principal::String`: THIS request's principal

# Returns
- `Tuple{Bool,Any}`: `(ok, handler_state_or_reason)`
"""
function verify_request_state(server::Server, token::AbstractString, method::String,
                              params_digest, principal::String)::Tuple{Bool,Any}
    parts = split(token, '.')
    length(parts) == 2 || return (false, "malformed token")
    payload_json, mac = try
        (String(base64decode(parts[1])), base64decode(parts[2]))
    catch
        return (false, "malformed token")
    end
    _ct_eq(mac, hmac_sha256(server.mrtr_state_key, payload_json)) ||
        return (false, "signature mismatch")
    payload = try
        JSON3.read(payload_json)
    catch
        return (false, "malformed token")
    end
    get(payload, :v, nothing) == 2 || return (false, "unsupported version")
    iat = get(payload, :iat, nothing)
    ttl = get(payload, :ttl, nothing)
    (iat isa Integer && ttl isa Integer && time() <= iat + ttl) ||
        return (false, "expired")
    String(get(payload, :sub, "")) == principal || return (false, "principal mismatch")
    String(get(payload, :mth, "")) == method || return (false, "method mismatch")
    String(get(payload, :dig, "")) == something(params_digest, "") ||
        return (false, "params do not match the original request")
    (true, get(payload, :st, nothing))
end

"""
    input_required_envelope(server::Server, ir::InputRequired, method::String,
                            params_digest, principal::String) -> LittleDict{String,Any}

Build the `InputRequiredResult` wire shape for a handler's `InputRequired` value:
`resultType: "input_required"`, the `inputRequests` map (each entry
`{method, params?}`), and a freshly minted `requestState` bound to this method,
principal, and params digest. Capability checking is the caller's job
(`undeclared_capability_requirements`) — it must reject with -32021 BEFORE building
this envelope.

# Arguments
- `server::Server`: The server
- `ir::InputRequired`: The handler's value
- `method::String`: The request method (bound into the state token)
- `params_digest`: The request's canonical params digest
- `principal::String`: The requesting principal

# Returns
- `LittleDict{String,Any}`: The result object
"""
function input_required_envelope(server::Server, ir::InputRequired, method::String,
                                 params_digest, principal::String)::LittleDict{String,Any}
    reqs = LittleDict{String,Any}()
    for (k, r) in ir.requests
        entry = LittleDict{String,Any}("method" => r.method)
        r.params === nothing || (entry["params"] = r.params)
        reqs[k] = entry
    end
    LittleDict{String,Any}(
        "resultType" => "input_required",
        "inputRequests" => reqs,
        "requestState" => issue_request_state(server, method, params_digest, principal, ir.state),
    )
end

# The ctx accessors `input_responses(ctx)` / `input_state(ctx)` live in
# handlers.jl (they need RequestContext, which is defined after this file).

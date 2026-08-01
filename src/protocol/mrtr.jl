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

Build an elicitation input request (`elicitation/create`): ask the user a question,
optionally constraining the answer with a requested schema.

# Arguments
- `message::String`: The message to present to the user
- `requested_schema`: Optional JSON schema (Dict) for the expected response content

# Returns
- `InputRequest`: The request for an `InputRequired` return
"""
function elicit_request(message::String; requested_schema=nothing)::InputRequest
    params = LittleDict{String,Any}("message" => message)
    requested_schema === nothing || (params["requestedSchema"] = requested_schema)
    InputRequest("elicitation/create", params)
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

"""
    missing_capabilities(ir::InputRequired, client_capabilities) -> Vector{String}

The client capabilities `ir`'s input requests need but `client_capabilities` (this
request's declared `_meta` capabilities object) does not include. A server MUST NOT
send inputRequests the client did not declare support for — a non-empty return
means the request must be rejected with -32021.

# Arguments
- `ir::InputRequired`: The handler's input-required value
- `client_capabilities`: The request's declared client capabilities (any JSON value)

# Returns
- `Vector{String}`: Sorted capability keys that are required but undeclared
"""
function missing_capabilities(ir::InputRequired, client_capabilities)::Vector{String}
    declared(cap) = client_capabilities isa AbstractDict &&
        (haskey(client_capabilities, cap) || haskey(client_capabilities, Symbol(cap)))
    missing = Set{String}()
    for (_, r) in ir.requests
        cap = MRTR_REQUEST_CAPABILITIES[r.method]
        declared(cap) || push!(missing, cap)
    end
    sort!(collect(missing))
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
    mrtr_principal(user::Union{AuthenticatedUser,Nothing}) -> String

The principal string bound into a `requestState`: the authenticated subject, or
`""` when the request is unauthenticated. A state issued to one principal must not
be redeemable by another.

# Arguments
- `user::Union{AuthenticatedUser,Nothing}`: The request's authenticated user

# Returns
- `String`: The principal
"""
mrtr_principal(user::Union{AuthenticatedUser,Nothing})::String =
    user === nothing ? "" : user.subject

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
    issue_request_state(server::Server, params_digest, principal::String, handler_state) -> String

Mint an integrity-protected `requestState` token: an HMAC-SHA256-signed payload
embedding issue time + TTL, the principal, the canonical digest of the original
request params, and the handler's carried state. Signed with the per-server
ephemeral key, so a token survives neither tampering nor a server restart.

# Arguments
- `server::Server`: The server (holds the signing key)
- `params_digest`: The request's canonical params digest (from `RequestMeta`)
- `principal::String`: The requesting principal (`mrtr_principal`)
- `handler_state`: The handler's JSON-serializable state (may be `nothing`)

# Returns
- `String`: The token (`base64(payload).base64(mac)`)
"""
function issue_request_state(server::Server, params_digest, principal::String,
                             handler_state)::String
    payload = JSON3.write(LittleDict{String,Any}(
        "v" => 1,
        "iat" => round(Int, time()),
        "ttl" => MRTR_STATE_TTL_SECS,
        "sub" => principal,
        "dig" => something(params_digest, ""),
        "st" => handler_state,
    ))
    mac = hmac_sha256(server.mrtr_state_key, payload)
    string(base64encode(payload), ".", base64encode(mac))
end

"""
    verify_request_state(server::Server, token::AbstractString, params_digest,
                         principal::String) -> Tuple{Bool,Any}

Verify a retry's `requestState` BEFORE any handler runs: signature (constant-time),
TTL, principal, and original-params digest must all hold — the token is
attacker-controlled input. Returns `(true, handler_state)` on success or
`(false, reason)` on any failure.

# Arguments
- `server::Server`: The server (holds the signing key)
- `token::AbstractString`: The offered `requestState`
- `params_digest`: THIS request's canonical params digest (must equal the original's)
- `principal::String`: THIS request's principal

# Returns
- `Tuple{Bool,Any}`: `(ok, handler_state_or_reason)`
"""
function verify_request_state(server::Server, token::AbstractString, params_digest,
                              principal::String)::Tuple{Bool,Any}
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
    get(payload, :v, nothing) == 1 || return (false, "unsupported version")
    iat = get(payload, :iat, nothing)
    ttl = get(payload, :ttl, nothing)
    (iat isa Integer && ttl isa Integer && time() <= iat + ttl) ||
        return (false, "expired")
    String(get(payload, :sub, "")) == principal || return (false, "principal mismatch")
    String(get(payload, :dig, "")) == something(params_digest, "") ||
        return (false, "params do not match the original request")
    (true, get(payload, :st, nothing))
end

"""
    input_required_envelope(server::Server, ir::InputRequired, params_digest,
                            principal::String) -> LittleDict{String,Any}

Build the `InputRequiredResult` wire shape for a handler's `InputRequired` value:
`resultType: "input_required"`, the `inputRequests` map (each entry
`{method, params?}`), and a freshly minted `requestState`. Capability checking is
the caller's job (`missing_capabilities`) — it must reject with -32021 BEFORE
building this envelope.

# Arguments
- `server::Server`: The server
- `ir::InputRequired`: The handler's value
- `params_digest`: The request's canonical params digest
- `principal::String`: The requesting principal

# Returns
- `LittleDict{String,Any}`: The result object
"""
function input_required_envelope(server::Server, ir::InputRequired, params_digest,
                                 principal::String)::LittleDict{String,Any}
    reqs = LittleDict{String,Any}()
    for (k, r) in ir.requests
        entry = LittleDict{String,Any}("method" => r.method)
        r.params === nothing || (entry["params"] = r.params)
        reqs[k] = entry
    end
    LittleDict{String,Any}(
        "resultType" => "input_required",
        "inputRequests" => reqs,
        "requestState" => issue_request_state(server, params_digest, principal, ir.state),
    )
end

# The ctx accessors `input_responses(ctx)` / `input_state(ctx)` live in
# handlers.jl (they need RequestContext, which is defined after this file).

# src/transports/http.jl

using HTTP
using JSON3
using UUIDs: uuid4
using Sockets: IPv4, IPv6
using Base64: base64decode

"""
    QueuedHttpRequest(id, body, user)

Envelope for a request on the HTTP work queue. Carries the per-request
authenticated `user` (or `nothing`) from the concurrent connection handler to the
single server loop, so auth identity travels with the request rather than via
shared transport state.
"""
struct QueuedHttpRequest
    id::String
    body::String
    user::Union{AuthenticatedUser,Nothing}
end

"""
    HttpTransport(; host::String="127.0.0.1", port::Int=8080, endpoint::String="/",
                  allowed_origins::Vector{String}=String[], allowed_hosts::Vector{String}=String[])

Transport implementation following the MCP Streamable HTTP specification (2025-06-18).
Supports Server-Sent Events (SSE) for streaming and session management. A request's
response is a single JSON object, or — when request-scoped notifications (progress,
log messages) are emitted during handling — an SSE stream scoped to that request.

When bound to a loopback host without bearer auth, requests whose Host or Origin
header is neither local nor allowlisted are rejected with 403 (DNS-rebinding
protection); a deployment behind a reverse proxy adds its public hostname to
`allowed_hosts` (or enables auth, which disables the guard).

# Fields
- `host::String`: Host address to bind to (default: "127.0.0.1")
- `port::Int`: Port number to listen on (default: 8080)
- `endpoint::String`: HTTP endpoint path (default: "/")
- `server::Union{HTTP.Server,Nothing}`: HTTP server instance
- `connected::Bool`: Connection status
- `server_task::Union{Task,Nothing}`: Server task handle
- `active_streams::Dict{String,HTTP.Stream}`: Active streaming connections
- `request_queue::Channel{QueuedHttpRequest}`: Queue for incoming requests (id, body, auth user)
- `response_channels::Dict{String,Channel{Tuple{Symbol,String}}}`: Per-request response
  routes carrying `(:notification, json)` entries followed by one `(:response, json)`
- `allowed_origins::Vector{String}`: Origins accepted by the DNS-rebinding guard (exact match)
- `allowed_hosts::Vector{String}`: Extra Host-header hostnames accepted by the DNS-rebinding guard
"""
mutable struct HttpTransport <: Transport
    host::String
    port::Int
    endpoint::String
    server::Union{HTTP.Server,Nothing}
    connected::Bool
    server_task::Union{Task,Nothing}
    active_streams::Dict{String,HTTP.Stream}
    sse_streams::Dict{String,HTTP.Stream}  # SSE connections
    request_queue::Channel{QueuedHttpRequest}
    response_channels::Dict{String,Channel{Tuple{Symbol,String}}}  # (:notification|:response, payload) per request
    notification_queue::Channel{String}  # For SSE notifications
    current_request_id::Union{String,Nothing}
    current_request_auth::Union{AuthenticatedUser,Nothing}  # Auth user of the message just read; set in the single server loop, never across connections
    session_id::Union{String,Nothing}  # Session management
    session_required::Bool  # Whether session is required after init
    protocol_version::String  # MCP protocol version
    event_counter::Int64  # SSE event IDs
    allowed_origins::Vector{String}  # CORS security
    allowed_hosts::Vector{String}  # Extra Host-header hostnames accepted by the DNS-rebinding guard
    auth::Union{AuthMiddleware,Nothing}  # OAuth Resource Server token validation (nothing = disabled)
    resource_metadata::Union{ProtectedResourceMetadata,Nothing}  # RFC 9728 Protected Resource Metadata
    channels_lock::ReentrantLock  # guards response_channels/active_streams (HTTP connection tasks + server loop + deferred-response waiters)
    sse_keepalive_secs::Float64  # idle interval between SSE keepalive comments (a WRITE is the only way to notice a silently-dead peer)

    function HttpTransport(;
        host::String="127.0.0.1",
        port::Int=8080,
        endpoint::String="/",
        allowed_origins::Vector{String}=String[],
        allowed_hosts::Vector{String}=String[],
        protocol_version::String=LATEST_PROTOCOL_VERSION,
        session_required::Bool=false,
        auth::Union{AuthMiddleware,Nothing}=nothing,
        resource_metadata::Union{ProtectedResourceMetadata,Nothing}=nothing,
        sse_keepalive_secs::Real=15.0
    )
        # The keepalive is what detects silently-dead SSE peers: Inf/NaN would
        # disable that detection entirely, and non-positive values busy-write.
        # Validate the CONVERTED value — a subnormal BigFloat is finite and
        # positive but stores as 0.0, and a huge one stores as Inf.
        keepalive = Float64(sse_keepalive_secs)
        isfinite(keepalive) && keepalive > 0 ||
            throw(ArgumentError("sse_keepalive_secs must be finite and positive, got $sse_keepalive_secs"))
        new(
            host,
            port,
            endpoint,
            nothing,
            false,
            nothing,
            Dict{String,HTTP.Stream}(),
            Dict{String,HTTP.Stream}(),  # SSE streams
            Channel{QueuedHttpRequest}(32),  # Buffer up to 32 requests
            Dict{String,Channel{Tuple{Symbol,String}}}(),
            # Unbounded with a soft cap enforced in send_notification: the GET SSE
            # consumer is OPTIONAL per spec, so a bounded channel with blocking put!
            # would let a POST-only client stall the single server loop once full
            Channel{String}(Inf),
            nothing,  # current_request_id
            nothing,  # current_request_auth
            nothing,  # No session initially
            session_required,
            protocol_version,
            0,  # Event counter starts at 0
            allowed_origins,
            allowed_hosts,
            auth,
            resource_metadata,
            ReentrantLock(),
            keepalive
        )
    end
end

"""
    is_valid_session_id(session_id::String) -> Bool

Validate that a session ID contains only visible ASCII characters (0x21 to 0x7E).

# Arguments
- `session_id::String`: The session ID to validate

# Returns
- `Bool`: true if valid, false otherwise
"""
function is_valid_session_id(session_id::String)::Bool
    # Empty session IDs are invalid
    if isempty(session_id)
        return false
    end
    
    for char in session_id
        code = Int(char)
        if code < 0x21 || code > 0x7E
            return false
        end
    end
    return true
end

"""
    generate_session_id() -> String

Generate a cryptographically secure session ID that meets MCP requirements.
Must contain only visible ASCII characters (0x21 to 0x7E).

# Returns
- `String`: A valid session ID
"""
function generate_session_id()::String
    # Use UUID which contains only alphanumeric and hyphens (all valid ASCII)
    return string(uuid4())
end

# Soft cap on pending out-of-band notifications when no GET SSE consumer drains them
const NOTIFICATION_QUEUE_SOFTCAP = 1000

# Max pending items on a subscriptions/listen response channel before the stream is
# load-shed (see deliver_notification): listen streams live indefinitely, so their
# backlog cannot be bounded by request lifetime like ordinary response channels.
const LISTEN_BACKLOG_CAP = 256

"""
    parse_host_header(hostport::AbstractString) -> Union{String,Nothing}

Parse a Host-header style `host[:port]` value strictly, returning the lowercased
hostname or `nothing` when the value is malformed (userinfo, multiple colons on a
non-bracketed host, junk after a bracketed IPv6 literal, non-numeric port). Malformed
values must be REJECTED by the DNS-rebinding guard, not leniently truncated into
something that looks local (`[::1]evil.example` must not read as `[::1]`).

# Arguments
- `hostport::AbstractString`: A Host-header style value

# Returns
- `Union{String,Nothing}`: The lowercased hostname (brackets kept for IPv6 literals),
  or `nothing` when malformed
"""
function parse_host_header(hostport::AbstractString)::Union{String,Nothing}
    h = lowercase(strip(hostport))
    isempty(h) && return nothing
    occursin('@', h) && return nothing  # userinfo smuggling
    if startswith(h, "[")
        idx = findfirst(']', h)
        isnothing(idx) && return nothing
        rest = h[nextind(h, idx):end]
        if !isempty(rest)
            startswith(rest, ":") || return nothing  # junk after the bracket
            port = rest[2:end]
            (isempty(port) || !all(isdigit, port)) && return nothing
        end
        return h[1:idx]
    end
    parts = split(h, ':')
    length(parts) > 2 && return nothing  # "host:80:evil" and unbracketed IPv6
    isempty(parts[1]) && return nothing
    if length(parts) == 2
        (isempty(parts[2]) || !all(isdigit, parts[2])) && return nothing
    end
    return String(parts[1])
end

"""
    is_loopback_host(host::AbstractString) -> Bool

Determine whether a hostname refers to the local loopback: `localhost` (optionally
with a trailing dot), any 127.0.0.0/8 IPv4 address, `::1`, or an IPv4-mapped IPv6
loopback (`::ffff:127.x.y.z`). String-list matching is not enough here — binding or
addressing via `127.0.0.2` is just as local as `127.0.0.1`.

# Arguments
- `host::AbstractString`: Hostname, IP literal, or bracketed IPv6 literal

# Returns
- `Bool`: true if the host is loopback
"""
function is_loopback_host(host::AbstractString)::Bool
    h = lowercase(strip(host))
    endswith(h, ".") && (h = chop(h))
    h == "localhost" && return true
    if startswith(h, "[") && endswith(h, "]")
        h = h[2:prevind(h, lastindex(h))]
    end
    # No tryparse methods exist for IP types; parse throws on non-IP strings
    ip4 = try parse(IPv4, h) catch; nothing end
    ip4 !== nothing && return (ip4.host >>> 24) == 127
    ip6 = try parse(IPv6, h) catch; nothing end
    if ip6 !== nothing
        ip6.host == UInt128(1) && return true  # ::1
        # IPv4-mapped loopback ::ffff:127.x.y.z
        return (ip6.host >>> 32) == 0xffff && ((ip6.host >>> 24) & 0xff) == 0x7f
    end
    return false
end

"""
    rebinding_violation(host_header, origin_header, allowed_hosts, allowed_origins) -> Union{String,Nothing}

Check Host and Origin headers against DNS-rebinding attacks on a loopback-bound
server (GHSA-w48q-cv73-mx4w class): a malicious website resolves its own domain to
127.0.0.1 and drives the local server from the victim's browser. A legitimate local
client sends a loopback Host; the attack necessarily carries the attacker's hostname.
Malformed Host values are violations (see `parse_host_header`). `allowed_hosts`
applies to the Host header only; Origin is admitted by loopback hostname or an exact
`allowed_origins` match — a proxy hostname in `allowed_hosts` deliberately does NOT
admit browser origins on that host.

# Arguments
- `host_header`: The request's Host header value ("" when absent)
- `origin_header`: The request's Origin header value ("" when absent)
- `allowed_hosts`: Extra hostnames accepted in Host (e.g. a reverse-proxy domain)
- `allowed_origins`: Full origins accepted in Origin (exact match, existing semantics)

# Returns
- `Union{String,Nothing}`: A human-readable violation description, or `nothing` if the
  request is acceptable
"""
function rebinding_violation(host_header::AbstractString, origin_header::AbstractString,
                             allowed_hosts::Vector{String},
                             allowed_origins::Vector{String})::Union{String,Nothing}
    if !isempty(host_header)
        hostname = parse_host_header(host_header)
        isnothing(hostname) && return "Host header '$host_header' is malformed"
        if !is_loopback_host(hostname) &&
           !(hostname in (lowercase(h) for h in allowed_hosts))
            return "Host header '$host_header' is not a permitted hostname"
        end
    end
    if !isempty(origin_header)
        # HTTP.URI separates host and port already (no strip needed; stripping would
        # mangle an unbracketed IPv6 host like "::1")
        origin_host = try
            lowercase(String(HTTP.URI(origin_header).host))
        catch
            ""
        end
        if !(origin_header in allowed_origins) && !is_loopback_host(origin_host)
            return "Origin header '$origin_header' is not a permitted origin"
        end
    end
    return nothing
end

"""
    format_sse_event(data::String; event::Union{String,Nothing}=nothing, id::Union{Int64,String,Nothing}=nothing) -> String

Format a message as a Server-Sent Event.

# Arguments
- `data::String`: The data to send
- `event::Union{String,Nothing}`: Optional event type
- `id::Union{Int64,String,Nothing}`: Optional event ID

# Returns
- `String`: Formatted SSE event
"""
function format_sse_event(data::String; event::Union{String,Nothing}=nothing, id::Union{Int64,String,Nothing}=nothing)
    parts = String[]
    
    if !isnothing(event)
        push!(parts, "event: $event")
    end
    
    if !isnothing(id)
        push!(parts, "id: $id")
    end
    
    # Split data by newlines and format each line
    for line in split(data, '\n')
        push!(parts, "data: $line")
    end
    
    # SSE events end with double newline
    return join(parts, "\n") * "\n\n"
end

"""
    handle_sse_stream(transport::HttpTransport, stream::HTTP.Stream, stream_id::String)

Handle a Server-Sent Events connection for notifications and streaming responses.

# Arguments
- `transport::HttpTransport`: The transport instance
- `stream::HTTP.Stream`: The HTTP stream
- `stream_id::String`: Unique identifier for this SSE stream

# Returns
- `Nothing`
"""
function handle_sse_stream(transport::HttpTransport, stream::HTTP.Stream, stream_id::String)
    request = stream.message
    
    # Check for Last-Event-ID header for resumption
    last_event_id = HTTP.header(request, "Last-Event-ID", "")
    if !isempty(last_event_id)
        # In a full implementation, we'd resume from this event
        @debug "SSE resumption requested" last_event_id=last_event_id
    end
    
    # Set up SSE headers
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.setheader(stream, "Connection" => "keep-alive")
    HTTP.setheader(stream, "X-Accel-Buffering" => "no")  # Disable nginx buffering
    
    # Start writing the stream
    HTTP.startwrite(stream)
    
    # Send initial connection event
    transport.event_counter += 1
    connection_event = format_sse_event(
        JSON3.write(Dict("type" => "connection", "status" => "connected")),
        event="connection",
        id=transport.event_counter
    )
    write(stream, connection_event)
    Base.flush(stream)
    
    # Store the SSE stream
    transport.sse_streams[stream_id] = stream
    
    try
        # Keep connection alive and send notifications.
        #
        # This loop deliberately polls `isready` instead of blocking in `take!`. The
        # previous implementation spawned a fresh `@async take!` waiter every 100ms
        # iteration and abandoned the old one; Channel waiters wake FIFO, so each
        # arriving notification was handed to an orphaned waiter and silently lost.
        # (It also called bare `close(timer)`, which resolves to this package's
        # `close(::Transport)` rather than `Base.close` — a MethodError on the first
        # iteration that the catch below swallowed, dropping the stream. Regression
        # test: "SSE notification delivery (issue #71 regression)".)
        while transport.connected && isopen(stream)
            ch = transport.notification_queue
            if !isready(ch)
                isopen(ch) || break  # queue closed and drained: shutting down
                sleep(0.01)
                continue
            end
            notification = take!(ch)

            transport.event_counter += 1
            event = format_sse_event(
                notification,
                event="message",
                id=transport.event_counter
            )
            write(stream, event)
            Base.flush(stream)
        end
    catch e
        @debug "SSE stream closed" stream_id=stream_id error=e
    finally
        # Clean up
        delete!(transport.sse_streams, stream_id)
    end
end

"""
    split_outside_quotes(s::AbstractString, delim::Char) -> Vector{String}

Split `s` on `delim` occurrences that lie OUTSIDE double-quoted strings, honoring
backslash escapes inside quotes (RFC 9110 quoted-string). Header parameters may
legally quote separator characters (`profile="a,b"`), so a naive `split` corrupts
the ranges around them.

# Arguments
- `s::AbstractString`: The header text to split
- `delim::Char`: The separator character

# Returns
- `Vector{String}`: The parts (quotes preserved verbatim)
"""
function split_outside_quotes(s::AbstractString, delim::Char)::Vector{String}
    parts = String[]
    buf = IOBuffer()
    inq = false
    esc = false
    for c in s
        if esc
            write(buf, c)
            esc = false
        elseif inq && c == '\\'
            write(buf, c)
            esc = true
        elseif c == '"'
            inq = !inq
            write(buf, c)
        elseif c == delim && !inq
            push!(parts, String(take!(buf)))
        else
            write(buf, c)
        end
    end
    push!(parts, String(take!(buf)))
    parts
end

"""
    accepts_sse(accept_header::AbstractString) -> Bool

Whether an `Accept` header admits a `text/event-stream` response, per media-range
matching: comma-separated ranges, media types compared case-insensitively with
parameters stripped, `text/*` and `*/*` admitted, and `q=0` a refusal. The MOST
SPECIFIC matching range decides (RFC 9110 precedence): exact `text/event-stream`
over `text/*` over `*/*` — so `text/event-stream;q=0, text/*;q=1` is a refusal
even though a laxer range matches. A bare substring test gets all of this wrong.

Pass the COMBINED value when the request repeats the `Accept` field (repeated
fields are equivalent to their comma-joined concatenation).

# Arguments
- `accept_header::AbstractString`: The request's (combined) `Accept` header value

# Returns
- `Bool`: true when the client can consume an SSE response
"""
function accepts_sse(accept_header::AbstractString)::Bool
    best_spec = -1
    best_q = 0.0
    for item in split_outside_quotes(accept_header, ',')
        parts = split_outside_quotes(item, ';')
        mt = lowercase(strip(parts[1]))
        spec = mt == "text/event-stream" ? 2 : mt == "text/*" ? 1 : mt == "*/*" ? 0 : -1
        spec == -1 && continue
        q = 1.0
        for p in parts[2:end]
            kv = split(p, '='; limit = 2)
            if length(kv) == 2 && lowercase(strip(kv[1])) == "q"
                q = something(tryparse(Float64, strip(kv[2])), 0.0)
            end
        end
        if spec > best_spec
            best_spec = spec
            best_q = q
        elseif spec == best_spec
            best_q = max(best_q, q)  # equal specificity: an accepting duplicate wins
        end
    end
    best_spec >= 0 && best_q > 0
end

# Modern methods whose Mcp-Name header mirrors a body field (SEP-2243)
const MCP_NAME_METHODS = Dict(
    "tools/call" => "name",
    "prompts/get" => "name",
    "resources/read" => "uri",
)

"""
    mcp_standard_header(request, name::String) -> Union{String,Nothing,Symbol}

Fetch a SEP-2243 standard header strictly: header names are matched
case-insensitively across ALL header instances; duplicates (a smuggling vector —
a gateway may honor a different copy than the backend) and values containing
non-visible-ASCII bytes (NUL/control/8-bit, which HTTP.jl's parser admits but
intermediaries interpret divergently) are rejected. Returns the single
whitespace-stripped value, `nothing` when absent, or `:invalid` when the header
must cause a -32020 rejection.

# Arguments
- `request`: The HTTP request
- `name::String`: The header name

# Returns
- `Union{String,Nothing,Symbol}`: Value, `nothing` (absent), or `:invalid`
"""
function mcp_standard_header(request, name::String)
    lname = lowercase(name)
    values = [String(v) for (k, v) in HTTP.headers(request) if lowercase(String(k)) == lname]
    isempty(values) && return nothing
    length(values) > 1 && return :invalid
    v = values[1]
    all(b -> 0x20 <= b <= 0x7e || b == UInt8('\t'), codeunits(v)) || return :invalid
    return String(strip(v))
end

"""
    decode_mcp_header_value(value::AbstractString) -> Union{String,Nothing}

Decode a standard-header value per SEP-2243: a `=?base64?...?=` sentinel wraps a
Base64-encoded UTF-8 payload (used when the raw value is not header-safe). The
Base64 is validated STRICTLY — canonical alphabet, correct padding, length a
multiple of four — because Julia's decoder is permissive (it ignores invalid
characters and missing padding), and SEP-2243 requires such values to be rejected,
not fuzzily matched. The decoded bytes must be valid UTF-8. Returns `nothing` when
the value must cause a -32020 rejection.

# Arguments
- `value::AbstractString`: The header value (already whitespace-stripped)

# Returns
- `Union{String,Nothing}`: The decoded value, or `nothing` when malformed
"""
function decode_mcp_header_value(value::AbstractString)::Union{String,Nothing}
    s = String(value)
    if startswith(s, "=?base64?") && endswith(s, "?=")
        ncodeunits(s) < ncodeunits("=?base64?") + ncodeunits("?=") + 1 && return nothing
        # Byte-safe slice (prefix/suffix are ASCII; interior bytes may be anything)
        payload = String(codeunits(s)[(ncodeunits("=?base64?") + 1):(end - 2)])
        # Strict canonical Base64: alphabet + padding + length
        occursin(r"^[A-Za-z0-9+/]+={0,2}$", payload) || return nothing
        ncodeunits(payload) % 4 == 0 || return nothing
        decoded = try
            String(base64decode(payload))
        catch
            return nothing
        end
        all(isvalid, decoded) || return nothing  # reject non-UTF-8 payloads
        return decoded
    end
    return s
end

"""
    modern_header_violation(request, msg, body_version) -> Union{String,Nothing}

Validate the SEP-2243 standard request headers of a modern-era POST against its body:
`MCP-Protocol-Version` and `Mcp-Method` are required on every request and must match
the body's `_meta` protocol version and `method`; `Mcp-Name` is required on
`tools/call`/`prompts/get` (mirroring `params.name`) and `resources/read` (mirroring
`params.uri`), with the Base64 sentinel decoded before comparison. Header names are
case-insensitive, duplicates and unsafe bytes are rejected (`mcp_standard_header`),
values are compared case-sensitively after whitespace stripping. (A request whose
headers claim a modern era while the body carries no modern `_meta` never reaches
this function — the caller rejects it as a missing required field, -32602.)

# Arguments
- `request`: The HTTP request (for header access)
- `msg`: The parsed JSON body (a `JSON3.Object`)
- `body_version`: The body's `_meta` protocol version

# Returns
- `Union{String,Nothing}`: A violation description for a -32020 HeaderMismatch, or
  `nothing` when the headers validate
"""
function modern_header_violation(request, msg, body_version::String)::Union{String,Nothing}
    header_version = mcp_standard_header(request, "MCP-Protocol-Version")
    header_version === :invalid &&
        return "MCP-Protocol-Version header is duplicated or contains unsafe characters"
    header_version === nothing &&
        return "required header MCP-Protocol-Version is missing"
    header_version != body_version &&
        return "MCP-Protocol-Version header '$header_version' does not match body value '$body_version'"

    method = get(msg, "method", nothing)
    method isa AbstractString ||
        return "body method is not a string"
    method = String(method)
    header_method = mcp_standard_header(request, "Mcp-Method")
    header_method === :invalid &&
        return "Mcp-Method header is duplicated or contains unsafe characters"
    header_method === nothing &&
        return "required header Mcp-Method is missing"
    header_method != method &&
        return "Mcp-Method header '$header_method' does not match body method '$method'"

    if haskey(MCP_NAME_METHODS, method)
        field = MCP_NAME_METHODS[method]
        body_name = get(msg, "params", nothing) isa JSON3.Object ?
                    get(msg.params, Symbol(field), nothing) : nothing
        header_name_raw = mcp_standard_header(request, "Mcp-Name")
        header_name_raw === :invalid &&
            return "Mcp-Name header is duplicated or contains unsafe characters"
        header_name_raw === nothing &&
            return "required header Mcp-Name is missing for $method"
        header_name = decode_mcp_header_value(header_name_raw)
        header_name === nothing &&
            return "Mcp-Name header carries a malformed Base64 sentinel value"
        if !(body_name isa AbstractString) || header_name != String(body_name)
            return "Mcp-Name header does not match body params.$field"
        end
    end

    return nothing
end

"""
    modern_error_http_status(payload::String) -> Int

Map a modern-era JSON-RPC response to its HTTP status per the 2026-07-28 transport:
`-32601` (method not found) → 404; the protocol validation errors — `-32020`
HeaderMismatch, `-32021` MissingRequiredClientCapability, `-32022`
UnsupportedProtocolVersion — → 400; everything else (results and application-level
errors) → 200.

# Arguments
- `payload::String`: The serialized JSON-RPC response

# Returns
- `Int`: The HTTP status code to use
"""
function modern_error_http_status(payload::String)::Int
    # Every mappable error response is a small validation/dispatch error body; skip
    # the sniff-and-parse entirely for large payloads (big tool results would
    # otherwise pay a second full parse whenever they contain the string "error")
    ncodeunits(payload) > 4096 && return 200
    contains(payload, "\"error\"") || return 200
    code = try
        msg = JSON3.read(payload)
        haskey(msg, "error") ? Int(msg.error.code) : nothing
    catch
        nothing
    end
    code == -32601 && return 404
    code in (-32020, -32021, -32022) && return 400
    return 200
end

"""
    handle_request(transport::HttpTransport, stream::HTTP.Stream)

Handle incoming HTTP requests following the Streamable HTTP specification.
Returns a single JSON response per request.

# Arguments
- `transport::HttpTransport`: The transport instance
- `stream::HTTP.Stream`: The HTTP stream

# Returns
- `Nothing`
"""
function handle_request(transport::HttpTransport, stream::HTTP.Stream)
    request = stream.message
    method = HTTP.method(request)
    target = request.target
    path = HTTP.URI(target).path

    # OAuth Resource Server: serve Protected Resource Metadata discovery (RFC 9728).
    # Public endpoint — intentionally reachable without authentication.
    if method == "GET" && path == WELL_KNOWN_PATH
        if !isnothing(transport.resource_metadata)
            status, body, headers = handle_well_known_request(transport.resource_metadata)
            HTTP.setstatus(stream, status)
            for (k, v) in headers
                HTTP.setheader(stream, k => v)
            end
            HTTP.setheader(stream, "Content-Length" => string(length(body)))
            HTTP.startwrite(stream)
            write(stream, body)
        else
            HTTP.setstatus(stream, 404)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            HTTP.setheader(stream, "Content-Length" => "9")
            HTTP.startwrite(stream)
            write(stream, "Not Found")
        end
        return nothing
    end

    # Handle both POST and GET requests to our endpoint
    if path != transport.endpoint
        HTTP.setstatus(stream, 404)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        write(stream, "Not Found")
        return nothing
    end

    # DNS-rebinding guard: a loopback-bound server without ENABLED bearer auth is
    # exactly the target of browser-driven rebinding attacks, so Host/Origin must look
    # local (or be explicitly allowlisted via allowed_hosts/allowed_origins).
    # Auth-enabled servers are already protected — a browser cannot attach the bearer
    # token — and commonly sit behind a reverse proxy that forwards a public Host, so
    # the guard stays out of their way. is_auth_enabled (not `auth === nothing`)
    # matters: disable_auth() installs a middleware that accepts everyone anonymously,
    # which provides no rebinding protection at all.
    if !is_auth_enabled(transport) && is_loopback_host(transport.host)
        host_values = [v for (k, v) in HTTP.headers(request) if lowercase(k) == "host"]
        origin_values = [v for (k, v) in HTTP.headers(request) if lowercase(k) == "origin"]
        violation = if length(host_values) > 1 || length(origin_values) > 1
            # Duplicate authority headers are a smuggling vector: different components
            # may honor different copies, so reject outright
            "duplicate Host/Origin headers"
        else
            rebinding_violation(
                isempty(host_values) ? "" : String(host_values[1]),
                isempty(origin_values) ? "" : String(origin_values[1]),
                transport.allowed_hosts,
                transport.allowed_origins
            )
        end
        if !isnothing(violation)
            @debug "Rejected potential DNS-rebinding request" violation=violation
            HTTP.setstatus(stream, 403)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            error_msg = "Forbidden: $violation"
            HTTP.setheader(stream, "Content-Length" => string(length(error_msg)))
            HTTP.startwrite(stream)
            write(stream, error_msg)
            return nothing
        end
    end

    # OAuth Resource Server: require a valid bearer token when auth is configured.
    # Applies to every request to the MCP endpoint (POST and SSE GET); the
    # well-known discovery endpoint above is exempt so clients can bootstrap.
    # The validated user travels with the request via QueuedHttpRequest (below),
    # not via shared transport state, so concurrent requests can't clobber it.
    authenticated_user = nothing
    if !isnothing(transport.auth)
        auth_header_raw = HTTP.header(request, "Authorization", "")
        auth_header = isempty(auth_header_raw) ? nothing : String(auth_header_raw)
        auth_result = authenticate_request(transport.auth, auth_header)
        if !auth_result.success
            resource_metadata_url = if !isnothing(transport.resource_metadata)
                "$(transport.resource_metadata.resource)/.well-known/oauth-protected-resource"
            else
                nothing
            end
            status, body, headers = auth_error_response(
                auth_result.error_code,
                auth_result.error;
                resource_metadata_url=resource_metadata_url
            )
            HTTP.setstatus(stream, status)
            for (k, v) in headers
                HTTP.setheader(stream, k => v)
            end
            HTTP.setheader(stream, "Content-Length" => string(length(body)))
            HTTP.startwrite(stream)
            write(stream, body)
            return nothing
        end
        authenticated_user = auth_result.user
    end

    # Handle GET requests for SSE notification stream
    if method == "GET"
        # The modern era removed the GET endpoint: a GET declaring a modern
        # MCP-Protocol-Version gets 405, never the legacy SSE stream or health body
        get_version = strip(HTTP.header(request, "MCP-Protocol-Version", ""))
        if get_version in MODERN_PROTOCOL_VERSIONS
            HTTP.setstatus(stream, 405)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            error_msg = "Method Not Allowed"
            HTTP.setheader(stream, "Content-Length" => string(ncodeunits(error_msg)))
            HTTP.startwrite(stream)
            write(stream, error_msg)
            return nothing
        end
        accept_header = HTTP.header(request, "Accept", "")
        if contains(accept_header, "text/event-stream")
            # Generate unique stream ID
            stream_id = string(uuid4())

            # Handle SSE stream
            handle_sse_stream(transport, stream, stream_id)
        else
            # Return health check response for plain GET requests (no Accept:
            # text/event-stream); allows clients like Claude Code to health-check.
            # The session ID is deliberately NOT included — it authenticates the
            # legacy session and must not be readable by an unauthenticated GET.
            HTTP.setstatus(stream, 200)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            health_response = JSON3.write(Dict(
                "status" => "ok",
                "protocol_version" => transport.protocol_version
            ))
            HTTP.setheader(stream, "Content-Length" => string(ncodeunits(health_response)))
            HTTP.startwrite(stream)
            write(stream, health_response)
        end
        return nothing
    end
    
    # Handle POST requests
    if method != "POST"
        HTTP.setstatus(stream, 405)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        error_msg = "Method Not Allowed"
        HTTP.setheader(stream, "Content-Length" => string(length(error_msg)))
        HTTP.startwrite(stream)
        write(stream, error_msg)
        return nothing
    end
    
    # MCP-Protocol-Version header check
    # Per spec: version negotiation happens at the JSON-RPC level (initialize request/response).
    # The header is for subsequent requests after negotiation. Any version in our supported
    # set is accepted; we only log when the client sends a version we don't recognize. The
    # JSON-RPC layer handles version negotiation properly.
    client_protocol_version = HTTP.header(request, "MCP-Protocol-Version", "")
    if !isempty(client_protocol_version) && !is_supported_version(client_protocol_version)
        @debug "Client requested unsupported protocol version" client=client_protocol_version supported=SUPPORTED_PROTOCOL_VERSIONS
    end
    
    # Security: Validate Origin header if configured
    if !isempty(transport.allowed_origins)
        origin = HTTP.header(request, "Origin", "")
        if !isempty(origin) && !(origin in transport.allowed_origins)
            @debug "Rejected request from unauthorized origin" origin=origin
            HTTP.setstatus(stream, 403)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            error_msg = "Forbidden: Invalid Origin"
            HTTP.setheader(stream, "Content-Length" => string(length(error_msg)))
            HTTP.startwrite(stream)  # Ensure headers are sent
            write(stream, error_msg)
            return nothing
        end
    end
    
    # Check Content-Type first
    content_type = HTTP.header(request, "Content-Type", "")
    if !startswith(content_type, "application/json")
        HTTP.setstatus(stream, 415)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        error_msg = "Unsupported Media Type"
        HTTP.setheader(stream, "Content-Length" => string(length(error_msg)))
        HTTP.startwrite(stream)
        write(stream, error_msg)
        return nothing
    end
    
    # Check Accept header per 2025-06-18 spec - SHOULD include both application/json and text/event-stream
    # Made lenient to support clients like Claude Code that may not send correct Accept headers.
    # Repeated Accept fields are combined (RFC 9110: equivalent to comma-joined) —
    # HTTP.header would return only the first instance.
    accept_header = join((String(v) for (k, v) in HTTP.headers(request)
                          if lowercase(String(k)) == "accept"), ",")
    if !contains(accept_header, "application/json") || !contains(accept_header, "text/event-stream")
        @debug "Client Accept header doesn't meet spec requirements" accept=accept_header expected="application/json, text/event-stream"
        # Continue anyway - the spec requirement is relaxed for compatibility
    end
    
    # Check for session ID header
    session_id = HTTP.header(request, "Mcp-Session-Id", "")
    
    try
        # Read request body
        body = String(read(stream))
        
        # Classify the message per JSON-RPC shape: a request has method+id, a
        # notification has method but no id, a client RESPONSE has result/error+id
        # but no method, and anything else (e.g. `{}`) is invalid. "No id" alone is
        # NOT a notification — that misclassifies responses as requests (which would
        # strand the connection waiting for a reply the loop never sends) and accepts
        # invalid objects with 202. Non-object JSON (arrays, scalars) keeps
        # parsed_msg == nothing and falls through to the request path, where the
        # server loop produces the JSON-RPC batch/parse rejection.
        local is_initialize = false
        local is_notification = false
        local is_client_response = false
        local is_invalid = false
        local is_modern = false
        local modern_version::Union{String,Nothing} = nothing
        local parsed_msg = nothing
        try
            msg = JSON3.read(body)
            if msg isa JSON3.Object
                parsed_msg = msg
                has_method = haskey(msg, "method")
                has_id = haskey(msg, "id")
                is_initialize = has_method && get(msg, "method", "") == "initialize"
                is_notification = has_method && !has_id
                is_client_response = !has_method && has_id &&
                                     (haskey(msg, "result") || haskey(msg, "error"))
                is_invalid = !has_method && !is_client_response
                # Modern-era (2026-07-28+) requests are stateless: protocol-level
                # sessions do not exist for them, so session validation must not apply
                if has_method && haskey(msg, "params") && msg.params isa JSON3.Object &&
                   haskey(msg.params, "_meta") && msg.params._meta isa JSON3.Object
                    v = get(msg.params._meta, Symbol(META_PROTOCOL_VERSION), nothing)
                    if v isa AbstractString
                        is_modern = true
                        modern_version = String(v)
                    end
                end
            end
        catch
            # Unparseable JSON: fall through to the request path, where the server
            # loop produces the JSON-RPC parse-error response
        end

        # Era can also be CLAIMED by the headers alone: a request whose
        # MCP-Protocol-Version header names a modern version must pass modern
        # validation even when its body carries no modern _meta — otherwise a
        # gateway routing on the headers and a backend executing the legacy body
        # see two different requests, which is exactly the attack the mirrored
        # headers exist to prevent.
        header_claims_modern = any(strip(String(v)) in MODERN_PROTOCOL_VERSIONS
                                   for (k, v) in HTTP.headers(request)
                                   if lowercase(String(k)) == "mcp-protocol-version")
        claims_modern = is_modern || header_claims_modern

        if is_invalid
            HTTP.setstatus(stream, 400)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            error_response = JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "error" => Dict(
                    "code" => -32600,
                    "message" => "Invalid Request: not a JSON-RPC request, notification, or response"
                ),
                "id" => nothing
            ))
            HTTP.setheader(stream, "Content-Length" => string(ncodeunits(error_response)))
            HTTP.startwrite(stream)
            write(stream, error_response)
            return nothing
        end

        if is_client_response
            # Per Streamable HTTP the server MUST return 202 for responses. This
            # server sends no server-to-client requests on this transport, so there
            # is nothing to correlate — acknowledge and drop.
            @debug "Received client JSON-RPC response; acknowledging with 202"
            HTTP.setstatus(stream, 202)
            HTTP.setheader(stream, "Content-Length" => "0")
            HTTP.startwrite(stream)
            return nothing
        end

        # Modern-era transport validation (SEP-2243/SEP-2575), before session logic
        # and before the request is queued: standard headers must mirror the body
        # (-32020 HeaderMismatch), the version must be supported (-32022), and
        # clientCapabilities must be present (-32602) — each with HTTP 400 per the
        # modern transport. Header-mismatch is checked FIRST. Notification POSTs are
        # excluded (the revision defines no header requirements for them). The
        # version echoed back is ALLOWLISTED — body strings never reach a response
        # header, which would otherwise be a header-injection vector.
        is_discover = parsed_msg !== nothing && get(parsed_msg, "method", "") == "server/discover"
        if (claims_modern || is_discover) && !is_notification && parsed_msg !== nothing
            req_id = get(parsed_msg, "id", nothing)
            failure = nothing  # (code, message, data)
            if !is_modern
                # The headers claim a modern era (or the method is modern-only) but
                # the body carries no modern _meta protocol version: the request IS
                # modern, and its required field is missing -> -32602. (-32020 is
                # reserved for header/body values that DISAGREE; either way the
                # request is rejected with 400 before reaching legacy handling.)
                failure = (ErrorCodes.INVALID_PARAMS,
                           "Missing required _meta field: $(META_PROTOCOL_VERSION)", nothing)
            else
                violation = modern_header_violation(request, parsed_msg, modern_version)
                if violation !== nothing
                    failure = (ErrorCodes.HEADER_MISMATCH, "Header mismatch: $violation", nothing)
                elseif !(modern_version in MODERN_PROTOCOL_VERSIONS)
                    failure = (ErrorCodes.UNSUPPORTED_PROTOCOL_VERSION, "Unsupported protocol version",
                               Dict{String,Any}(
                                   "supported" => vcat(MODERN_PROTOCOL_VERSIONS, SUPPORTED_PROTOCOL_VERSIONS),
                                   "requested" => modern_version))
                elseif !(get(parsed_msg.params._meta, Symbol(META_CLIENT_CAPABILITIES), nothing) isa JSON3.Object)
                    failure = (ErrorCodes.INVALID_PARAMS,
                               "Missing required _meta field: $(META_CLIENT_CAPABILITIES)", nothing)
                end
            end
            if failure !== nothing
                code, message, data = failure
                err = Dict{String,Any}("code" => code, "message" => message)
                data === nothing || (err["data"] = data)
                error_response = JSON3.write(Dict{String,Any}(
                    "jsonrpc" => "2.0",
                    "error" => err,
                    "id" => req_id
                ))
                HTTP.setstatus(stream, 400)
                HTTP.setheader(stream, "Content-Type" => "application/json")
                (modern_version !== nothing && modern_version in MODERN_PROTOCOL_VERSIONS) &&
                    HTTP.setheader(stream, "MCP-Protocol-Version" => modern_version)
                HTTP.setheader(stream, "Content-Length" => string(ncodeunits(error_response)))
                HTTP.startwrite(stream)
                write(stream, error_response)
                return nothing
            end
        end

        # subscriptions/listen opens a long-lived SSE response stream; a client
        # whose Accept excludes text/event-stream could never read one, and its
        # request-scoped notifications are dropped by design — the subscription
        # would be a black hole. Reject up front, BEFORE the request registers a
        # response route.
        if parsed_msg !== nothing && get(parsed_msg, "method", "") == "subscriptions/listen" &&
           !is_notification && !accepts_sse(accept_header)
            error_response = JSON3.write(Dict{String,Any}(
                "jsonrpc" => "2.0",
                "error" => Dict{String,Any}(
                    "code" => ErrorCodes.INVALID_REQUEST,
                    "message" => "subscriptions/listen requires an Accept header including text/event-stream"
                ),
                "id" => get(parsed_msg, "id", nothing)
            ))
            HTTP.setstatus(stream, 400)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            (modern_version !== nothing && modern_version in MODERN_PROTOCOL_VERSIONS) &&
                HTTP.setheader(stream, "MCP-Protocol-Version" => modern_version)
            HTTP.setheader(stream, "Content-Length" => string(ncodeunits(error_response)))
            HTTP.startwrite(stream)
            write(stream, error_response)
            return nothing
        end

        # Session validation - only check after we know if it's initialization.
        # Modern-era requests are exempt: the modern transport removed protocol
        # sessions, so a stateless request without a legacy session ID must not be
        # rejected (and never mints one). server/discover is modern-only, so it is
        # exempt too.
        if !is_initialize && !is_modern && !is_discover
            # After initialization, session may be required
            if transport.session_required && !isnothing(transport.session_id) && isempty(session_id)
                @debug "Missing required session ID"
                HTTP.setstatus(stream, 400)  # 400 Bad Request per spec
                HTTP.setheader(stream, "Content-Type" => "application/json")
                error_response = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "error" => Dict(
                        "code" => -32000,
                        "message" => "Session ID required"
                    ),
                    "id" => nothing
                ))
                write(stream, error_response)
                return nothing
            end

            # Validate provided session ID
            if !isempty(session_id) && !isnothing(transport.session_id) && session_id != transport.session_id
                @debug "Invalid session ID" provided=session_id expected=transport.session_id
                HTTP.setstatus(stream, 401)  # 401 Unauthorized for invalid authentication
                HTTP.setheader(stream, "Content-Type" => "application/json")
                error_response = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "error" => Dict(
                        "code" => -32000,
                        "message" => "Invalid session"
                    ),
                    "id" => nothing
                ))
                write(stream, error_response)
                return nothing
            end
        end

        # Generate session ID on initialization if not exists. Modern-era requests
        # never mint sessions (the modern transport removed them).
        if is_initialize && !is_modern && isnothing(transport.session_id)
            transport.session_id = generate_session_id()
            @debug "Generated session ID" session_id=transport.session_id
            # Don't automatically require session - let server config decide
        end

        # For notifications, return 202 Accepted immediately. A modern-marked
        # notification is acknowledged WITHOUT the legacy session/version headers
        # and WITHOUT entering the legacy processing path: the modern core defines
        # no client-to-server notifications on this transport (cancellation is
        # closing the response stream), so there is nothing to process.
        if is_notification
            HTTP.setstatus(stream, 202)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            if claims_modern
                (modern_version !== nothing && modern_version in MODERN_PROTOCOL_VERSIONS) &&
                    HTTP.setheader(stream, "MCP-Protocol-Version" => modern_version)
            else
                HTTP.setheader(stream, "MCP-Protocol-Version" => transport.protocol_version)
                if !isnothing(transport.session_id)
                    HTTP.setheader(stream, "Mcp-Session-Id" => transport.session_id)
                end
            end
            HTTP.setheader(stream, "Content-Length" => "0")
            # No body for 202 Accepted per spec
            HTTP.startwrite(stream)  # Ensure headers are sent

            # Queue legacy notifications for processing; drop modern-marked ones
            if !claims_modern
                put!(transport.request_queue, QueuedHttpRequest("notification-" * string(uuid4()), body, authenticated_user))
            else
                @debug "Dropping modern-marked notification (no client notifications in the modern era)"
            end
            return nothing
        end

        # Generate unique request ID
        request_id = string(uuid4())
        
        # Create the response route for this request. The channel carries any
        # request-scoped notifications (progress, log messages) followed by exactly
        # one final (:response, ...) entry. Unbounded: producers include the single
        # server loop, which must NEVER block on a slow client's half-read SSE
        # response — buffering is bounded by the request's own lifetime.
        # Registration is gated on `connected` UNDER the lock so it cannot race
        # shutdown (a channel registered after close()'s snapshot would never be
        # closed and would strand this handler in take! forever).
        response_channel = Channel{Tuple{Symbol,String}}(Inf)
        registered = lock(transport.channels_lock) do
            transport.connected || return false
            transport.response_channels[request_id] = response_channel
            transport.active_streams[request_id] = stream
            true
        end
        if !registered
            HTTP.setstatus(stream, 503)
            HTTP.setheader(stream, "Content-Type" => "text/plain")
            error_msg = "Service Unavailable: server shutting down"
            HTTP.setheader(stream, "Content-Length" => string(length(error_msg)))
            HTTP.startwrite(stream)
            write(stream, error_msg)
            return nothing
        end

        # Queue the request for processing
        put!(transport.request_queue, QueuedHttpRequest(request_id, body, authenticated_user))

        # Deliver the response. Per Streamable HTTP, a request's response is either a
        # single JSON object or an SSE stream scoped to this request carrying
        # request-related notifications followed by the final response. The first item
        # on the channel decides which shape we use: a quiet request stays plain JSON,
        # a notification arriving first upgrades the response to SSE.
        try
            kind, payload = take!(response_channel)
            client_accepts_sse = accepts_sse(accept_header)  # combined Accept from above

            if kind === :notification && !client_accepts_sse
                # Client can't consume an SSE response; drop request-scoped
                # notifications and answer with the bare JSON response.
                while kind !== :response
                    @debug "Dropping request-scoped notification (client Accept lacks text/event-stream)"
                    kind, payload = take!(response_channel)
                end
            end

            if kind === :response
                # Plain JSON response. Modern responses map protocol errors to HTTP
                # statuses (404 for -32601, 400 for -32020/-32021/-32022), echo the
                # request's own protocol version, and never carry a session header
                # (the modern transport removed protocol sessions).
                HTTP.setstatus(stream, is_modern ? modern_error_http_status(payload) : 200)
                HTTP.setheader(stream, "Content-Type" => "application/json")
                HTTP.setheader(stream, "Cache-Control" => "no-cache")
                if is_modern
                    HTTP.setheader(stream, "MCP-Protocol-Version" => something(modern_version, transport.protocol_version))
                else
                    HTTP.setheader(stream, "MCP-Protocol-Version" => transport.protocol_version)
                    if !isnothing(transport.session_id)
                        HTTP.setheader(stream, "Mcp-Session-Id" => transport.session_id)
                    end
                end
                write(stream, payload)
            else
                # SSE response stream scoped to this request
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type" => "text/event-stream")
                HTTP.setheader(stream, "Cache-Control" => "no-cache")
                HTTP.setheader(stream, "X-Accel-Buffering" => "no")
                if is_modern
                    HTTP.setheader(stream, "MCP-Protocol-Version" => something(modern_version, transport.protocol_version))
                else
                    HTTP.setheader(stream, "MCP-Protocol-Version" => transport.protocol_version)
                    if !isnothing(transport.session_id)
                        HTTP.setheader(stream, "Mcp-Session-Id" => transport.session_id)
                    end
                end
                HTTP.startwrite(stream)
                last_write = time()
                while true
                    transport.event_counter += 1
                    write(stream, format_sse_event(payload, event="message", id=transport.event_counter))
                    Base.flush(stream)  # NOT bare flush: that resolves to this package's flush(::Transport)
                    last_write = time()
                    kind === :response && break
                    # Wait for the next item by POLLING, not a blocking take!: a
                    # subscriptions/listen stream can idle indefinitely. isready is
                    # checked before isopen so items already buffered on a closed
                    # channel still drain (graceful shutdown results), and
                    # isready-then-take! cannot race: this handler is the channel's
                    # only consumer. isopen(stream) alone CANNOT see a peer that
                    # vanished while idle (a FIN/RST is only observed on I/O), so
                    # the loop also writes a periodic SSE comment as a keepalive —
                    # invisible to event parsers, but the write is what surfaces a
                    # dead socket, bounding a dead stream's lifetime to about two
                    # keepalive intervals.
                    got_next = false
                    while isopen(stream)
                        if isready(response_channel)
                            kind, payload = take!(response_channel)
                            got_next = true
                            break
                        end
                        isopen(response_channel) || break
                        if time() - last_write >= transport.sse_keepalive_secs
                            write(stream, ": keepalive\n\n")
                            Base.flush(stream)
                            last_write = time()
                        end
                        sleep(0.05)
                    end
                    got_next || break
                end
            end

        catch e
            if !(e isa InvalidStateException)
                @debug "Error waiting for response" error=e
                # nwritten starts at -1 and startwrite() sets it to 0, so this is
                # HTTP.jl's own "response not started yet" signal (there is no
                # public predicate for it) — only then is a 500 body still legal
                if stream.nwritten < 0
                    HTTP.setstatus(stream, 500)
                    HTTP.setheader(stream, "Content-Type" => "application/json")
                    error_response = JSON3.write(Dict(
                        "jsonrpc" => "2.0",
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Internal error"
                        ),
                        "id" => nothing
                    ))
                    write(stream, error_response)
                end
            end
        finally
            # Cleanup
            lock(transport.channels_lock) do
                delete!(transport.active_streams, request_id)
                delete!(transport.response_channels, request_id)
            end
            Base.close(response_channel)
        end
        
    catch e
        # A client that disconnects mid-request surfaces as EOFError (read) or IOError
        # (broken pipe on write) — benign connection teardown, not a server fault. Log it
        # at debug and do not attempt to write a 500 to an already-closed stream.
        if e isa EOFError || e isa Base.IOError
            @debug "Client disconnected while handling request" error=e
        else
            @error "Error handling request" error=e
            if stream.nwritten < 0  # response not started (see comment above)
                HTTP.setstatus(stream, 500)
                HTTP.setheader(stream, "Content-Type" => "application/json")
                error_response = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "error" => Dict(
                        "code" => -32603,
                        "message" => "Internal error: $(e)"
                    ),
                    "id" => nothing
                ))
                write(stream, error_response)
            end
        end
    end
    
    nothing
end

"""
    connect(transport::HttpTransport) -> Nothing

Start the HTTP server and begin listening for connections.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Nothing`

# Throws
- `TransportError`: If the server cannot be started
"""
function connect(transport::HttpTransport)
    if transport.connected
        return nothing
    end
    
    # Set connected before starting to avoid race condition
    transport.connected = true
    
    # Start server
    try
        @info "Starting HTTP server" host=transport.host port=transport.port endpoint=transport.endpoint
        
        # Start server in background (serve! returns immediately)
        transport.server = HTTP.serve!(transport.host, transport.port; stream=true) do stream
            handle_request(transport, stream)
        end
    catch e
        @error "Failed to start HTTP server" error=e
        transport.connected = false
        rethrow(e)
    end
    
    # Wait a moment for server to start
    sleep(0.5)
    
    @info "HTTP server started" url="http://$(transport.host):$(transport.port)$(transport.endpoint)"
    nothing
end

"""
    close(transport::HttpTransport) -> Nothing

Stop the HTTP server and close all connections.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Nothing`
"""
function close(transport::HttpTransport)::Nothing
    # Flip `connected` and snapshot the response channels under the SAME lock that
    # gates channel registration: a connection handler either registered before the
    # snapshot (and its channel gets closed below) or observes connected == false and
    # answers 503 — no channel can slip in after the snapshot and strand its handler
    # in take! forever.
    channels = lock(transport.channels_lock) do
        if !transport.connected
            nothing
        else
            transport.connected = false
            collect(values(transport.response_channels))
        end
    end
    channels === nothing && return nothing

    for channel in channels
        try
            Base.close(channel)
        catch
            # Channel might be closed already
        end
    end

    # Close request queue and the out-of-band notification queue (unblocks any
    # GET SSE writer waiting on it)
    Base.close(transport.request_queue)
    Base.close(transport.notification_queue)
    
    # Stop server
    if !isnothing(transport.server)
        try
            HTTP.close(transport.server)
        catch e
            @debug "Error closing HTTP server" error=e
        end
        transport.server = nothing
    end
    
    @info "HTTP server stopped"
    nothing
end

"""
    is_connected(transport::HttpTransport) -> Bool

Check if the HTTP server is running and accepting connections.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Bool`: true if connected, false otherwise
"""
function is_connected(transport::HttpTransport)::Bool
    transport.connected
end

"""
    read_message(transport::HttpTransport) -> Union{String,Nothing}

Read a message from the request queue. Waits a BOUNDED interval and returns
`nothing` when no request arrives, so the server loop regularly re-checks its run
condition: `stop!` must be able to end the loop while the transport is still open
(graceful `subscriptions/listen` closure delivers on the open transport, then the
transport is closed) — a blocking `take!` would pin the loop until the next request.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Union{String,Nothing}`: The message string, or nothing when no request arrived
  (or the transport disconnected)
"""
function read_message(transport::HttpTransport)::Union{String,Nothing}
    if !transport.connected
        return nothing
    end

    deadline = time() + 0.2
    while time() < deadline
        if isready(transport.request_queue)
            # The server loop is the queue's only consumer, so isready-then-take!
            # cannot race another taker.
            env = take!(transport.request_queue)

            # Store the current request ID for response correlation, and the
            # per-request authenticated user (consumed by the single server loop via
            # pending_auth_context before the next read — never shared across connections).
            transport.current_request_id = env.id
            transport.current_request_auth = env.user

            return env.body
        end
        if !isopen(transport.request_queue)
            # Queue closed and drained: transport is shutting down
            transport.connected = false
            return nothing
        end
        sleep(0.01)
    end
    nothing
end

"""
    write_message(transport::HttpTransport, message::String) -> Nothing

Write a message to the current request's response channel.
The request handler will send this as the HTTP response.

# Arguments
- `transport::HttpTransport`: The transport instance
- `message::String`: The message to send

# Returns
- `Nothing`
"""
function write_message(transport::HttpTransport, message::String)::Nothing
    if !transport.connected
        return nothing
    end
    
    # Get the current request ID
    if isdefined(transport, :current_request_id) && !isnothing(transport.current_request_id)
        request_id = transport.current_request_id

        # Send message to the response channel (look up under the lock, put! outside)
        channel = lock(transport.channels_lock) do
            get(transport.response_channels, request_id, nothing)
        end
        if channel !== nothing
            try
                put!(channel, (:response, message))
                # Clear current request ID after sending response
                transport.current_request_id = nothing
            catch e
                @debug "Failed to write message" error=e
            end
        end
    else
        @debug "No active request to write response to"
    end

    nothing
end

"""
    notification_route(transport::HttpTransport) -> Union{String,Nothing}

Return the HTTP request ID of the message just read from the queue, used by the
server loop as the request-scoped notification route (see the base
`notification_route` docstring).
"""
notification_route(transport::HttpTransport) = transport.current_request_id

"""
    capture_response_route(transport::HttpTransport) -> Union{String,Nothing}

Detach the current request's response route so its response can be delivered later
from a background task (see `deliver_response`). Clears `current_request_id` so the
loop's subsequent `write_message` calls cannot route into this request's channel.
"""
function capture_response_route(transport::HttpTransport)::Union{String,Nothing}
    route = transport.current_request_id
    transport.current_request_id = nothing
    route
end

"""
    deliver_response(transport::HttpTransport, route::Union{String,Nothing}, message::String) -> Nothing

Deliver a deferred response to the request identified by `route` (captured earlier via
`capture_response_route`). The HTTP connection handler is still blocked on the
request's response channel, so the POST stays open until this delivers — which is
exactly the blocking behavior `tasks/result` requires. Dropped silently when the
client has disconnected (its channel is gone or closed).
"""
function deliver_response(transport::HttpTransport, route::Union{String,Nothing},
                          message::String)::Nothing
    route === nothing && return nothing
    channel = lock(transport.channels_lock) do
        get(transport.response_channels, route, nothing)
    end
    channel === nothing && return nothing
    try
        put!(channel, (:response, message))
    catch e
        @debug "Failed to deliver deferred response (client likely disconnected)" error=e
    end
    nothing
end

"""
    deliver_notification(transport::HttpTransport, route, message::String) -> Bool

Push a notification onto the response stream of the request identified by `route`
(captured via `capture_response_route`) — the delivery path for
`subscriptions/listen` streams. Returns `false` when that route is gone (client
disconnected), so the caller can prune the subscription.

A listen stream lives arbitrarily long, so — unlike ordinary request channels,
whose buffering is bounded by the request's own lifetime — its backlog must be
capped: a reader that stopped draining would otherwise accumulate every
notification forever. At `LISTEN_BACKLOG_CAP` pending items the stream is
load-shed: its channel is closed (which ends the connection handler after it
drains what is already buffered) and delivery is reported failed so the caller
prunes the subscription.
"""
function deliver_notification(transport::HttpTransport, route, message::String)::Bool
    route === nothing && return false
    channel = lock(transport.channels_lock) do
        get(transport.response_channels, route, nothing)
    end
    channel === nothing && return false
    if Base.n_avail(channel) >= LISTEN_BACKLOG_CAP
        @debug "subscriptions/listen backlog cap reached; load-shedding stream" route
        Base.close(channel)
        return false
    end
    try
        put!(channel, (:notification, message))
        return true
    catch e
        @debug "Subscription route closed" error=e
        return false
    end
end

"""
    deliver_log_notification(transport::HttpTransport, route, message::String) -> Bool

Push a request-scoped log notification onto the request's response stream. Unlike
`deliver_notification`, backlog pressure NEVER closes the channel — the request's
final response still has to travel it, and load-shedding it away because a stalled
client let log records pile up would destroy the response. Past the cap the record
is simply dropped (`false`), sending it to the logger's fallback stream instead.
"""
function deliver_log_notification(transport::HttpTransport, route, message::String)::Bool
    route === nothing && return false
    channel = lock(transport.channels_lock) do
        get(transport.response_channels, route, nothing)
    end
    channel === nothing && return false
    if Base.n_avail(channel) >= NOTIFICATION_QUEUE_SOFTCAP
        @debug "Request log backlog full; dropping log notification" route
        return false
    end
    try
        put!(channel, (:notification, message))
        return true
    catch e
        @debug "Request route closed" error=e
        return false
    end
end

"""
    route_alive(transport::HttpTransport, route) -> Bool

Whether a captured response route still has a live consumer: its channel is still
registered and open. The connection handler unregisters and closes the channel when
its client disconnects (or its stream is load-shed), so a dead route shows up here
without anything being written to it.
"""
function route_alive(transport::HttpTransport, route)::Bool
    route === nothing && return false
    channel = lock(transport.channels_lock) do
        get(transport.response_channels, route, nothing)
    end
    channel !== nothing && isopen(channel)
end


"""
    set_negotiated_version!(transport::HttpTransport, version::String) -> Nothing

Update the version advertised in `MCP-Protocol-Version` response headers (and accepted
in request headers) to the version negotiated during `initialize`, so per-request
headers echo what the initialize response returned.
"""
function set_negotiated_version!(transport::HttpTransport, version::String)
    transport.protocol_version = version
    nothing
end

"""
    send_notification(transport::HttpTransport, notification::String) -> Nothing

Send a notification. A notification emitted while the server loop is synchronously
handling a request (progress, log messages) is request-scoped: it is routed onto that
request's response channel and delivered on the POST's SSE response stream, per
Streamable HTTP. Anything else — notifications from background tasks (MCP Tasks
status updates) or emitted outside request handling — goes to the standalone GET SSE
notification stream.

The request route is read from the server loop's task-local storage (set in
`run_server_loop`), so background tasks — which never inherit it — can't misroute
their notifications into whatever request the loop happens to be processing.

# Arguments
- `transport::HttpTransport`: The transport instance
- `notification::String`: The notification message to send

# Returns
- `Nothing`
"""
function send_notification(transport::HttpTransport, notification::String)::Nothing
    if !transport.connected
        return nothing
    end

    # Request-scoped delivery: onto the active request's response channel
    route = get(task_local_storage(), :mcp_notification_route, nothing)
    if route !== nothing
        channel = lock(transport.channels_lock) do
            get(transport.response_channels, route, nothing)
        end
        if channel !== nothing
            try
                put!(channel, (:notification, notification))
                return nothing
            catch e
                @debug "Request route closed; falling back to GET stream" error=e
            end
        end
    end

    # Out-of-band delivery: the standalone GET SSE notification stream. The queue is
    # unbounded (put! must never block the single server loop — the GET consumer is
    # optional per spec and may simply not exist), so enforce a soft cap here by
    # dropping new notifications once too many are pending.
    try
        if Base.n_avail(transport.notification_queue) >= NOTIFICATION_QUEUE_SOFTCAP
            @debug "Notification queue full (no SSE consumer?); dropping notification"
            return nothing
        end
        put!(transport.notification_queue, notification)
    catch e
        @debug "Failed to queue notification" error=e
    end

    nothing
end

"""
    broadcast_to_sse(transport::HttpTransport, message::String; event::String="message") -> Nothing

Broadcast a message immediately to all SSE streams.

# Arguments
- `transport::HttpTransport`: The transport instance
- `message::String`: The message to broadcast
- `event::String`: The event type (default: "message")

# Returns
- `Nothing`
"""
function broadcast_to_sse(transport::HttpTransport, message::String; event::String="message")::Nothing
    if isempty(transport.sse_streams)
        return nothing
    end
    
    transport.event_counter += 1
    sse_event = format_sse_event(
        message,
        event=event,
        id=transport.event_counter
    )
    
    # Send to all SSE streams
    for (stream_id, stream) in transport.sse_streams
        try
            write(stream, sse_event)
            Base.flush(stream)
        catch e
            @debug "Failed to write to SSE stream" stream_id=stream_id error=e
            # Remove dead streams
            delete!(transport.sse_streams, stream_id)
        end
    end
    
    nothing
end

"""
    end_response(transport::HttpTransport) -> Nothing

Deprecated: No longer needed as HTTP transport now sends complete responses.
This method exists for backward compatibility but does nothing.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Nothing`
"""
function end_response(transport::HttpTransport)::Nothing
    # No-op: responses are now sent immediately in write_message
    nothing
end

# Pretty printing
function Base.show(io::IO, transport::HttpTransport)
    status = transport.connected ? "connected" : "disconnected"
    active = length(transport.active_streams)
    print(io, "HttpTransport(http://$(transport.host):$(transport.port)$(transport.endpoint), $status, $active active)")
end

"""
    pending_auth_context(transport::HttpTransport) -> Union{AuthenticatedUser,Nothing}

Return the authenticated user of the message most recently read from the queue (set
in `read_message`, consumed immediately by the single server loop). This is how the
per-request identity reaches `RequestContext.authenticated_user`; handlers should read
it from the request context, not from the transport.
"""
function pending_auth_context(transport::HttpTransport)::Union{AuthenticatedUser,Nothing}
    return transport.current_request_auth
end

"""
    is_auth_enabled(transport::HttpTransport) -> Bool

Return whether OAuth Resource Server token validation is enabled on this transport.

# Arguments
- `transport::HttpTransport`: The transport instance

# Returns
- `Bool`: true if an enabled `AuthMiddleware` is configured
"""
function is_auth_enabled(transport::HttpTransport)::Bool
    return !isnothing(transport.auth) && transport.auth.enabled
end
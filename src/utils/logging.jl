# src/utils/logging.jl

"""
    MCPLogger <: AbstractLogger

Define a custom logger for MCP server that formats messages according to protocol requirements.

Once a LEGACY session is initialized, log records are delivered to the client as MCP
`notifications/message` notifications via the server's transport (`send_notification`):
stdio writes them to stdout alongside responses; Streamable HTTP delivers them on the
originating request's SSE response stream (or the standalone notification stream when
no request is being handled). Before initialization — or if transport delivery fails —
records fall back to `stream` as JSON lines. Modern-era (2026-07-28+) requests never
deliver through these ambient gates: a request that opted in via
`io.modelcontextprotocol/logLevel` is served under a request-scoped
`ModernRequestLogger` wrapping this logger, and every other modern request keeps the
loop-armed suppression flag, so its records reach only the fallback stream.

# Fields
- `stream::IO`: Fallback output stream for log messages (used before the client
  initializes and when transport delivery is unavailable)
- `min_level::LogLevel`: Minimum logging level to display (mutable so `logging/setLevel`
  can adjust it on the installed logger)
- `message_limits::Dict{Any,Int}`: Message limit settings for rate limiting
- `transport::Any`: The server transport notifications are delivered over
  (`Union{Nothing,Transport}`; typed `Any` to avoid include-order coupling)
- `transport_active::Base.RefValue{Bool}`: Gate flipped on client initialization —
  notifications MUST NOT be emitted to a client that has not initialized
"""
mutable struct MCPLogger <: AbstractLogger
    stream::IO
    min_level::LogLevel
    message_limits::Dict{Any,Int}
    transport::Any
    transport_active::Base.RefValue{Bool}
end

# Back-compat: the pre-transport three-field positional shape still constructs
MCPLogger(stream::IO, level::LogLevel, limits::Dict{Any,Int}) =
    MCPLogger(stream, level, limits, nothing, Ref(false))

"""
    MCP_LOG_LEVELS

The log levels defined by the MCP spec (RFC 5424 severities), lowest to highest.
"""
const MCP_LOG_LEVELS = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]

"""
    mcp_level_to_julia(level::String) -> LogLevel

Map an MCP/RFC-5424 log level string to the closest Julia `LogLevel`.

# Arguments
- `level::String`: One of `MCP_LOG_LEVELS`

# Returns
- `LogLevel`: `Debug`, `Info`, `Warn`, or `Error` (the four Julia standard levels)
"""
function mcp_level_to_julia(level::String)::LogLevel
    level == "debug" && return Logging.Debug
    level in ("info", "notice") && return Logging.Info
    level == "warning" && return Logging.Warn
    return Logging.Error  # error, critical, alert, emergency
end

"""
    mcp_level_severity(level::String) -> Int

The RFC-5424 severity rank of an MCP log level (1 = debug, lowest … 8 = emergency,
highest), for at-or-above comparisons.

# Arguments
- `level::String`: One of `MCP_LOG_LEVELS`

# Returns
- `Int`: The 1-based rank within `MCP_LOG_LEVELS` (unrecognized levels rank highest,
  so they never widen delivery)
"""
function mcp_level_severity(level::String)::Int
    idx = findfirst(==(level), MCP_LOG_LEVELS)
    idx === nothing ? length(MCP_LOG_LEVELS) : idx
end

# HTTP.jl's internal connection-loop logging must not be relayed into the MCP
# notification stream: on every client disconnect HTTP.jl logs the `closeread`
# EOF at error level — transport-internal teardown noise, not an application log.
_http_internal_record(_module) =
    _module !== nothing && nameof(Base.moduleroot(_module)) === :HTTP

"""
    MCPLogger(stream::IO=stderr, level::LogLevel=Info) -> MCPLogger

Create a new MCPLogger instance with specified stream and level.

# Arguments
- `stream::IO=stderr`: The output stream where log messages will be written
- `level::LogLevel=Info`: The minimum logging level to display

# Returns
- `MCPLogger`: A new logger instance
"""
function MCPLogger(stream::IO=stderr, level::LogLevel=Info)
    MCPLogger(stream, level, Dict{Any,Int}())
end

function Logging.shouldlog(logger::MCPLogger, level, _module, group, id)
    level >= logger.min_level || return false
    # The package's own transport errors (logged from this module) pass; HTTP.jl
    # internals do not.
    return !_http_internal_record(_module)
end

Logging.min_enabled_level(logger::MCPLogger) = logger.min_level

Logging.catch_exceptions(logger::MCPLogger) = false

"""
    format_log_notification(level, message, _module, filepath, line; kwargs...) -> (String, String)

Build the wire form of a log record as an MCP `notifications/message`.

# Arguments
- `level`: The Julia `LogLevel` of the record
- `message`: The log message content
- `_module`: The module where the log was generated
- `filepath`: The source file path
- `line`: The source line number
- `kwargs...`: Additional context, stringified into the metadata

# Returns
- `Tuple{String,String}`: The MCP level name and the serialized JSON-RPC notification
"""
function format_log_notification(level, message, _module, filepath, line; kwargs...)
    mcp_level = if level >= Error
        "error"
    elseif level >= Warn
        "warning"
    elseif level >= Info
        "info"
    else
        "debug"
    end

    log_message = LittleDict{String,Any}(
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => LittleDict{String,Any}(
            "level" => mcp_level,
            "data" => LittleDict{String,Any}(
                "message" => string(message),
                "timestamp" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
                "metadata" => LittleDict{String,Any}(
                    "module" => string(_module),
                    "file" => string(filepath),
                    "line" => line
                )
            )
        )
    )
    if !isempty(kwargs)
        log_message["params"]["data"]["metadata"]["context"] = Dict(string(k) => string(v) for (k,v) in kwargs)
    end

    buf = IOBuffer()
    JSON3.write(buf, log_message)
    (mcp_level, String(take!(buf)))
end

"""
    Logging.handle_message(logger::MCPLogger, level, message, _module, group, id, filepath, line; kwargs...) -> Nothing

Format and output log messages according to the MCP protocol format.

# Arguments
- `logger::MCPLogger`: The MCP logger instance
- `level`: The log level of the message
- `message`: The log message content
- `_module`: The module where the log was generated
- `group`: The log group
- `id`: The log message ID
- `filepath`: The source file path
- `line`: The source line number
- `kwargs...`: Additional contextual information to include in the log

# Returns
- `Nothing`: Function writes to the logger stream but doesn't return a value
"""
function Logging.handle_message(logger::MCPLogger, level, message, _module, group, id,
                              filepath, line; kwargs...)
    # Reentrancy guard FIRST: everything below — string(message), string(v) on kwarg
    # values, JSON3.write, is_connected, the transport send — can invoke user-defined
    # show methods or transport code that logs, re-entering this function. A recursive
    # record gets a minimal fixed fallback line (still gated by the operator's level:
    # a record that would not have printed must not leave a marker either): no
    # formatting of user values, no transport delivery, so the recursion terminates
    # at depth one.
    if get(task_local_storage(), :mcp_logger_reentry, false)
        try
            level >= logger.min_level &&
                println(logger.stream, "{\"mcp_logger\":\"recursive log record suppressed\"}")
        catch
        end
        return nothing
    end
    task_local_storage(:mcp_logger_reentry, true)
    try

    _, serialized = format_log_notification(level, message, _module, filepath, line; kwargs...)

    # Deliver to the client as a notifications/message over the transport once the
    # LEGACY session is initialized (recursion from the send path is handled by the
    # entry guard above). Modern-era (2026-07-28+) requests never deliver through
    # this path: the loop arms the suppression flag per message, and a validated
    # per-request logLevel opt-in is served by a `ModernRequestLogger` scope (which
    # child tasks inherit) instead of this logger's ambient gates.
    t = logger.transport
    if t !== nothing && logger.transport_active[] && is_connected(t) &&
       !get(task_local_storage(), :mcp_suppress_log_notifications, false)
        try
            send_notification(t, serialized)
            return nothing
        catch
            # Transport delivery failed; fall through to the fallback stream
        end
    end

    # Fallback: write to the configured stream (stderr by default)
    println(logger.stream, serialized)
    Base.flush(logger.stream)

    finally
        task_local_storage(:mcp_logger_reentry, false)
    end
    nothing
end

"""
    ModernRequestLogger(inner::MCPLogger, transport, route,
                        level::Union{String,Nothing}) <: AbstractLogger

The logging scope of ONE modern-era (2026-07-28+) request. `handle_modern_request`
installs it around the serve path with `with_logger`, which is what makes every
guarantee task-inheritance-proof: child tasks a handler spawns inherit the logstate
(unlike task-local storage), so their records land here too, subject to the same
rules as the serving task's.

Semantics per SEP-2575: with a requested `level`, records at or above it (RFC-5424)
are delivered as `notifications/message` on the ORIGINATING request's response
stream — the `route` captured at construction, pushed via `deliver_notification`
on the `transport` the arming site verified — never on the standalone GET stream,
a `subscriptions/listen` stream, or another server's transport. Without a `level`
(the request did not opt in, or the server declares no logging capability), nothing
is ever delivered. Delivery ends when `closed` is set (the final response is on its
way) or the response channel is gone — late records are dropped, not diverted.
Undelivered records fall back to the operator's `inner.stream` under `inner`'s own
`min_level`, so a `debug` opt-in below the operator's level never spams stderr.

# Fields
- `inner::MCPLogger`: The server's installed logger (fallback stream + operator level)
- `transport::Any`: The serving transport (verified `=== inner.transport` at arming)
- `route::Any`: The request's captured notification route
- `level::Union{String,Nothing}`: The validated requested MCP level, or `nothing`
  for a wire-silent scope
- `closed::Base.RefValue{Bool}`: Set once the request's response is under way
"""
struct ModernRequestLogger <: AbstractLogger
    inner::MCPLogger
    transport::Any
    route::Any
    level::Union{String,Nothing}
    closed::Base.RefValue{Bool}
end

ModernRequestLogger(inner::MCPLogger, transport, route, level::Union{String,Nothing}) =
    ModernRequestLogger(inner, transport, route, level, Ref(false))

# A debug opt-in must generate records below the operator's installed level; the
# with_logger installation rebuilds Julia's cached LogState from this value.
function Logging.min_enabled_level(logger::ModernRequestLogger)
    logger.level === nothing ? logger.inner.min_level :
        min(logger.inner.min_level, mcp_level_to_julia(logger.level))
end

function Logging.shouldlog(logger::ModernRequestLogger, level, _module, group, id)
    level >= Logging.min_enabled_level(logger) || return false
    return !_http_internal_record(_module)
end

Logging.catch_exceptions(logger::ModernRequestLogger) = false

function Logging.handle_message(logger::ModernRequestLogger, level, message, _module,
                                group, id, filepath, line; kwargs...)
    # Same reentrancy termination as MCPLogger (delivery and formatting can log)
    if get(task_local_storage(), :mcp_logger_reentry, false)
        try
            level >= logger.inner.min_level &&
                println(logger.inner.stream, "{\"mcp_logger\":\"recursive log record suppressed\"}")
        catch
        end
        return nothing
    end
    task_local_storage(:mcp_logger_reentry, true)
    try

    mcp_level, serialized = format_log_notification(level, message, _module, filepath, line; kwargs...)

    if logger.level !== nothing && !logger.closed[] &&
       mcp_level_severity(mcp_level) >= mcp_level_severity(logger.level)
        try
            # deliver_notification returns false when the route is gone (client
            # disconnected / response already completed on HTTP) — drop to the
            # fallback stream, never divert to another stream
            deliver_notification(logger.transport, logger.route, serialized) && return nothing
        catch
        end
    end

    # Operator fallback under the INSTALLED level: records that exist only because
    # the opt-in lowered the effective enablement stay off the operator's stream
    if level >= logger.inner.min_level
        println(logger.inner.stream, serialized)
        Base.flush(logger.inner.stream)
    end

    finally
        task_local_storage(:mcp_logger_reentry, false)
    end
    nothing
end

"""
    init_logging(level::LogLevel=Info) -> Nothing

Initialize logging for the MCP server with a custom MCP-formatted logger.

# Arguments
- `level::LogLevel=Info`: The minimum logging level to display

# Returns
- `Nothing`: Function sets the global logger but doesn't return a value
"""
function init_logging(level::LogLevel=Info)
    logger = MCPLogger(stderr, level)
    global_logger(logger)
end

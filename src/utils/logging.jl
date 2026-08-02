# src/utils/logging.jl

"""
    MCPLogger <: AbstractLogger

Define a custom logger for MCP server that formats messages according to protocol requirements.

Once the server is initialized, log records are delivered to the client as MCP
`notifications/message` notifications via the server's transport (`send_notification`):
stdio writes them to stdout alongside responses; Streamable HTTP delivers them on the
originating request's SSE response stream (or the standalone notification stream when
no request is being handled). Before initialization — or if transport delivery fails —
records fall back to `stream` as JSON lines.

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

# The per-request log level (modern era, io.modelcontextprotocol/logLevel) is
# task-local: handle_modern_request sets it for the duration of one validated
# request on the serial loop task, and the loop clears it with the notification
# route. It lowers the logger's effective enablement so a debug-requesting client
# can receive records below the operator's min_level — handle_message filters
# delivery by MCP severity and keeps the fallback stream at min_level.
function effective_min_level(logger::MCPLogger)::LogLevel
    lvl = get(task_local_storage(), :mcp_request_log_level, nothing)
    lvl isa String ? min(logger.min_level, mcp_level_to_julia(lvl)) : logger.min_level
end

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
    level >= effective_min_level(logger) || return false
    # Do not relay HTTP.jl's internal connection-loop logging into the MCP notification
    # stream. On every client disconnect HTTP.jl logs the `closeread` EOF at error level
    # ("handle_connection handler error") — transport-internal teardown noise, not an MCP
    # application log. The package's own transport errors (logged from this module) pass.
    if _module !== nothing && nameof(Base.moduleroot(_module)) === :HTTP
        return false
    end
    return true
end

Logging.min_enabled_level(logger::MCPLogger) = effective_min_level(logger)

Logging.catch_exceptions(logger::MCPLogger) = false

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
    # record gets a minimal fixed fallback line: no formatting of user values, no
    # transport delivery, so the recursion terminates at depth one.
    if get(task_local_storage(), :mcp_logger_reentry, false)
        try
            println(logger.stream, "{\"mcp_logger\":\"recursive log record suppressed\"}")
        catch
        end
        return nothing
    end
    task_local_storage(:mcp_logger_reentry, true)
    try

    # Convert log level to MCP protocol level
    mcp_level = if level >= Error
        "error"
    elseif level >= Warn
        "warning"
    elseif level >= Info
        "info"
    else
        "debug"
    end
    
    # Create JSON-RPC formatted log message
    buf = IOBuffer()
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
    
    # Add any additional context from kwargs
    if !isempty(kwargs)
        log_message["params"]["data"]["metadata"]["context"] = Dict(string(k) => string(v) for (k,v) in kwargs)
    end
    
    # Write to buffer
    JSON3.write(buf, log_message)
    serialized = String(take!(buf))

    # Deliver to the client as a notifications/message over the transport once the
    # session is initialized (recursion from the send path is handled by the
    # entry guard above). Modern-era (2026-07-28+) request handling sets the
    # suppression flag: notifications/message MUST NOT be emitted for a request
    # that did not opt in via io.modelcontextprotocol/logLevel. When a request DID
    # opt in, the task-local per-request level filters delivery to records at or
    # above it (RFC-5424 severity), independent of the operator's min_level.
    request_level = get(task_local_storage(), :mcp_request_log_level, nothing)
    deliverable = !(request_level isa String) ||
                  mcp_level_severity(mcp_level) >= mcp_level_severity(request_level)
    # transport_active is the LEGACY never-before-initialize rule; the modern era
    # has no initialization, so a validated per-request opt-in (which also proved
    # the logger belongs to the serving transport before arming the task-local)
    # delivers on a connected transport regardless of it.
    active = logger.transport_active[] || request_level isa String
    t = logger.transport
    if deliverable && t !== nothing && active && is_connected(t) &&
       !get(task_local_storage(), :mcp_suppress_log_notifications, false)
        try
            send_notification(t, serialized)
            return nothing
        catch
            # Transport delivery failed; fall through to the fallback stream
        end
    end

    # Fallback: write to the configured stream (stderr by default). Records that
    # only exist because a per-request logLevel lowered the effective enablement
    # stay off the operator's stream — min_level still governs it.
    if level >= logger.min_level
        println(logger.stream, serialized)
        Base.flush(logger.stream)
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

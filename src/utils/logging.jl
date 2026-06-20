# src/utils/logging.jl

"""
    MCPLogger <: AbstractLogger

Define a custom logger for MCP server that formats messages according to protocol requirements.

# Fields
- `stream::IO`: The output stream for log messages
- `min_level::LogLevel`: Minimum logging level to display (mutable so `logging/setLevel`
  can adjust it on the installed logger)
- `message_limits::Dict{Any,Int}`: Message limit settings for rate limiting
"""
mutable struct MCPLogger <: AbstractLogger
    stream::IO
    min_level::LogLevel
    message_limits::Dict{Any,Int}
end

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
    # Do not relay HTTP.jl's internal connection-loop logging into the MCP notification
    # stream. On every client disconnect HTTP.jl logs the `closeread` EOF at error level
    # ("handle_connection handler error") — transport-internal teardown noise, not an MCP
    # application log. The package's own transport errors (logged from this module) pass.
    if _module !== nothing && nameof(Base.moduleroot(_module)) === :HTTP
        return false
    end
    return true
end

Logging.min_enabled_level(logger::MCPLogger) = logger.min_level

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
    # Convert log level to MCP protocol level
    mcp_level = if level >= Error
        "error"
    elseif level >= Warn 
        "warning"
    else
        "info"
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
    
    # Write to output stream
    println(logger.stream, String(take!(buf)))
    Base.flush(logger.stream)
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

#!/usr/bin/env julia

# MCP Tasks demo (SEP-1686, experimental): a long-running tool executed in the
# background via task-augmented tools/call, with progress notifications and
# cooperative cancellation.
#
# Run:    julia --project examples/task_server.jl
#
# Try it over stdio (each line is one JSON-RPC message; responses interleave):
#
#   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"demo","version":"1.0"}}}
#   {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"count_slowly","arguments":{"n":5},"task":{"ttl":60000}}}
#     -> returns {"task":{"taskId":"...","status":"working",...}} immediately
#   {"jsonrpc":"2.0","id":3,"method":"tasks/get","params":{"taskId":"<taskId>"}}
#     -> poll status: working ... completed
#   {"jsonrpc":"2.0","id":4,"method":"tasks/result","params":{"taskId":"<taskId>"}}
#     -> blocks until terminal, then returns the tool result
#   {"jsonrpc":"2.0","id":5,"method":"tasks/cancel","params":{"taskId":"<taskId>"}}
#     -> cancels a running task (rejected once terminal)

using ModelContextProtocol

count_slowly = MCPTool(
    name = "count_slowly",
    description = "Count to n, one second per step (use task execution!)",
    parameters = [
        ToolParameter(name = "n", type = "integer",
                      description = "How far to count", required = false, default = 5)
    ],
    handler = (args, ctx) -> begin
        n = Int(args["n"])
        for i in 1:n
            # Stop early if the client called tasks/cancel
            task_cancelled(ctx) && return TextContent(text = "cancelled at $i/$n")
            # Progress flows to the client when it sent a progressToken
            send_progress(ctx, i; total = n, message = "counted $i of $n")
            sleep(1.0)
        end
        TextContent(text = "counted to $n")
    end,
    task_support = :optional,  # client chooses: sync call or task-augmented
)

quick = MCPTool(
    name = "quick_echo",
    description = "Plain synchronous tool for comparison",
    parameters = [
        ToolParameter(name = "msg", type = "string",
                      description = "Message to echo", required = true)
    ],
    handler = args -> TextContent(text = "echo: $(args["msg"])"),
)

server = mcp_server(
    name = "task-demo-server",
    version = "1.0.0",
    description = "Demonstrates MCP Tasks: background tool execution with polling, blocking result retrieval, and cancellation",
    tools = [count_slowly, quick],
)

println(stderr, "task-demo-server ready (stdio). count_slowly supports task-augmented execution.")
start!(server)

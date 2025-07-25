#!/usr/bin/env julia

# Simple test client for HTTP MCP server

using HTTP
using JSON3

# Test initialize request
println("Testing initialize...")
response = HTTP.post(
    "http://127.0.0.1:3000/",
    ["Content-Type" => "application/json"],
    JSON3.write(Dict(
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => Dict(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict(
                "experimental" => Dict(),
                "roots" => Dict("listChanged" => true),
                "sampling" => Dict()
            ),
            "clientInfo" => Dict(
                "name" => "test-client",
                "version" => "1.0.0"
            )
        ),
        "id" => 1
    ))
)

println("Initialize response:")
println(String(response.body))
println()

# Test tools/list request
println("Testing tools/list...")
response = HTTP.post(
    "http://127.0.0.1:3000/",
    ["Content-Type" => "application/json"],
    JSON3.write(Dict(
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "params" => Dict(),
        "id" => 2
    ))
)

println("Tools list response:")
println(String(response.body))
println()

# Test calling the echo tool
println("Testing echo tool...")
response = HTTP.post(
    "http://127.0.0.1:3000/",
    ["Content-Type" => "application/json"],
    JSON3.write(Dict(
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => Dict(
            "name" => "echo",
            "arguments" => Dict("message" => "Hello from HTTP client!")
        ),
        "id" => 3
    ))
)

println("Echo tool response:")
println(String(response.body))
#!/usr/bin/env julia

# Demonstration of HTTP transport with direct usage

using ModelContextProtocol
using HTTP
using JSON3

# Create HTTP transport
transport = HttpTransport(port=3001)

# Create simple handlers for testing
println("Starting minimal HTTP transport demo on port 3001...")

# Connect the transport (starts HTTP server)
ModelContextProtocol.connect(transport)

println("Server is running. Send requests to http://localhost:3001/")
println("Example: curl -X POST http://localhost:3001/ -H 'Content-Type: application/json' -d '{\"test\":\"data\"}'")
println("Press Ctrl+C to stop")

# Simple message processing loop
try
    while ModelContextProtocol.is_connected(transport)
        # Try to read a message
        msg = ModelContextProtocol.read_message(transport)
        
        if !isnothing(msg)
            println("\nReceived: $msg")
            
            # Parse as JSON
            try
                data = JSON3.read(msg)
                
                # Send a response
                response = Dict(
                    "jsonrpc" => "2.0",
                    "result" => Dict("echo" => msg, "timestamp" => now()),
                    "id" => get(data, :id, nothing)
                )
                
                ModelContextProtocol.write_message(transport, JSON3.write(response))
                ModelContextProtocol.end_response(transport)
                
                println("Sent response")
            catch e
                println("Error processing message: $e")
            end
        else
            # No message available, sleep briefly
            sleep(0.1)
        end
    end
catch e
    if !(e isa InterruptException)
        @error "Error in message loop" exception=e
    end
finally
    ModelContextProtocol.close(transport)
    println("\nServer stopped")
end
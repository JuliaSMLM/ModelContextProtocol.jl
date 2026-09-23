using Test
using JSON

# Simple test that just verifies basic stdio communication without Python dependencies
@testset "Basic Stdio Communication" begin
    # Create a simple echo server that doesn't require ModelContextProtocol
    echo_server_code = """
    using JSON
    
    # Read a line from stdin
    line = readline(stdin)
    
    # Parse it as JSON
    try
        msg = JSON.parse(line)
        
        # Echo it back with a response wrapper
        response = Dict(
            "received" => msg,
            "timestamp" => time()
        )
        
        println(stdout, JSON.json(response))
        flush(stdout)
    catch e
        println(stderr, "Error: ", e)
        flush(stderr)
    end
    """
    
    server_file = tempname() * ".jl"
    
    try
        write(server_file, echo_server_code)
        
        # Test message
        test_msg = Dict("test" => "hello", "value" => 42)
        
        # Run the server and communicate. The subprocess must inherit this harness's
        # project environment: the server code does `using JSON`, and without
        # --project it would resolve against the machine's global environment —
        # working or failing depending on what happens to be installed there.
        julia_exe = Base.julia_cmd().exec[1]

        output = read(pipeline(
            `echo $(JSON.json(test_msg))`,
            `$julia_exe --project=$(Base.active_project()) $server_file`
        ), String)
        
        # Parse response
        response = JSON.parse(output)
        
        @test haskey(response, "received")
        @test response["received"]["test"] == "hello"
        @test response["received"]["value"] == 42
        @test haskey(response, "timestamp")
        
    finally
        rm(server_file, force=true)
    end
end
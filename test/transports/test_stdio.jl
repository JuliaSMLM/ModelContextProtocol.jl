using Test
using ModelContextProtocol
using ModelContextProtocol: read_message, write_message, is_connected, close, flush

@testset "StdioTransport" begin
    @testset "Basic functionality" begin
        # Create a transport with custom IO streams for testing
        input = IOBuffer("test message\n")
        output = IOBuffer()
        
        transport = StdioTransport(input=input, output=output)
        
        @test is_connected(transport) == true
        
        # Test reading
        msg = read_message(transport)
        @test msg == "test message"
        
        # Test writing
        write_message(transport, "response")
        seekstart(output)
        @test readline(output) == "response"
        
        # Test close
        close(transport)
        @test is_connected(transport) == false
    end
    
    @testset "EOF handling" begin
        # Empty input should return nothing
        input = IOBuffer("")
        transport = StdioTransport(input=input, output=IOBuffer())
        
        msg = read_message(transport)
        @test isnothing(msg)
        @test is_connected(transport) == false
    end
    
    @testset "Empty line handling" begin
        # Empty lines should be skipped
        input = IOBuffer("\n\ntest\n")
        transport = StdioTransport(input=input, output=IOBuffer())
        
        msg1 = read_message(transport)
        @test isnothing(msg1)  # Empty line returns nothing
        
        msg2 = read_message(transport)
        @test isnothing(msg2)  # Empty line returns nothing
        
        msg3 = read_message(transport)
        @test msg3 == "test"
    end
    
    @testset "Default streams" begin
        # Test that default constructor uses stdin/stdout
        transport = StdioTransport()
        @test transport.input === stdin
        @test transport.output === stdout
        @test is_connected(transport) == true
    end
end
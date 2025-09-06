@testset "content2dict function" begin
    @testset "TextContent conversion" begin
        # Basic text content
        text_content = TextContent(
            type = "text",
            text = "Hello, world!",
            annotations = LittleDict{String,Any}("key" => "value")
        )
        
        dict = content2dict(text_content)
        
        @test dict["type"] == "text"
        @test dict["text"] == "Hello, world!"
        @test dict["annotations"] == LittleDict{String,Any}("key" => "value")
        
        # Text content with empty annotations
        text_content_empty = TextContent(
            type = "text",
            text = "Test",
            annotations = LittleDict{String,Any}()
        )
        
        dict_empty = content2dict(text_content_empty)
        @test dict_empty["annotations"] == LittleDict{String,Any}()
    end
    
    @testset "ImageContent conversion" begin
        # Test image data
        image_data = [0x89, 0x50, 0x4E, 0x47]  # PNG header
        
        image_content = ImageContent(
            type = "image",
            data = image_data,
            mime_type = "image/png",
            annotations = LittleDict{String,Any}("alt" => "test image")
        )
        
        dict = content2dict(image_content)
        
        @test dict["type"] == "image"
        @test dict["data"] == base64encode(image_data)
        @test dict["mimeType"] == "image/png"
        @test dict["annotations"] == LittleDict{String,Any}("alt" => "test image")
    end
    
    @testset "EmbeddedResource conversion" begin
        # Create a test resource
        text_resource = Dict{String,Any}(
            "uri" => "test://example.txt",
            "text" => "Resource content",
            "mimeType" => "text/plain"
        )
        
        embedded = EmbeddedResource(
            type = "resource",
            resource = text_resource,
            annotations = LittleDict{String,Any}("source" => "test")
        )
        
        dict = content2dict(embedded)
        
        @test dict["type"] == "resource"
        @test dict["resource"] isa AbstractDict
        @test dict["resource"]["uri"] == "test://example.txt"
        @test dict["resource"]["text"] == "Resource content"
        @test dict["resource"]["mimeType"] == "text/plain"
        @test dict["annotations"] == LittleDict{String,Any}("source" => "test")
        
        # Test with blob resource
        blob_resource = Dict{String,Any}(
            "uri" => "test://example.bin",
            "blob" => base64encode([0x01, 0x02, 0x03, 0x04]),
            "mimeType" => "application/octet-stream"
        )
        
        embedded_blob = EmbeddedResource(
            type = "resource",
            resource = blob_resource,
            annotations = LittleDict{String,Any}()
        )
        
        dict_blob = content2dict(embedded_blob)
        
        @test dict_blob["type"] == "resource"
        @test dict_blob["resource"]["uri"] == "test://example.bin"
        @test dict_blob["resource"]["blob"] == base64encode([0x01, 0x02, 0x03, 0x04])
        @test dict_blob["resource"]["mimeType"] == "application/octet-stream"
    end
    
    @testset "Vector of content conversion" begin
        # Test with map function
        contents = [
            TextContent(type = "text", text = "First", annotations = LittleDict{String,Any}()),
            ImageContent(type = "image", data = [0xFF], mime_type = "image/jpeg", annotations = LittleDict{String,Any}()),
            TextContent(type = "text", text = "Second", annotations = LittleDict{String,Any}())
        ]
        
        dicts = map(content2dict, contents)
        
        @test length(dicts) == 3
        @test dicts[1]["type"] == "text"
        @test dicts[1]["text"] == "First"
        @test dicts[2]["type"] == "image"
        @test dicts[2]["mimeType"] == "image/jpeg"
        @test dicts[3]["type"] == "text"
        @test dicts[3]["text"] == "Second"
    end
    
    @testset "Error handling" begin
        # Create a custom content type that's not supported
        struct UnsupportedContent <: Content
            type::String
        end
        
        unsupported = UnsupportedContent("unsupported")
        
        @test_throws ArgumentError content2dict(unsupported)
        
        try
            content2dict(unsupported)
        catch e
            @test e isa ArgumentError
            @test contains(e.msg, "Unsupported content type: UnsupportedContent")
        end
    end
end
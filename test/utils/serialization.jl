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

@testset "CallToolResult structuredContent serialization" begin
    with_sc = CallToolResult(
        content = [Dict{String,Any}("type" => "text", "text" => "hi")],
        structured_content = Dict("answer" => 42),
    )
    without_sc = CallToolResult(
        content = [Dict{String,Any}("type" => "text", "text" => "hi")],
    )
    j_with = JSON3.read(JSON3.write(with_sc), Dict{String,Any})
    j_without = JSON3.read(JSON3.write(without_sc), Dict{String,Any})

    # structured_content is emitted as `structuredContent`, omitted when nothing
    @test j_with["structuredContent"]["answer"] == 42
    @test !haskey(j_without, "structuredContent")
    # existing fields are unaffected
    @test haskey(j_with, "content")
    @test j_with["isError"] == false  # is_error -> isError wire key

    # _meta is emitted verbatim, omitted when nothing
    with_meta = CallToolResult(
        content = [Dict{String,Any}("type" => "text", "text" => "hi")],
        _meta = Dict("trace" => "abc"),
    )
    j_meta = JSON3.read(JSON3.write(with_meta), Dict{String,Any})
    @test j_meta["_meta"]["trace"] == "abc"
    @test !haskey(j_without, "_meta")
end

@testset "CallToolResult accepts Content objects" begin
    # CallToolResult.content is Vector{Dict{String,Any}}. Content objects — what tool
    # handlers naturally build — must convert in place via content2dict, so that
    # `CallToolResult(content = [TextContent(...)], is_error = true)`, a documented
    # handler pattern, constructs instead of throwing MethodError(convert, Dict, ...).
    r = CallToolResult(content = [TextContent(text = "denied")], is_error = true)
    @test r.content isa Vector{Dict{String,Any}}
    @test r.content == [Dict{String,Any}("type" => "text", "text" => "denied")]
    @test r.is_error

    # mixed Content types convert element-wise
    r2 = CallToolResult(content = [TextContent(text = "a"),
                                   AudioContent(data = [0x52], mime_type = "audio/wav")])
    @test length(r2.content) == 2
    @test r2.content[1]["type"] == "text"
    @test r2.content[2]["type"] == "audio"
    @test !r2.is_error

    # same wire shape as pre-built Dicts
    j = JSON3.read(JSON3.write(r), Dict{String,Any})
    @test j["content"][1]["type"] == "text"
    @test j["content"][1]["text"] == "denied"
    @test j["isError"] == true
end

@testset "AudioContent conversion" begin
    audio = AudioContent(data = [0x52, 0x49, 0x46, 0x46], mime_type = "audio/wav")
    dict = content2dict(audio)
    @test dict["type"] == "audio"
    @test dict["data"] == base64encode([0x52, 0x49, 0x46, 0x46])
    @test dict["mimeType"] == "audio/wav"
    @test !haskey(dict, "annotations")
    @test !haskey(dict, "_meta")

    # AudioContent is a valid prompt message content type
    msg = PromptMessage(content = audio)
    @test msg.content isa AudioContent
end

@testset "ResourceLink spec wire format" begin
    link = ResourceLink(
        uri = "file:///project/result.png",
        name = "result.png",
        description = "Segmentation overlay",
        mime_type = "image/png",
    )
    dict = content2dict(link)
    # MCP spec shape: type "resource_link" with uri/name (not "link"/"href")
    @test dict["type"] == "resource_link"
    @test dict["uri"] == "file:///project/result.png"
    @test dict["name"] == "result.png"
    @test dict["description"] == "Segmentation overlay"
    @test dict["mimeType"] == "image/png"
    @test !haskey(dict, "href")

    # Optional fields omitted when unset
    minimal = content2dict(ResourceLink(uri = "file:///x", name = "x"))
    @test !haskey(minimal, "description") && !haskey(minimal, "mimeType") && !haskey(minimal, "title")
end
# Define a tool 

using JSON


function gen_2d_array(name::String, sz::Int)
    arr = zeros(sz, sz)
    Main.storage[name] = arr
    return Dict("status" => "success", "message" => "Array created", "name" => name)
end

julia_gen_array = MCPTool(
    name="gen_2d_array",
    description="Generate a 2D array of Float64",
    parameters=[
        ToolParameter(
            name="name",
            type="string",
            description="The name of the array to store in the workspace",
            required=true
        ),
        ToolParameter(
            name="size",
            type="integer",
            description="The size of the array (size x size)",
            required=true
        )
    ],
    handler = params -> begin
        # Parse or convert the size parameter explicitly
        name = params["name"]
        # handle if size is string
        if typeof(params["size"]) == String
            sz = parse(Int, params["size"])
        else
            sz = params["size"]
        end
        
        result = gen_2d_array(name, sz)
        TextContent(
            type = "text",
            text = JSON.json(result)
        )
    end
    
)


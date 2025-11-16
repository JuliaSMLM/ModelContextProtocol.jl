# Auto-Registration Bug Analysis and Fix

**Date**: 2025-10-22
**Status**: ✅ **FIXED** - Solution implemented and verified
**Severity**: High - Feature was broken in Julia 1.12+

---

## Summary

The `auto_register!` function in `src/core/init.jl` was broken due to Julia scoping issues with the `names()` function and Julia 1.12's stricter world age semantics. The function would scan component files but fail to register any tools/resources/prompts, returning empty lists.

**Root Cause**: Using `names(mod, all=true)` to introspect modules created inside functions returns only `[:anonymous]` instead of actual variable names.

**Solution**: Use `include()`'s return value directly instead of introspecting the module.

---

## Symptoms

```bash
$ npx @modelcontextprotocol/inspector --cli julia --project=. examples/reg_dir.jl --method tools/list

{
  "tools": []  # ❌ Should contain: julia_version, gen_2d_array, inspect_workspace
}
```

```julia
julia> server = mcp_server(name="test", auto_register_dir="examples/mcp_tools")
[ Info: Auto-registering components from .../examples/mcp_tools
# ✅ Server starts successfully (misleading!)

julia> length(server.tools)
0  # ❌ Should be 3
```

---

## Root Cause Analysis

### Issue 1: Julia Scoping Bug with names()

When `Module()` is created inside a function, `names(mod, all=true)` returns incomplete results:

```julia
# ✅ WORKS at top level
mod = Module()
Core.eval(mod, :(using ModelContextProtocol))
Base.include(mod, "component.jl")
names(mod, all=true)  # → [:anonymous, :component_name, ...]

# ❌ FAILS inside function
function test()
    mod = Module()
    Core.eval(mod, :(using ModelContextProtocol))
    Base.include(mod, "component.jl")
    names(mod, all=true)  # → [:anonymous]  ← Only this!
end
```

**Why**: Julia's compilation and scoping model doesn't fully populate `names()` for modules created in local scopes.

### Issue 2: Julia 1.12 World Age Semantics

The original implementation (commit bdee6e5) used:

```julia
eval(Meta.parse("module TempModule using ModelContextProtocol; include(\"$path\") end"))
mod = getfield(Main, module_name)
```

This approach:
- ✅ Worked in Julia 1.10/1.11 (module created at top level in Main)
- ❌ **Fails in Julia 1.12** with world age warnings:

```
WARNING: Detected access to binding in a world prior to its definition world.
Julia 1.12 has introduced more strict world age semantics for global bindings.
This code will error in future versions of Julia.
```

---

## Solution: Use include() Return Value

Julia's `include()` returns the **last expression** in the file. For component files that end with a tool/resource/prompt definition, this is exactly what we need!

### Before (Broken)

```julia
function auto_register!(server::Server, dir::AbstractString)
    for file in component_files
        mod = Module()
        Core.eval(mod, :(using ModelContextProtocol))
        Base.include(mod, file)

        # ❌ This fails - names() returns only [:anonymous]
        for name in names(mod, all=true)
            if isdefined(mod, name)
                component = getfield(mod, name)
                if component isa MCPTool
                    register!(server, component)
                end
            end
        end
    end
end
```

### After (Fixed)

```julia
function auto_register!(server::Server, dir::AbstractString)
    for file in component_files
        mod = Module()
        Core.eval(mod, :(using ModelContextProtocol))

        # ✅ include() returns the last expression!
        component = Base.include(mod, file)

        if component isa MCPTool  # or MCPResource, MCPPrompt
            register!(server, component)
            @info "Registered MCPTool from $file"
        end
    end
end
```

### Component File Format Requirement

Component files must have the tool/resource/prompt as the **last expression**:

```julia
# examples/mcp_tools/tools/julia_version.jl
using JSON3

julia_version_tool = MCPTool(
    name = "julia_version",
    description = "Get Julia version",
    handler = params -> Dict("version" => string(VERSION))
)  # ← This is the last expression, so include() returns it!
```

---

## Verification

After implementing the fix:

```bash
$ julia --project=. -e 'using ModelContextProtocol;
  server = mcp_server(name="test", auto_register_dir="examples/mcp_tools");
  println("Tools: ", length(server.tools), ", Resources: ", length(server.resources),
          ", Prompts: ", length(server.prompts))'

[ Info: Auto-registering components from .../examples/mcp_tools
[ Info: Registered MCPTool from .../gen_array.jl
[ Info: Registered MCPTool from .../julia_version.jl
[ Info: Registered MCPTool from .../workspace_inspector.jl
[ Info: Registered MCPResource from .../workspace_data.jl
[ Info: Registered MCPPrompt from .../analysis_prompt.jl
Tools: 3, Resources: 1, Prompts: 1
✅ SUCCESS!
```

```bash
$ npx @modelcontextprotocol/inspector --cli julia --project=. examples/reg_dir.jl --method tools/list

{
  "tools": [
    {"name": "gen_2d_array", ...},
    {"name": "julia_version", ...},
    {"name": "inspect_workspace", ...}
  ]
}
✅ SUCCESS!
```

---

## Git History

1. **bdee6e5** (Jan 10, 2025): "adding auto registration tools. not testted"
   - Original implementation using `eval(Meta.parse("module ..."))` at top level
   - Worked in Julia 1.10/1.11

2. **0239a75** (Jan 14, 2025): "add register directory example and bug fixes"
   - Changed to `Module()` + `names()` introspection
   - **Broke auto-registration** due to scoping issue

3. **56fe801** (Sep 3, 2025): "Move auto-registration to async background task"
   - Attempted async fix (didn't address root cause)

4. **e7f238b** (Sep 4, 2025): "Fix Inspector CLI compatibility"
   - Reverted to synchronous (still broken)

5. **[This fix]** (Oct 22, 2025): Use `include()` return value
   - ✅ **Properly fixed** using documented Julia behavior

---

## Why the Original Approach Broke

The change from commit bdee6e5 (eval at top level) to commit 0239a75 (Module() + names()) broke auto-registration because:

1. **Module introspection via names() doesn't work in function scope**
   - `names(mod, all=true)` requires the module to be "fully realized" in the current world age
   - Modules created as local variables aren't fully introspectable this way

2. **Julia 1.12's stricter world age semantics**
   - The original `eval()` approach would fail in Julia 1.12+ with world age errors
   - Even if reverted, it wouldn't be forward-compatible

---

## Alternative Approaches Considered

### Option 1: Revert to eval() at top level
❌ **Rejected**: Fails in Julia 1.12+ with world age errors

### Option 2: Use invokelatest with eval
❌ **Rejected**: Still doesn't populate names() correctly

### Option 3: Parse files as text
❌ **Rejected**: Complex, fragile, unnecessary

### Option 4: Require explicit exports
❌ **Rejected**: Adds user burden, breaks existing files

### Option 5: Use include() return value ✅
✅ **SELECTED**: Simple, robust, uses documented Julia behavior

---

## Migration Guide

### For Component Authors

Your component files must have the component as the **last expression**:

```julia
# ✅ CORRECT - component is last expression
my_tool = MCPTool(
    name = "my_tool",
    description = "Does something",
    handler = params -> ...
)

# ❌ INCORRECT - comment is last expression
my_tool = MCPTool(
    name = "my_tool",
    description = "Does something",
    handler = params -> ...
)
# Some final comment here

# ✅ FIX - add component reference at end
my_tool = MCPTool(
    name = "my_tool",
    description = "Does something",
    handler = params -> ...
)
# Some comment here
my_tool  # ← Ensure component is returned
```

### For Existing Code

All existing component files in `examples/mcp_tools/` already follow this pattern, so no changes needed.

---

## Testing

To test auto-registration:

```bash
# Direct Julia test
julia --project=. -e 'using ModelContextProtocol;
  server = mcp_server(name="test", auto_register_dir="examples/mcp_tools");
  @show length(server.tools);'

# MCP Inspector test
npx @modelcontextprotocol/inspector --cli \
  julia --project=. examples/reg_dir.jl \
  -- --method tools/list
```

Expected results:
- **Tools**: 3 (gen_2d_array, julia_version, inspect_workspace)
- **Resources**: 1 (workspace_data)
- **Prompts**: 1 (analyze_code)

---

## Lessons Learned

1. **Always test before committing** - Original commit said "not testted" [sic]
2. **Module introspection is tricky** - `names()` behavior varies by scope
3. **Julia version compatibility matters** - World age semantics changed in 1.12
4. **Use documented behavior** - `include()` return value is reliable
5. **Silent failures are dangerous** - Server appeared to start successfully but registered nothing

---

## Status

✅ **FIXED** in src/core/init.jl (Oct 22, 2025)
✅ **TESTED** with MCP Inspector and direct Julia calls
✅ **DOCUMENTED** in auto_register! docstring
✅ **VERIFIED** on Julia 1.12.1

**Impact**: Auto-registration now works correctly for all MCP component types.

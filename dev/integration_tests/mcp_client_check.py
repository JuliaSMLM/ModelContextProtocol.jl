#!/usr/bin/env python3
"""Standalone MCP client check.

Drives a Julia MCP server over stdio using the *current* `mcp` Python SDK
(`stdio_client` + `ClientSession`), exercising initialize -> tools/list ->
tools/call and an error path. Exits 0 on success, 1 on any failure, 2 on usage
error. The server command + args are everything after the script name, e.g.:

    python3 mcp_client_check.py julia --project=/path/to/repo echo_server.jl

This is deliberately a real external process (no PythonCall / CondaPkg), so the
Julia test can orchestrate it as a subprocess and assert on its exit code.
"""
import asyncio
import sys
import traceback

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def run(server_cmd, server_args):
    params = StdioServerParameters(command=server_cmd, args=server_args)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print(f"[py] initialized: protocol={getattr(init, 'protocolVersion', '?')}")

            tools = await session.list_tools()
            names = [t.name for t in tools.tools]
            print(f"[py] tools/list -> {names}")
            assert "echo" in names, f"expected an 'echo' tool, got {names}"

            result = await session.call_tool("echo", {"text": "Hello from Python!"})
            texts = [c.text for c in result.content if getattr(c, "type", None) == "text"]
            print(f"[py] tools/call echo -> {texts} (isError={result.isError})")
            assert not result.isError, "echo unexpectedly returned isError=true"
            assert any("Hello from Python!" in t for t in texts), \
                f"echo did not round-trip the argument: {texts}"

            # Numeric tool with two parameters.
            add = await session.call_tool("add", {"a": 5, "b": 3})
            add_texts = [c.text for c in add.content if getattr(c, "type", None) == "text"]
            print(f"[py] tools/call add(5,3) -> {add_texts}")
            assert any("8" in t for t in add_texts), f"add(5,3) did not return 8: {add_texts}"

            # Resources: list + read.
            resources = await session.list_resources()
            ruris = [str(r.uri) for r in resources.resources]
            print(f"[py] resources/list -> {ruris}")
            res = next((r for r in resources.resources if "integration/data" in str(r.uri)), None)
            assert res is not None, f"expected the integration data resource, got {ruris}"
            contents = await session.read_resource(res.uri)
            rtexts = [c.text for c in contents.contents if getattr(c, "text", None) is not None]
            print(f"[py] resources/read -> {rtexts}")
            assert any("answer" in t for t in rtexts), f"resource content unexpected: {rtexts}"

            # Error path: an unknown tool must surface as an error (either an
            # isError result or a raised McpError) rather than a silent success.
            try:
                err = await session.call_tool("does_not_exist", {})
                assert err.isError, "unknown tool should return isError=true"
                print("[py] tools/call unknown -> isError result (ok)")
            except Exception as e:  # noqa: BLE001
                print(f"[py] tools/call unknown -> raised {type(e).__name__} (ok)")

            print("[py] all assertions passed")


def main():
    if len(sys.argv) < 2:
        print("usage: mcp_client_check.py <server-cmd> [args...]", file=sys.stderr)
        return 2
    cmd, *args = sys.argv[1:]
    try:
        asyncio.run(asyncio.wait_for(run(cmd, args), timeout=120))
    except Exception as e:  # noqa: BLE001 - this is a test harness; report everything
        print(f"[py] FAILED: {e!r}", file=sys.stderr)
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

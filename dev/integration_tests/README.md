# External Integration Tests

Cross-language integration tests for ModelContextProtocol.jl: a real external Python
process (the official [`mcp`](https://pypi.org/project/mcp/) SDK) drives a local Julia
MCP server over stdio, exercising the protocol end to end — initialize, `tools/list`,
`tools/call` (string and numeric arguments), `resources/list`, `resources/read`, and an
error path.

These are **not** part of `Pkg.test()` (they need an external Python interpreter) and
they do **not** use PythonCall/CondaPkg. The Python client runs as a plain subprocess,
so the only requirement is a `python3` on `PATH` with `mcp` importable.

## Setup

```bash
cd dev/integration_tests

# 1. Julia deps (develops the in-repo ModelContextProtocol into this env)
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.instantiate()'

# 2. Python MCP SDK, into whatever python3 is on PATH
pip install -r requirements.txt
```

## Running

```bash
julia --project=. runtests.jl
```

`test_basic_stdio.jl` always runs (Julia-only). `test_python_client.jl` auto-detects a
`python3` with `mcp`; if none is found it skips with a clear message rather than
silently passing.

## Files

- `runtests.jl` — entry point; includes the two suites below
- `test_basic_stdio.jl` — Julia-only stdio smoke test (no Python)
- `test_python_client.jl` — spawns the Python client against the Julia server, asserts a clean exit
- `mcp_client_check.py` — standalone Python `mcp`-SDK client (initialize → tools → resources → error path)
- `integration_server.jl` — the Julia MCP server under test (echo + add tools, one resource)

## CI

Install Julia and a `python3`, `pip install -r requirements.txt`, then
`julia --project=. runtests.jl`. No CondaPkg/pixi step is required.

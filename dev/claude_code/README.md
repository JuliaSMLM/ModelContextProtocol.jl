# Claude Code interop probe

The conformance suite is a reference client. This folder checks the package against a
shipping one: Claude Code. It is a manual check, not CI, because it needs a signed-in
Claude Code.

`interop_server.jl` is a small server with four tools:

| Tool | What it shows |
|---|---|
| `era_probe` | The protocol era and version the client used, and the capabilities it declared on the request |
| `ask_name` | A form elicitation through MRTR (`InputRequired`) |
| `slow_job` | A long call handed off as a background task (`task_detach`) |
| `confirm_job` | A background task that pauses to ask the user a question (`task_await_input`) |

## Run it

Over stdio, with a throwaway MCP config so no project or user settings are touched:

```bash
cat > /tmp/interop-stdio.json <<'EOF'
{"mcpServers":{"interop":{"command":"julia","args":["--project=/path/to/ModelContextProtocol","/path/to/ModelContextProtocol/dev/claude_code/interop_server.jl"]}}}
EOF

MCP_TIMEOUT=120000 claude -p 'Call the era_probe tool and print its output verbatim.' \
  --mcp-config /tmp/interop-stdio.json --strict-mcp-config \
  --allowedTools 'mcp__interop__era_probe'
```

Over HTTP, start the server first:

```bash
julia --project dev/claude_code/interop_server.jl http 8798 &
echo '{"mcpServers":{"interop":{"type":"http","url":"http://127.0.0.1:8798/"}}}' > /tmp/interop-http.json
claude -p 'Call the era_probe tool and print its output verbatim.' \
  --mcp-config /tmp/interop-http.json --strict-mcp-config \
  --allowedTools 'mcp__interop__era_probe'
```

`MCP_TIMEOUT` gives Julia time to start on a cold cache. Add `--debug-file <path>` to
see Claude Code's own log of the connection.

`ask_name`, `slow_job` and `confirm_job` need a person: run `claude` interactively with
the same `--mcp-config` and ask it to call them. A one-shot `claude -p` run has nobody to
answer a form. It also did not declare the tasks extension when tried with 2.1.332, in
plain and `stream-json` output and with `CLAUDE_AUTO_BACKGROUND_TASKS=1`: `slow_job`
then runs to the end as an ordinary call and reports `ran as a task: false`.

## What to expect

With Claude Code 2.1.332, over both stdio and HTTP, `era_probe` reports:

```
era: modern (per-request _meta)
protocol version: 2026-07-28
client capabilities: elicitation, roots
elicitation modes: form, url
extensions:
```

So Claude Code speaks the 2026-07-28 revision to this package with no configuration,
and declares both elicitation modes. The `extensions` line is empty on a one-shot run.
In an interactive session it should list `io.modelcontextprotocol/tasks`; that, and the
three tools that need a person, have not been checked yet.

Re-run this after a Claude Code release that changes its MCP support, and before a
release of this package that changes the modern-era surface.

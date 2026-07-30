#!/usr/bin/env bash
#
# wait-http.sh <url> <server-pid> [timeout-seconds]
#
# Block until an MCP Streamable HTTP server answers `initialize`, then return.
#
# Replaces a fixed `sleep 15`, which was both too slow and not actually a
# guarantee: the server answered in ~4s locally, but a cold runner compiling Julia
# could take longer than the sleep and fail confusingly. Polling also notices a
# server that died during startup instead of waiting out the full timeout.
set -euo pipefail

url=$1
pid=$2
limit=${3:-90}

for ((i = 1; i <= limit; i++)); do
  if curl -sf -o /dev/null -X POST "$url" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"ci","version":"1.0"}},"id":1}'; then
    echo "server ready after ${i}s"
    exit 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "server process $pid exited during startup"
    exit 1
  fi
  sleep 1
done

echo "server did not become ready within ${limit}s"
exit 1

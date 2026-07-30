#!/usr/bin/env bash
#
# assert-json.sh <file> <jq-filter> [label]
#
# Assert that <file> holds JSON satisfying <jq-filter>, and fail loudly otherwise.
#
# The emptiness check is not redundant: `jq -e` on an EMPTY file exits 0 (verified
# with jq 1.6), and a failed Inspector invocation writes NOTHING to stdout — it
# reports the error on stderr and exits non-zero. So a step that captured stdout to
# a file and then only ran `jq -e` would pass on a total failure. Combined with the
# `|| true` this workflow used to carry, that is exactly how these checks went
# green while testing nothing.
set -euo pipefail

file=$1
filter=$2
label=${3:-$filter}

if [ ! -s "$file" ]; then
  echo "ASSERT FAIL [$label]: '$file' is missing or empty (the command produced no stdout)"
  exit 1
fi

if ! jq -e "$filter" "$file" >/dev/null 2>&1; then
  echo "ASSERT FAIL [$label]: filter did not hold: $filter"
  echo "--- actual payload ---"
  jq . "$file" 2>/dev/null || cat "$file"
  exit 1
fi

echo "ok [$label]"

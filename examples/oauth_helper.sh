#!/bin/bash
# OAuth helper script - completes OAuth flow without a browser
# Usage: ./oauth_helper.sh "http://127.0.0.1:3000/authorize?..."
#
# Paste the full authorize URL (can include newlines, they'll be stripped)

# Read URL from argument or stdin
if [ -n "$1" ]; then
    URL="$1"
else
    echo "Paste the authorize URL (press Ctrl+D when done):"
    URL=$(cat)
fi

# Remove any newlines/whitespace from the URL
URL=$(echo "$URL" | tr -d '\n\r ' )

echo "Processing OAuth flow..."
echo "URL: ${URL:0:80}..."

# Follow redirects and capture the final Location header
# We use -w to get redirect_url, and stop before hitting Claude Code's callback
FINAL_URL=$(curl -s -L -o /dev/null -w '%{url_effective}' \
    --max-redirs 10 \
    "$URL" 2>&1)

echo "Final redirect: ${FINAL_URL:0:80}..."

# Check if it's the Claude Code callback
if [[ "$FINAL_URL" == *"localhost"*"/callback"* ]] || [[ "$FINAL_URL" == *"127.0.0.1"*"/callback"*"code="* ]]; then
    echo "Hitting Claude Code callback..."
    RESULT=$(curl -s "$FINAL_URL" 2>&1)
    echo "Done! Result: $RESULT"
    echo ""
    echo "Auth should be complete. Check Claude Code with: claude mcp list"
else
    echo "Unexpected final URL. OAuth flow may have failed."
    echo "Full URL: $FINAL_URL"
fi

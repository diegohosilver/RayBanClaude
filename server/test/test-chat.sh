#!/usr/bin/env bash
# Test script for the RayBan Claude Gateway (also runs under Windows Git Bash)
#
# Usage:
#   ./test-chat.sh [BASE_URL] [TOKEN]
#   GATEWAY_TOKEN=<token> ./test-chat.sh http://192.168.1.20:18790
#
# Without a token argument, ~/.raybanclaude/gateway-token is read (if present).

set -u

BASE_URL="${1:-http://localhost:18790}"
TOKEN="${2:-${GATEWAY_TOKEN:-}}"
TOKEN_FILE="$HOME/.raybanclaude/gateway-token"

if [ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi

if [ -z "$TOKEN" ]; then
  echo "Error: No gateway token. Pass it as the 2nd argument or via GATEWAY_TOKEN." >&2
  exit 1
fi

# Pretty-print JSON: jq, else node, else unchanged
pretty() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  elif command -v node >/dev/null 2>&1; then
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.stringify(JSON.parse(s),null,2))}catch{console.log(s)}})'
  else
    cat
  fi
}

AUTH_HEADER="Authorization: Bearer ${TOKEN}"

echo "=== Health (public) ==="
curl -s "$BASE_URL/health" | pretty
echo ""

echo "=== Health details ==="
curl -s -H "$AUTH_HEADER" "$BASE_URL/health/details" | pretty
echo ""

echo "=== Tools ==="
curl -s -H "$AUTH_HEADER" "$BASE_URL/tools" | pretty
echo ""

echo "=== Chat (text only) ==="
curl -s -X POST "$BASE_URL/chat" \
  -H "$AUTH_HEADER" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello! Which tools do you have? Please list them briefly."}' | pretty
echo ""

echo "=== Configuration ==="
curl -s -H "$AUTH_HEADER" "$BASE_URL/config" | pretty
echo ""

echo "=== MCP status ==="
curl -s -H "$AUTH_HEADER" "$BASE_URL/tools/health" | pretty
echo ""

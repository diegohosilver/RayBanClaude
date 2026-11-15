#!/usr/bin/env bash
# Start RayBan Claude: Claude Code with the channel + dashboard in the browser (macOS/Linux)
set -euo pipefail
cd "$(dirname "$0")"
PORT="${RAYBANCLAUDE_PORT:-18790}"

command -v claude >/dev/null || { echo "Claude Code is missing – please run ./setup.sh first."; exit 1; }
[[ -d channel/node_modules ]] || { echo "Dependencies are missing – please run ./setup.sh first."; exit 1; }

# Open the dashboard as soon as the channel is running
(
  for _ in $(seq 1 90); do
    if curl -fsS "http://localhost:$PORT/health" >/dev/null 2>&1; then
      if command -v open >/dev/null; then open "http://localhost:$PORT"; else xdg-open "http://localhost:$PORT" >/dev/null 2>&1 || true; fi
      exit 0
    fi
    sleep 1
  done
) &

echo "◉ RayBan Claude is starting … the dashboard will open in your browser shortly."
# Pre-approve only RayBan Claude's own tools – everything else still asks
# Earlier glasses session in this folder? Then continue there (--neu starts fresh)
resume=()
session_dir="$HOME/.claude/projects/$(pwd | sed 's/[^A-Za-z0-9]/-/g')"
if [[ "${1:-}" != "--neu" ]] && compgen -G "$session_dir/*.jsonl" > /dev/null; then
  resume=(--continue)
  echo "  Resuming the last conversation (new conversation: ./start.sh --neu)"
fi
exec claude "${resume[@]}" --dangerously-load-development-channels server:raybanclaude \
  --allowedTools "mcp__raybanclaude__reply" "mcp__raybanclaude__edit_message" "mcp__raybanclaude__request_photo" \
                 "mcp__raybanclaude__phone_action" "mcp__raybanclaude__remember" "mcp__raybanclaude__forget"

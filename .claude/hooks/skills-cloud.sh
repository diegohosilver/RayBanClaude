#!/usr/bin/env bash
# skills-cloud.sh - runs automatically at the start of every Claude Code cloud session
# (SessionStart hook in .claude/settings.json of each project).
# Installs Philip's skills from MoinMornhart/claude-skills into ~/.claude/skills.
# Silent: no output when everything works. Never aborts, never blocks the session.
# Locally (Windows PC) it does nothing - MorniSync handles that there.

[[ "${CLAUDE_CODE_REMOTE:-}" == "true" || "${1:-}" == "--force" ]] || exit 0

ZIEL="${HOME}/.claude/skills"
LOG="${HOME}/.claude/skills-cloud.log"
ARBEIT="$(mktemp -d 2>/dev/null || echo /tmp/skills-cloud.$$)"
mkdir -p "$ZIEL" "$ARBEIT"

# Fallback list in case the private claude-skills repo is not reachable in the session.
# Generated from skills-auswahl.txt by cloud/cloud-einrichten.sh.
ERSATZ=$(cat <<'LISTE'
vercel-labs/skills find-skills
mattpocock/skills grill-me
mattpocock/skills to-spec
mattpocock/skills prototype
obra/superpowers brainstorming
obra/superpowers writing-plans
obra/superpowers executing-plans
mattpocock/skills handoff
juliusbrussee/caveman caveman
obra/superpowers systematic-debugging
obra/superpowers verification-before-completion
mattpocock/skills tdd
mattpocock/skills git-guardrails-claude-code
leonxlnx/taste-skill design-taste-frontend
vercel-labs/agent-skills web-design-guidelines
nextlevelbuilder/ui-ux-pro-max-skill ui-ux-pro-max
shadcn/ui shadcn
heygen-com/hyperframes hyperframes
remotion-dev/skills remotion-best-practices
coreyhaines31/marketingskills seo-audit
supabase/agent-skills supabase-postgres-best-practices
obra/superpowers subagent-driven-development
obra/superpowers dispatching-parallel-agents
trailofbits/skills semgrep
trailofbits/skills sharp-edges
trailofbits/skills supply-chain-risk-auditor
trailofbits/skills differential-review
LISTE
)

lauf() {
  # 1) Fetch the latest list from the repo, otherwise use the fallback list
  local liste=""
  if timeout 30 git clone -q --depth 1 https://github.com/MoinMornhart/claude-skills "$ARBEIT/claude-skills" 2>/dev/null \
     && [[ -f "$ARBEIT/claude-skills/skills-auswahl.txt" ]]; then
    liste="$(cat "$ARBEIT/claude-skills/skills-auswahl.txt")"
  else
    liste="$ERSATZ"
  fi

  # 2) Collect missing skills, grouped by source repo
  declare -A fehlt=()
  while read -r repo skill _; do
    [[ -z "${repo:-}" || "$repo" == \#* || -z "${skill:-}" ]] && continue
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$skill" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    [[ -f "$ZIEL/$skill/SKILL.md" ]] && continue
    fehlt[$repo]+="$skill "
  done <<< "$liste"
  [[ ${#fehlt[@]} -eq 0 ]] && return 0

  # 3) Clone each source repo once (shallow) and copy the skill folders
  local fehler=""
  for repo in "${!fehlt[@]}"; do
    local d="$ARBEIT/src/${repo//\//_}"
    if ! timeout 120 git clone -q --depth 1 "https://github.com/$repo" "$d" 2>/dev/null; then
      fehler+=" ${fehlt[$repo]}"; continue
    fi
    for skill in ${fehlt[$repo]}; do
      local quelle=""
      # Look for a folder with the same name and SKILL.md (skills/<name>, .claude/skills/<name>, <name>, ...)
      quelle="$(find "$d" -type f -name SKILL.md -path "*/$skill/SKILL.md" -not -path '*/node_modules/*' 2>/dev/null | awk '{print length, $0}' | sort -n | head -1 | cut -d' ' -f2-)"
      # otherwise via "name:" in the header
      if [[ -z "$quelle" ]]; then
        quelle="$(grep -rlE --include=SKILL.md "^name:[[:space:]]*['\"]?$skill['\"]?[[:space:]]*$" "$d" 2>/dev/null | head -1)"
      fi
      # Repo has only one skill in the root folder
      if [[ -z "$quelle" && -f "$d/SKILL.md" ]]; then quelle="$d/SKILL.md"; fi
      if [[ -n "$quelle" ]]; then
        rm -rf "$ZIEL/$skill" && mkdir -p "$ZIEL/$skill" \
          && cp -r "$(dirname "$quelle")/." "$ZIEL/$skill/" && rm -rf "$ZIEL/$skill/.git"
      elif command -v npx >/dev/null && timeout 120 npx -y skills add "https://github.com/$repo" --skill "$skill" -a claude-code -g -y >/dev/null 2>&1; then
        :
      else
        fehler+=" $skill"
      fi
    done
  done
  if [[ -n "$fehler" ]]; then
    echo "$(date '+%F %T') failed:$fehler" >> "$LOG"
  else
    echo "$(date '+%F %T') ok" >> "$LOG"
  fi
}

if [[ "${1:-}" == "--vordergrund" || "${1:-}" == "--force" ]]; then
  lauf; rm -rf "$ARBEIT"
else
  # In the background so the session starts immediately
  ( lauf; rm -rf "$ARBEIT" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0

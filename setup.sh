#!/usr/bin/env bash
# RayBan Claude – Setup on macOS and Linux (Windows: setup.cmd)
set -euo pipefail
cd "$(dirname "$0")"
PORT="${RAYBANCLAUDE_PORT:-18790}"

orange=$'\033[38;5;208m'; green=$'\033[32m'; yellow=$'\033[33m'; gray=$'\033[90m'; reset=$'\033[0m'
step() { printf '\n%s▸ %s%s\n' "$orange" "$1" "$reset"; }
ok()   { printf '  %s✓ %s%s\n' "$green" "$1" "$reset"; }
warn() { printf '  %s! %s%s\n' "$yellow" "$1" "$reset"; }
ask()  { read -r -p "  $1 (y/n) " a; [[ "$a" =~ ^(j|ja|y|yes)$ ]]; }
has()  { command -v "$1" >/dev/null 2>&1; }

printf '\n  %s◉ RayBan Claude – Setup%s\n' "$orange" "$reset"
printf '  %sUnofficial open-source project – not affiliated with Meta, Ray-Ban or Anthropic.%s\n' "$gray" "$reset"

step "Checking Bun"
if ! has bun; then
  warn "Bun is not installed (free, https://bun.sh)."
  if ask "Install Bun with the official installer?"; then
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
  else
    warn "The channel does not run without Bun."; exit 1
  fi
fi
ok "Bun $(bun --version)"

step "Checking Claude Code"
if ! has claude; then
  warn "Claude Code is not installed."
  if ask "Install Claude Code with the official installer?"; then
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
has claude && ok "Claude Code $(claude --version)"

step "Installing channel dependencies"
(cd channel && bun install --frozen-lockfile && bun audit)
ok "Channel ready"

step "Gateway mode (optional, your own Anthropic API key)"
if has npm && ask "Set up the gateway server?"; then
  (cd server && npm ci && npm run build && npm audit --audit-level=high)
  [[ -f server/.env ]] || { cp server/.env.example server/.env; warn "server/.env created – add your ANTHROPIC_API_KEY."; }
  ok "Gateway built (start: cd server && npm start)"
fi

if [[ "$(uname)" == "Darwin" ]]; then
  step "iOS app (Mac with Xcode only)"
  if has xcodegen || { has brew && ask "Install XcodeGen via Homebrew?" && brew install xcodegen; }; then
    (cd ios && xcodegen generate)
    ok "Xcode project generated: ios/RayBanClaude.xcodeproj (choose your team under Signing & Capabilities)"
  else
    warn "Without a Mac/Xcode: use the prebuilt IPA from GitHub Actions – see docs/IPHONE-OHNE-MAC.md"
  fi
fi

printf '\n  %s✅ Done!%s\n' "$green" "$reset"
echo "   1. ./start.sh  – starts Claude Code with RayBan Claude"
echo "   2. Dashboard: http://localhost:$PORT – scan the QR code with the iPhone camera"
echo "   3. On the go (optional): Tailscale on PC and iPhone – the address is then included in the QR code automatically"
echo

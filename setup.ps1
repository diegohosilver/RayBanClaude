<#
  RayBan Claude – Setup on Windows
  Run:       double-click setup.cmd (or use the Windows installer RayBanClaude-Setup.exe)
  or:        powershell -ExecutionPolicy Bypass -File .\setup.ps1

  -Unattended: no prompts (for the installer) – installs Bun and Claude Code if needed
  with the official installers, skips the optional gateway; the installer sets up the
  firewall itself.
#>
param([switch]$Unattended)
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot
$Port = 18790

function Write-Step($text) { Write-Host "`n▸ $text" -ForegroundColor DarkYellow }
function Write-Ok($text)   { Write-Host "  ✓ $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  ! $text" -ForegroundColor Yellow }
function Ask($question, [bool]$UnattendedAnswer = $true) {
    if ($Unattended) { return $UnattendedAnswer }
    (Read-Host "  $question (y/n)") -match '^(j|ja|y|yes)$'
}
function Test-Command($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function Test-Rule($name) { [bool](Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) }

# Find freshly installed tools right away (the installer still inherits the old PATH)
$env:Path = "$env:USERPROFILE\.bun\bin;$env:USERPROFILE\.local\bin;$env:Path"

try {
    Write-Host ""
    Write-Host "  ◉ RayBan Claude – Setup" -ForegroundColor DarkYellow
    Write-Host "    Claude sees what you see (Ray-Ban Meta Gen 2 & iPhone)" -ForegroundColor Gray
    Write-Host "    Unofficial open-source project – not affiliated with Meta, Ray-Ban or Anthropic." -ForegroundColor DarkGray

    # ── 1. Bun (runs the channel server) ─────────────────────────────────────
    Write-Step "Checking Bun"
    if (-not (Test-Command 'bun')) {
        Write-Warn "Bun is not installed (free, https://bun.sh)."
        if (Ask "Install Bun now with the official installer?") {
            powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://bun.sh/install.ps1 | iex"
        } else {
            Write-Warn "The channel does not run without Bun. Install later: irm https://bun.sh/install.ps1 | iex"
            exit 1
        }
    }
    if (-not (Test-Command 'bun')) { throw "Bun was not found – please run setup.cmd again." }
    Write-Ok "Bun $(bun --version)"

    # ── 2. Claude Code ───────────────────────────────────────────────────────
    Write-Step "Checking Claude Code"
    if (-not (Test-Command 'claude')) {
        Write-Warn "Claude Code is not installed."
        if (Ask "Install Claude Code now with the official installer?") {
            powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://claude.ai/install.ps1 | iex"
        } else {
            Write-Warn "Install later: https://claude.com/claude-code"
        }
    }
    if (Test-Command 'claude') { Write-Ok "Claude Code $(claude --version)" }

    # ── 3. Channel dependencies ──────────────────────────────────────────────
    Write-Step "Installing channel dependencies"
    Push-Location channel
    bun install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) { throw "bun install failed (internet connection?)" }
    bun audit
    Pop-Location
    Write-Ok "Channel ready"

    # ── 4. Link with the Claude desktop app ───────────────────────────────────
    # Claude in your regular chats can then read the glasses history and pass knowledge to the glasses.
    Write-Step "Linking with the Claude app"
    Write-Host "  You can then say things like this in your Claude chats: “What did I ask through the glasses today?”" -ForegroundColor Gray
    Write-Host "  or “Transfer what you know about me to the glasses.”" -ForegroundColor Gray
    if (Ask "Link with the Claude desktop app on this PC?") {
        bun channel\link-desktop.ts
    }

    # ── 5. Optional: gateway mode (your own Anthropic API key, billed per request) ──
    if (Test-Path server) {
        Write-Step "Gateway mode (optional)"
        Write-Host "  Only needed if you want to work WITHOUT Claude Code, using your own API key." -ForegroundColor Gray
        if ((Test-Command 'npm') -and (Ask "Set up the gateway server?" $false)) {
            Push-Location server
            npm ci
            npm run build
            npm audit --audit-level=high
            if (-not (Test-Path .env)) {
                Copy-Item .env.example .env
                Write-Warn "server\.env created – enter your ANTHROPIC_API_KEY there."
            }
            Pop-Location
            Write-Ok "Gateway built (start: cd server; npm start)"
        }
    }

    # ── 6. Windows firewall: the iPhone must be able to reach the PC (Wi-Fi and, if present, Tailscale) ──
    if (-not $Unattended) {
        Write-Step "Windows firewall"
        $hasTailscale = [bool](Get-NetAdapter -Name 'Tailscale' -ErrorAction SilentlyContinue)
        $missing = (-not (Test-Rule 'RayBan Claude')) -or ($hasTailscale -and -not (Test-Rule 'RayBan Claude (Tailscale)'))
        if (-not $missing) {
            Write-Ok "Firewall rules in place"
        } else {
            Write-Host "  For the iPhone to reach the PC, port $Port must be open on the PRIVATE network" -ForegroundColor Gray
            Write-Host "  (and – if installed – for your Tailscale devices)." -ForegroundColor Gray
            if (Ask "Open it now? Windows will ask for administrator rights.") {
                Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\firewall.ps1`"", '-Port', $Port)
            } else {
                Write-Warn "Alternatively, answer the Windows prompt for 'Private networks' with 'Allow' on first launch."
            }
        }
        if (-not $hasTailscale) {
            Write-Host "  On the go via your Claude subscription? Install Tailscale (free) on PC and iPhone" -ForegroundColor Gray
            Write-Host "  (https://tailscale.com/download) and run setup.cmd again." -ForegroundColor Gray
        }
    }

    $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' }
    if ($profiles) {
        Write-Warn "Your Wi-Fi is classified as 'Public' – Windows then blocks the iPhone."
        Write-Host "    Settings → Network & Internet → Wi-Fi → Network profile: Private" -ForegroundColor Cyan
    }

    # ── Done ─────────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ✅ Done! Here's what's next:" -ForegroundColor Green
    Write-Host "   1. Start 'RayBan Claude' (desktop icon or start.cmd)"
    Write-Host "      The first time: sign in to Claude, confirm 'Use this MCP server' and"
    Write-Host "      'I am using this for local development'."
    Write-Host "   2. The dashboard opens: http://localhost:$Port"
    Write-Host "   3. Install the iPhone app: docs\IPHONE-OHNE-MAC.md (free, with Sideloadly)"
    Write-Host "   4. Scan the QR code in the dashboard with the iPhone camera – done."
    Write-Host "   5. On the go: with Tailscale the remote address is included in the QR code automatically."
    Write-Host ""
    if ($Unattended) { Start-Sleep -Seconds 3 }
} catch {
    Write-Host ""
    Write-Host "  ✗ Setup aborted: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    Tip: check your internet connection and run 'RayBan Claude – Setup' again." -ForegroundColor Gray
    if ($Unattended) { Read-Host "  Press Enter to close" | Out-Null }
    exit 1
}

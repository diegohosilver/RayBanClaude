<#
  Start RayBan Claude: Claude Code with the channel + dashboard in the browser.
  Normally just double-click start.cmd.

  Claude picks up where you left off last time (claude --continue) –
  so it still knows what you talked about through the glasses. -Neu starts fresh.
#>
param([switch]$Neu)
Set-Location -Path $PSScriptRoot
# Find freshly installed tools even if Windows has not reloaded the PATH yet
$env:Path = "$env:USERPROFILE\.bun\bin;$env:USERPROFILE\.local\bin;$env:Path"
$Port = if ($env:RAYBANCLAUDE_PORT) { $env:RAYBANCLAUDE_PORT } else { 18790 }

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "Claude Code is missing – please run setup.ps1 first." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
if (-not (Test-Path "channel\node_modules")) {
    Write-Host "Dependencies are missing – please run setup.ps1 first." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Open the dashboard as soon as the channel is running (Claude Code starts it a few seconds after launch)
Start-Job -ArgumentList $Port -ScriptBlock {
    param($Port)
    for ($i = 0; $i -lt 90; $i++) {
        try {
            Invoke-WebRequest -Uri "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 2 | Out-Null
            Start-Process "http://localhost:$Port"
            return
        } catch { Start-Sleep -Seconds 1 }
    }
} | Out-Null

Write-Host "◉ RayBan Claude is starting … the dashboard will open in your browser shortly." -ForegroundColor DarkYellow
Write-Host "  Replies, photos, phone actions and memory are pre-approved; you approve other tools on your phone." -ForegroundColor Gray

# Earlier glasses session in this folder? Then continue there (Claude Code stores it under ~/.claude/projects)
$sessionDir = Join-Path $env:USERPROFILE (".claude\projects\" + ($PSScriptRoot -replace '[^A-Za-z0-9]', '-'))
$resume = @()
if (-not $Neu -and (Test-Path (Join-Path $sessionDir '*.jsonl'))) {
    $resume = @('--continue')
    Write-Host "  Resuming the last conversation (new conversation: Start menu → RayBan Claude → New conversation, or start.cmd -Neu)." -ForegroundColor Gray
}

# Only RayBan Claude's own tools are pre-approved – everything else still asks
# (on request, right on the phone via permission relay). Calls, messages and navigation
# are always confirmed by the user on the iPhone anyway.
claude @resume --dangerously-load-development-channels server:raybanclaude `
    --allowedTools "mcp__raybanclaude__reply" "mcp__raybanclaude__edit_message" "mcp__raybanclaude__request_photo" `
    "mcp__raybanclaude__phone_action" "mcp__raybanclaude__remember" "mcp__raybanclaude__forget"

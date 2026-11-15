<#
  RayBan Claude – open the Windows firewall (needs administrator rights)

  Opens port 18790 ONLY on the private network (home Wi-Fi) and – if Tailscale is installed –
  ONLY on the Tailscale adapter for devices from your own tailnet (100.64.0.0/10).
  With -Remove both rules are removed again (uninstall).
#>
param(
    [switch]$Remove,
    [int]$Port = 18790
)
$ErrorActionPreference = 'Stop'
$Lan = 'RayBan Claude'
$Tailnet = 'RayBan Claude (Tailscale)'

function Test-Rule($name) { [bool](Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) }

try {
    if ($Remove) {
        foreach ($name in @($Lan, $Tailnet)) {
            if (Test-Rule $name) { Remove-NetFirewallRule -DisplayName $name }
        }
        Write-Host "  ✓ RayBan Claude firewall rules removed" -ForegroundColor Green
        exit 0
    }
    if (-not (Test-Rule $Lan)) {
        New-NetFirewallRule -DisplayName $Lan -Direction Inbound -Protocol TCP -LocalPort $Port -Profile Private -Action Allow | Out-Null
    }
    Write-Host "  ✓ Home Wi-Fi: port $Port open on the private network" -ForegroundColor Green
    if (Get-NetAdapter -Name 'Tailscale' -ErrorAction SilentlyContinue) {
        if (-not (Test-Rule $Tailnet)) {
            New-NetFirewallRule -DisplayName $Tailnet -Direction Inbound -Protocol TCP -LocalPort $Port `
                -InterfaceAlias 'Tailscale' -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null
        }
        Write-Host "  ✓ On the go: port $Port open for your Tailscale devices" -ForegroundColor Green
    }
} catch {
    Write-Host "  ! Could not set up the firewall: $($_.Exception.Message)" -ForegroundColor Yellow
    Start-Sleep -Seconds 6
    exit 1
}

#requires -Version 5.1
<#
.SYNOPSIS
  Operator CLI for the Windows tunnel-monitor (reads state.json beside this script).

.USAGE
  tunnel-check.ps1
  tunnel-check.ps1 -Action CheckNow

.NOTES
  Default install: C:\ProgramData\tunnel-monitor\
#>

param(
    [ValidateSet("Status", "CheckNow", "TestEmail", "TestNotify", "Reset", "Tail", "History", "SshTest", "TaskStatus")]
    [string]$Action = "Status"
)

$InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $InstallDir "state.json"
$LogPath = Join-Path $InstallDir "monitor.log"
$MonitorPs1 = Join-Path $InstallDir "monitor.ps1"

$TaskName = "TunnelMonitorLanClient"

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning "Elevation required. Re-run PowerShell as Administrator."
        exit 2
    }
}

function Show-StatusPretty {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        Write-Host "state.json missing — run the scheduled task or Install.ps1"
        exit 0
    }
    try {
        $o = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Host "state.json unreadable"
        exit 1
    }
    Write-Host "Tunnel Monitor (Windows)"
    Write-Host "--------------------------"
    Write-Host (" Diagnosis:       {0}" -f $o.diagnosis)
    Write-Host (" Alert state:    {0}" -f $o.alert_state)
    Write-Host (" Failure count: {0}" -f $o.failure_count)
    Write-Host (" Last check:    {0}" -f $o.timestamp)
    Write-Host ""
    Write-Host "Checks:"
    Write-Host ("  Tunnel       {0}: {1} lat={2}" -f $o.checks.tunnel.target, $o.checks.tunnel.ok, $o.checks.tunnel.latency_ms)
    Write-Host ("  Remote WAN   {0}: {1} lat={2}" -f $o.checks.remote_wan.target, $o.checks.remote_wan.ok, $o.checks.remote_wan.latency_ms)
    Write-Host ("  Our internet {0}: {1} lat={2}" -f $o.checks.our_internet.target, $o.checks.our_internet.ok, $o.checks.our_internet.latency_ms)
    Write-Host ("  DNS {0} -> {1} match={2}" -f $o.checks.dns.host, $o.checks.dns.resolved, $o.checks.dns.match)
    Write-Host ""
    Write-Host "ROUTER dedup:"
    Write-Host ("  Reachable: {0}" -f $o.router_dedup.reachable)
    Write-Host ("  State: {0}" -f $o.router_dedup.state)
    Write-Host ("  Checked:   {0}" -f $o.router_dedup.checked_at)
}

switch ($Action) {
    "Status" { Show-StatusPretty; break }
    "CheckNow" {
        Assert-Admin
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Host "Task started."
        break
    }
    "TestEmail" {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MonitorPs1 email-test
        exit $LASTEXITCODE
    }
    "TestNotify" {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MonitorPs1 notify-test
        Write-Host "`nstub only — Notify-Stub.ps1 logs NOTIFY_SKIPPED"
        break
    }
    "Reset" {
        Assert-Admin
        if (Test-Path $StatePath) {
            Copy-Item $StatePath ($StatePath + ".bak." + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Force
        }
        $now = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
        $fresh = @{
            timestamp           = $now
            alert_state         = "UP"
            failure_count       = 0
            checks              = @{
                tunnel         = @{ target = $null; ok = $null; latency_ms = $null }
                remote_wan     = @{ target = $null; ok = $null; latency_ms = $null }
                our_internet   = @{ target = $null; ok = $null; latency_ms = $null }
                dns            = @{ host = $null; resolved = $null; expected = $null; match = $null }
            }
            router_dedup        = @{ reachable = $false; state = $null; checked_at = $now }
            last_alert_sent_at  = $null
            last_recovery_sent_at = $null
            diagnosis           = "RESET"
        }
        $json = ConvertTo-Json -Depth 15 $fresh
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText("$StatePath.tmp", $json + "`r`n", $utf8)
        Move-Item -LiteralPath "$StatePath.tmp" -Destination $StatePath -Force
        Write-Host "state reset."
        break
    }
    "Tail" {
        Get-Content -LiteralPath $LogPath -Wait -Tail 20
        break
    }
    "History" {
        Get-Content -LiteralPath $LogPath -Tail 50
        break
    }
    "SshTest" {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MonitorPs1 ssh-test
        exit $LASTEXITCODE
    }
    "TaskStatus" {
        Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue | Format-List
        Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Format-List
        break
    }
}

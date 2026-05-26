#requires -Version 5.1
<#
.SYNOPSIS
  Removes the Windows tunnel-monitor scheduled task and optionally ProgramData files.

.USAGE
  Run elevated:
    powershell -ExecutionPolicy Bypass -File Uninstall.ps1
    powershell -ExecutionPolicy Bypass -File Uninstall.ps1 -RemoveData

.PARAMETER RemoveData
  Delete C:\ProgramData\tunnel-monitor\ entirely (config.env, SSH keys, logs, state).
#>
param(
    [switch]$Help,
    [switch]$RemoveData
)

$TaskName = "TunnelMonitorLanClient"
$InstallDir = Join-Path $env:ProgramData "tunnel-monitor"

function Show-TmUninstallHelp {
    Write-Host @"
Uninstall.ps1 — remove scheduled task and optional data

USAGE (Administrator shell):
  powershell -ExecutionPolicy Bypass -File Uninstall.ps1 [-RemoveData] [-Help]
"@
}

if ($Help -or ($args | Where-Object { $_ -in @("--help", "-h", "/h", "-?", "/?" )})) {
    Show-TmUninstallHelp
    exit 0
}

$newId = [Security.Principal.WindowsIdentity]::GetCurrent()
$wp = New-Object Security.Principal.WindowsPrincipal $newId
if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run as Administrator." -ErrorCategory PermissionDenied
}

schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
Write-Host "Scheduled task $($TaskName) removed (if it existed)."

if ($RemoveData) {
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
        Write-Host "Removed $($InstallDir)"
    }
    else {
        Write-Host "Install directory not present — nothing to delete."
    }
}
else {
    Write-Host @"
Software files remain at $($InstallDir)
Re-run with -RemoveData to delete config, SSH keys, state, and logs.
"@
}

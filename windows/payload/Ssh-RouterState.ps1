#requires -Version 5.1
<#
.SYNOPSIS
  Prints router state line (N:UP / N:DOWN) to stdout via ssh.exe.

.PARAMETER ConfigPath
  Path to config.env

.EXIT
  0 ok, 1 failure, 2 config
#>
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-ConfigEnv {
    param([string]$Path)
    $cfg = @{}
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#")) { return }
        if ($line -notmatch "^([A-Za-z0-9_]+)=") { return }
        $key = $Matches[1]
        $rest = $line.Substring($key.Length + 1)
        if ($rest.StartsWith('"') -and $rest.EndsWith('"')) {
            $cfg[$key] = $rest.Substring(1, $rest.Length - 2)
        }
        elseif ($rest.StartsWith("'") -and $rest.EndsWith("'")) {
            $cfg[$key] = $rest.Substring(1, $rest.Length - 2)
        }
        else {
            $cfg[$key] = $rest
        }
    }
    return $cfg
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "config missing: $ConfigPath"
    exit 2
}

$c = Read-ConfigEnv -Path $ConfigPath
$h = if ($c.ContainsKey("ROUTER_HOST")) { $c["ROUTER_HOST"] } else { "192.0.2.254" }
$u = if ($c.ContainsKey("ROUTER_USER")) { $c["ROUTER_USER"] } else { "root" }
$key = if ($c.ContainsKey("ROUTER_KEY")) { $c["ROUTER_KEY"] } else { "$env:ProgramData\tunnel-monitor\.ssh\id_ed25519" }
$statePath = if ($c.ContainsKey("ROUTER_STATE_PATH")) { $c["ROUTER_STATE_PATH"] } else { "/data/tunnel-monitor/state" }

if (-not (Test-Path -LiteralPath $key)) {
    Write-Error "SSH key missing: $key"
    exit 2
}

$known = Join-Path (Split-Path -Parent $key) "known_hosts"
if (-not (Test-Path -LiteralPath (Split-Path -Parent $known))) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $known) -Force | Out-Null
}

$ssh = "ssh.exe"
if (-not (Get-Command $ssh -ErrorAction SilentlyContinue)) {
    Write-Error "ssh.exe not found (install OpenSSH Client optional feature)"
    exit 2
}

$remoteCmd = "cat $statePath 2>/dev/null"
$args = @(
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=3",
    "-o", "ServerAliveCountMax=2",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=$known",
    "-i", $key,
    "${u}@${h}",
    $remoteCmd
)

try {
    $out = & $ssh @args 2>$null
}
catch {
    Write-Error "ssh failed"
    exit 1
}

$line = @($out | ForEach-Object { "${_}" } | Where-Object { $_ } ) | Select-Object -Last 1
$line = ([string]$line).Trim() -replace "[\r\n]+", ""
if ([string]::IsNullOrWhiteSpace($line)) {
    Write-Error "empty router state"
    exit 1
}
if ($line -notmatch "^[0-9]+:(UP|DOWN)$") {
    Write-Error "malformed state: $line"
    exit 1
}
Write-Output $line
exit 0

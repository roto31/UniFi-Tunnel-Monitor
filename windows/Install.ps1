#requires -Version 5.1
<#
.SYNOPSIS
  Installs Tunnel Monitor LAN client onto this Windows machine (scheduled task).

.DESCRIPTION
  Copies payload\* to "%ProgramData%\tunnel-monitor\", creates SSH key material,
  initializes config.env from the template once, registers a SYSTEM scheduled
  task firing every five minutes running monitor.ps1 check.

  Desktop toasts from SYSTEM are not implemented; Notify-Stub.ps1 logs only.

.USAGE
  Run elevated (Administrator):
    powershell -ExecutionPolicy Bypass -File Install.ps1
    powershell -ExecutionPolicy Bypass -File Install.ps1 -SkipRouterKeyProvision

.PARAMETER Help
  Show this help text (no admin required).

.PARAMETER SkipRouterKeyProvision
  Do not probe or push ~/.ssh authorized_keys on ROUTER_HOST (use when onboarding later).

.PARAMETER SkipSchTasks
  Copy files only; skip schtasks registration (manual testing).

.PARAMETER SkipAutoStartTask
  After registering the task, do not kick an immediate sample run via Start-ScheduledTask.
#>
param(
    [switch]$Help,
    [switch]$SkipRouterKeyProvision,
    [switch]$SkipSchTasks,
    [switch]$SkipAutoStartTask
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Show-TmInstallHelp {
    Write-Host @"
Install.ps1 — Windows tunnel-monitor installer

USAGE (Administrator shell):
  powershell -ExecutionPolicy Bypass -File Install.ps1 [--help|-h|-?]

OPTIONS
  -SkipRouterKeyProvision  Skip pushing SSH pubkey to ROUTER_HOST
  -SkipSchTasks            Skip schtasks registration
  -SkipAutoStartTask       Do not trigger the task once after install
"@
}

if ($Help -or ($args | Where-Object { $_ -in @("--help", "-h", "/h", "-?", "/?" )})) {
    Show-TmInstallHelp
    exit 0
}

$PayloadDir = Join-Path $ScriptRoot "payload"
$InstallDir = Join-Path $env:ProgramData "tunnel-monitor"
$SshDir = Join-Path $InstallDir ".ssh"
$SshKey = Join-Path $SshDir "id_ed25519"
$SshPub = "${SshKey}.pub"

$newId = [Security.Principal.WindowsIdentity]::GetCurrent()
$wp = New-Object Security.Principal.WindowsPrincipal $newId
if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run as Administrator." -ErrorCategory PermissionDenied -ErrorAction Stop
}

$TaskName = "TunnelMonitorLanClient"

function Ensure-PayloadTm {
    $need = @(
        "monitor.ps1",
        "Send-Email.ps1",
        "Notify-Stub.ps1",
        "Ssh-RouterState.ps1",
        "tunnel-check.ps1",
        "config.env.template"
    )
    foreach ($f in $need) {
        $p = Join-Path $PayloadDir $f
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Error "Missing payload file: $p"
        }
    }
}

function Read-MinimalEnvTm {
    param([string]$Path)
    $cfg = @{}
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#")) { return }
        if ($line -notmatch '^([A-Za-z0-9_]+)=(.*)$') { return }
        $k = $Matches[1]
        $rest = $Matches[2]
        if (($rest.StartsWith('"') -and $rest.EndsWith('"')) -or ($rest.StartsWith("'") -and $rest.EndsWith("'"))) {
            $cfg[$k] = $rest.Substring(1, $rest.Length - 2)
        }
        else {
            $cfg[$k] = $rest.Trim('"')
        }
    }
    $cfg
}

function Invoke-RouterProvisionTm {
    param(
        [string]$RouterHost,
        [string]$RouterUser,
        [string]$SshExe,
        [string]$KhFile,
        [string]$PrivKeyPath,
        [string]$PubKeyPath
    )
    if (($RouterHost -eq "REPLACE_WITH_ROUTER_LAN_IP") -or [string]::IsNullOrWhiteSpace($RouterHost)) {
        Write-Warning "ROUTER_HOST is still a placeholder — skip router SSH pubkey push."
        return
    }

    function Test-RouterPingTm {
        & $SshExe -o BatchMode=yes -o ConnectTimeout=5 `
            -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KhFile" `
            -i "$PrivKeyPath" "${RouterUser}@${RouterHost}" "echo OK" 2>$null
        ($LASTEXITCODE -eq 0)
    }

    if (Test-RouterPingTm) {
        Write-Host "SSH batch auth already works for ${RouterUser}@${RouterHost}."
        return
    }

    Write-Host "Pushing SSH public key (router login password prompted once):"
    Get-Content -LiteralPath $PubKeyPath -Raw | & $SshExe -o StrictHostKeyChecking=accept-new `
        -o UserKnownHostsFile="$KhFile" "${RouterUser}@${RouterHost}" `
        "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to authorize SSH key."
    }

    if (-not (Test-RouterPingTm)) {
        Write-Error "Key pushed but BatchMode SSH still failing."
    }
    Write-Host "Router SSH authorization OK."
}

Ensure-PayloadTm

if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    Write-Error "ssh.exe not found. Install OpenSSH Client (Windows optional feature)." -ErrorCategory ObjectNotFound
}

if (-not (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue)) {
    Write-Error "ssh-keygen.exe not found (part of OpenSSH Client)." -ErrorCategory ObjectNotFound
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Get-ChildItem -LiteralPath $PayloadDir -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $InstallDir $_.Name) -Force
}

$template = Join-Path $InstallDir "config.env.template"
$cfgPath = Join-Path $InstallDir "config.env"

if (-not (Test-Path -LiteralPath $cfgPath)) {
    Copy-Item -LiteralPath $template -Destination $cfgPath -Force
    Write-Warning "Wrote starter config.env from template — edit SMTP_PASSWORD before alerting."
}

$statePath = Join-Path $InstallDir "state.json"

if (-not (Test-Path -LiteralPath $statePath)) {
    $now = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
    $fresh = @{ timestamp = $now; alert_state = "UP"; failure_count = 0; checks = @{
            tunnel       = @{ target = $null; ok = $null; latency_ms = $null }; remote_wan = @{ target = $null; ok = $null; latency_ms = $null }; our_internet = @{ target = $null; ok = $null; latency_ms = $null }; dns = @{ host = $null; resolved = $null; expected = $null; match = $null }
        }; router_dedup = @{ reachable = $false; state = $null; checked_at = $now }; last_alert_sent_at = $null; last_recovery_sent_at = $null; diagnosis = "PENDING_FIRST_RUN"
    }
    $json = ConvertTo-Json -Depth 15 $fresh -Compress:$false
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText("${statePath}.tmp", $json + "`r`n", $utf8)
    Move-Item -LiteralPath "${statePath}.tmp" -Destination $statePath -Force
}

$tlog = Join-Path $InstallDir "monitor.log"

if (-not (Test-Path -LiteralPath $tlog)) {
    New-Item -ItemType File -Path $tlog -Force | Out-Null
}

New-Item -ItemType Directory -Path $SshDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $SshKey)) {
    Write-Host "Generating ed25519 key for tunnel-monitor..."
    $proc = Start-Process -FilePath (Get-Command ssh-keygen.exe).Source `
        -ArgumentList @("-t", "ed25519", "-f", "$SshKey", "-N", "", "-q", "-C", "tunnel-monitor@$env:COMPUTERNAME") `
        -Wait -NoNewWindow -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Error "ssh-keygen failed with exit $($proc.ExitCode)"
    }
}

$khPath = Join-Path $SshDir "known_hosts"
if (-not (Test-Path -LiteralPath $khPath)) {
    New-Item -ItemType File -Path $khPath -Force | Out-Null
}

$configMap = Read-MinimalEnvTm -Path $cfgPath
$rHost = if ($configMap["ROUTER_HOST"]) { [string]$configMap["ROUTER_HOST"] } else { "REPLACE_WITH_ROUTER_LAN_IP" }
$rUser = if ($configMap["ROUTER_USER"]) { [string]$configMap["ROUTER_USER"] } else { "root" }

$SshExe = (Get-Command ssh.exe).Source

if (-not $SkipRouterKeyProvision) {
    Invoke-RouterProvisionTm -RouterHost $rHost -RouterUser $rUser -SshExe $SshExe `
        -KhFile $khPath -PrivKeyPath $SshKey -PubKeyPath $SshPub
}

if (-not $SkipSchTasks) {
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $monPs1 = Join-Path $InstallDir "monitor.ps1"
    $execLine = '"' + $psExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $monPs1 + '" check'
    schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null

    schtasks.exe /Create /F /TN $TaskName /TR $execLine /SC MINUTE /MO 5 /RU SYSTEM

    if (-not $SkipAutoStartTask) {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
}

Write-Host @"

Install finished.
Next:
  Edit:   $($cfgPath)
  Test:   powershell -File $(Join-Path $InstallDir tunnel-check.ps1) -Action TestEmail
          powershell $(Join-Path $ScriptRoot Verify.ps1)
"@

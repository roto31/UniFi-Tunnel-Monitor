#requires -Version 5.1
<#
.SYNOPSIS
  Post-install sanity checks for the Windows tunnel-monitor.

.USAGE
  powershell -ExecutionPolicy Bypass -File Verify.ps1
#>
param(
    [switch]$Help
)

$TaskName = "TunnelMonitorLanClient"
$InstallDir = Join-Path $env:ProgramData "tunnel-monitor"

function Show-TmVerifyHelp {
    Write-Host @" 
Verify.ps1 — checks TunnelMonitorLanClient task and installed files under ProgramData.

USAGE:
  powershell -ExecutionPolicy Bypass -File Verify.ps1
"@ 
}

if ($Help -or ($args | Where-Object { $_ -in @("--help", "-h", "/h", "-?", "/?" )})) {
    Show-TmVerifyHelp
    exit 0
}

$script:VerifyProblems = New-Object System.Collections.Generic.List[string]

function ComplainTm {
    param([string]$Msg)
    Write-Warning $Msg
    [void]$script:VerifyProblems.Add($Msg)
}

$needScripts = @(
    "monitor.ps1",
    "Send-Email.ps1",
    "Notify-Stub.ps1",
    "Ssh-RouterState.ps1",
    "tunnel-check.ps1",
    "config.env",
    "config.env.template",
    "state.json"
)

foreach ($f in $needScripts) {
    $p = Join-Path $InstallDir $f
    if (-not (Test-Path -LiteralPath $p)) {
        ComplainTm "Missing: $p"
    }
}

$key = Join-Path $InstallDir ".ssh\id_ed25519"

if (-not (Test-Path -LiteralPath $key)) {
    ComplainTm "Missing SSH private key $key — re-run Install.ps1"
}

$snull = schtasks.exe /Query /TN $TaskName 2>$null

if ($LASTEXITCODE -ne 0) {
    ComplainTm "Scheduled task '$TaskName' not found — Install.ps1 not run or Uninstall.ps1 cleared it."
}

try {
    $raw = Get-Content -LiteralPath (Join-Path $InstallDir "state.json") -Raw -Encoding UTF8
    [void]($raw | ConvertFrom-Json -ErrorAction Stop)
}
catch {
    ComplainTm ("state.json is not valid JSON: " + $_.Exception.Message)
}

foreach ($c in @("ssh.exe", "curl.exe")) {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        ComplainTm "Missing $c in PATH."
    }
}

$cfgTxt = ""
try {
    $cfgTxt = Get-Content -LiteralPath (Join-Path $InstallDir "config.env") -Raw -Encoding UTF8 -ErrorAction Stop
}
catch {
    ComplainTm "Unable to read config.env"
}

if ($cfgTxt -match "REPLACE_WITH_") {
    ComplainTm "config.env still contains REPLACE_WITH_* placeholders — edit before production use."
}

if ($script:VerifyProblems.Count -eq 0) {
    Write-Host "verify.sh equivalent: PASS"
}

if ($script:VerifyProblems.Count -gt 0) {
    exit 1
}

exit 0

#requires -Version 5.1
<#
.SYNOPSIS
  Authenticated SMTP submission via curl.exe (STARTTLS, port 587).

.PARAMETER SubjectRaw
  Subject before SUBJECT_PREFIX is prepended.

.PARAMETER BodyPath
  Path to UTF-8/plain body file.

.PARAMETER ConfigPath
  Path to config.env

.EXIT
  0 success, 1 curl/runtime, 2 config, 3 bad args
#>
param(
    [Parameter(Mandatory = $true)][string]$SubjectRaw,
    [Parameter(Mandatory = $true)][string]$BodyPath,
    [Parameter(Mandatory = $true)][string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-Help {
    Write-Host @"
Send-Email.ps1 -SubjectRaw <s> -BodyPath <file> -ConfigPath <config.env>
"@
}

function Read-ConfigEnv {
    param([string]$Path)
    $cfg = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "config missing: $Path"
    }
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

if ($SubjectRaw -eq "--help" -or $SubjectRaw -eq "-h") {
    Show-Help
    exit 0
}

if (-not (Test-Path -LiteralPath $BodyPath)) {
    Write-Error "body file missing: $BodyPath"
    exit 3
}

try {
    $c = Read-ConfigEnv -Path $ConfigPath
}
catch {
    Write-Error $_
    exit 2
}

$smtpServer = if ($c.ContainsKey("SMTP_SERVER")) { $c["SMTP_SERVER"] } else { "smtp.mail.me.com" }
$smtpPort = if ($c.ContainsKey("SMTP_PORT")) { $c["SMTP_PORT"] } else { "587" }
$prefix = if ($c.ContainsKey("SUBJECT_PREFIX")) { $c["SUBJECT_PREFIX"] } else { "[WIN]" }

foreach ($k in @("SMTP_USER", "SMTP_PASSWORD", "ALERT_FROM", "ALERT_TO")) {
    if (-not $c.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($c[$k])) {
        Write-Error "$k not set"
        exit 2
    }
}
if ($c["SMTP_PASSWORD"] -eq "REPLACE_WITH_APP_SPECIFIC_PASSWORD") {
    Write-Error "SMTP_PASSWORD placeholder"
    exit 2
}

$subject = "$prefix $SubjectRaw"
$msgPath = [System.IO.Path]::GetTempFileName()
try {
    $from = $c["ALERT_FROM"]
    $to = $c["ALERT_TO"]
    $user = $c["SMTP_USER"]
    $pass = $c["SMTP_PASSWORD"]
    $body = Get-Content -LiteralPath $BodyPath -Raw
    $crlfBody = ($body -replace "`r`n", "`n") -replace "`n", "`r`n"
    $sb = New-Object System.Text.StringBuilder
    $utc = ([DateTimeOffset]::UtcNow).ToString("r")
    $hostShort = $env:COMPUTERNAME
    $mid = "<$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).$PID@$hostShort>"
    [void]$sb.Append("From: $from`r`n")
    [void]$sb.Append("To: $to`r`n")
    [void]$sb.Append("Subject: $subject`r`n")
    [void]$sb.Append("Date: $utc`r`n")
    [void]$sb.Append("Message-ID: $mid`r`n")
    [void]$sb.Append("MIME-Version: 1.0`r`n")
    [void]$sb.Append("Content-Type: text/plain; charset=UTF-8`r`n")
    [void]$sb.Append("Content-Transfer-Encoding: 8bit`r`n")
    [void]$sb.Append("`r`n")
    [void]$sb.Append($crlfBody)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($msgPath, $sb.ToString(), $enc)

    $curl = "curl.exe"
    if (-not (Get-Command $curl -ErrorAction SilentlyContinue)) {
        Write-Error "curl.exe not found"
        exit 2
    }

    $smtpUrl = "smtp://${smtpServer}:${smtpPort}"
    $argList = @(
        "--silent", "--show-error", "--fail", "--ssl-reqd",
        "--connect-timeout", "10",
        "--max-time", "30",
        "--url", $smtpUrl,
        "--user", "${user}:${pass}",
        "--mail-from", $from,
        "--mail-rcpt", $to,
        "--upload-file", $msgPath
    )
    $p = Start-Process -FilePath $curl -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        exit 1
    }
}
finally {
    Remove-Item -LiteralPath $msgPath -Force -ErrorAction SilentlyContinue
}
exit 0

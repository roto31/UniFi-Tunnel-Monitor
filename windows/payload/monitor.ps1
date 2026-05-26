#requires -Version 5.1
<#
.SYNOPSIS
  Windows LAN-client tunnel monitor (parity with Public/linux and Public/mac scripts).

.USAGE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File monitor.ps1 [check|diagnose|email-test|ssh-test|notify-test]

.NOTES
  The `check` subcommand ALWAYS exits 0 so the Scheduled Task scheduler does not
  mark perpetual failures — errors are logged to monitor.log beside this script.

  Desktop toasts from SYSTEM are not implemented; Notify-Stub.ps1 logs NOTIFY_SKIPPED.
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "diagnose", "email-test", "ssh-test", "notify-test", "help", "--help", "-h")]
    [string]$Subcommand = "check"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "config.env"
$StatePath = Join-Path $ScriptDir "state.json"
$LogPath = Join-Path $ScriptDir "monitor.log"
[int]$script:LogMaxBytes = 1048576
$SendEmailPs1 = Join-Path $ScriptDir "Send-Email.ps1"
$NotifyStubPs1 = Join-Path $ScriptDir "Notify-Stub.ps1"
$SshRouterPs1 = Join-Path $ScriptDir "Ssh-RouterState.ps1"

function Write-TmLog {
    param([string]$Level, [string]$Msg)
    $line = ("[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Msg)
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
    Write-Output $line
}

function Rotate-TmLog {
    if (-not (Test-Path -LiteralPath $LogPath)) { return }
    try {
        if ((Get-Item -LiteralPath $LogPath).Length -gt $script:LogMaxBytes) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + ".1") -Force -ErrorAction SilentlyContinue
            New-Item -ItemType File -Path $LogPath -Force | Out-Null
        }
    }
    catch { }
}

function Read-ConfigEnvTm {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "missing config"
    }
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
            $cfg[$key] = $rest.Trim('"')
        }
    }
    $cfg
}

function Invoke-IcmpPingAvgTm {
    param([string]$HostName, [int]$Count, [int]$TimeoutSec)
    $ping = New-Object System.Net.NetworkInformation.Ping
    $deadlineMs = [int]([Math]::Min(2147483647, $TimeoutSec * 1000))
    [double[]]$times = @()
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($HostName, $deadlineMs)
            if (($null -ne $r) -and ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)) {
                $times += [double]$r.RoundtripTime
            }
        }
        catch { }
    }
    if ($times.Count -eq 0) {
        return @{ Ok = $false; Latency = $null }
    }
    $avg = (($times | Measure-Object -Average).Average)
    return @{ Ok = $true; Latency = [double]$avg }
}

function Resolve-DdnsATm {
    param([string]$Name)
    $servers = @("1.1.1.1", $null, "8.8.8.8")
    foreach ($srv in $servers) {
        try {
            if ($srv) {
                $list = @(Resolve-DnsName -Name $Name -Type A -DnsOnly -Server $srv -ErrorAction Stop)
            }
            else {
                $list = @(Resolve-DnsName -Name $Name -Type A -ErrorAction Stop)
            }
            foreach ($rec in $list) {
                if ($rec.IPAddress -match '^[0-9]+\.') {
                    return [string]$rec.IPAddress
                }
            }
        }
        catch { }
    }
    return $null
}

function Get-RouterStateLineTm {
    $raw = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SshRouterPs1 -ConfigPath $ConfigPath 2>$null)
    [int]$ec = $LASTEXITCODE
    if (($ec -ne 0) -or ($null -eq $raw) -or ($raw.Count -eq 0)) {
        return @{ Ok = $false; Line = "" }
    }
    [string]$line = [string]$raw[-1]
    if (-not ([string]::IsNullOrWhiteSpace($line))) {
        return @{ Ok = $true; Line = $line.Trim() }
    }
    return @{ Ok = $false; Line = "" }
}

function DiagnoseTm {
    param(
        [bool]$OkOurInternet,
        [bool]$OkTunnel,
        [bool]$RouterReachable,
        [string]$RouterCount,
        [string]$RouterAlertState,
        [bool]$OkDnsMatch,
        [bool]$OkRemoteWan
    )
    if (-not $OkOurInternet) { return "OUR_INTERNET_DOWN" }
    if ($OkTunnel) { return "HEALTHY" }
    if (-not $RouterReachable) { return "ROUTER_UNREACHABLE" }
    if (($RouterAlertState -eq "UP") -and ($RouterCount -eq "0")) { return "DISAGREEMENT" }
    if (-not $OkDnsMatch) { return "DDNS_DRIFT" }
    if (-not $OkRemoteWan) { return "REMOTE_INTERNET_DOWN" }
    return "TUNNEL_DOWN"
}

function Diagnosis-ToSubjectTm {
    param([string]$d)
    switch ($d) {
        "TUNNEL_DOWN" { return "TUNNEL DOWN" }
        "DDNS_DRIFT" { return "DDNS DRIFT - fix DDNS provider" }
        "REMOTE_INTERNET_DOWN" { return "REMOTE INTERNET DOWN" }
        "ROUTER_UNREACHABLE" { return "ROUTER UNREACHABLE" }
        "DISAGREEMENT" { return "DISAGREEMENT (ROUTER says UP)" }
        Default { return $d }
    }
}

function Read-PrevStateTm {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @{ Fail = 0; AlertState = "UP"; LastAlert = $null; LastRecovery = $null }
    }
    try {
        $o = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        return @{
            Fail         = [int]$o.failure_count
            AlertState   = [string]$o.alert_state
            LastAlert    = $o.last_alert_sent_at
            LastRecovery = $o.last_recovery_sent_at
        }
    }
    catch {
        Write-TmLog "WARN" "state.json unparseable; using defaults"
        return @{ Fail = 0; AlertState = "UP"; LastAlert = $null; LastRecovery = $null }
    }
}

function Write-StateJsonTm {
    param($StateObj)
    $tmp = $StatePath + ".tmp"
    $json = ConvertTo-Json -InputObject $StateObj -Depth 20
    $utf8nb = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $json + "`r`n", $utf8nb)
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

# --- bootstrap / deps check for check path ---
function Test-EssentialBins {
    foreach ($exe in @("curl.exe", "ssh.exe")) {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            return $exe
        }
    }
    return $null
}

# --- HELP ---
if (($Subcommand -eq "help") -or ($Subcommand -eq "--help") -or ($Subcommand -eq "-h")) {
    Write-Output @"
monitor.ps1

  check           full health cycle (scheduled task uses this)
  diagnose        prints diagnosis only (no state write)
  email-test      SMTP test via Send-Email.ps1
  ssh-test        ROUTER SSH state read via Ssh-RouterState.ps1
  notify-test     NOTIFY_SKIPPED stub line in monitor.log
"@
    exit 0
}

# notify-test --
if ($Subcommand -eq "notify-test") {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $NotifyStubPs1 -Title "Tunnel TEST" -Message "Synthetic test" -LogPath $LogPath
    exit 0
}

# email-test --
if ($Subcommand -eq "email-test") {
    $tmpBody = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    try {
        @"

Synthetic Windows tunnel-monitor test email.
Computer: $($env:COMPUTERNAME)
Time: $(Get-Date)


"@ | Out-File -LiteralPath $tmpBody -Encoding UTF8 -Force

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SendEmailPs1 `
            -SubjectRaw "TEST tunnel monitor SMTP" -BodyPath $tmpBody -ConfigPath $ConfigPath
        exit $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue
    }
}

# ssh-test --
if ($Subcommand -eq "ssh-test") {
    try {
        $ln = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SshRouterPs1 -ConfigPath $ConfigPath 2>$null) | Select-Object -Last 1
        Write-Output ("OK ROUTER STATE = $ln")
        exit 0
    }
    catch {
        Write-Warning $_
        exit 1
    }
}

function Run-DiagnoseMode {
    $c = Read-ConfigEnvTm -Path $ConfigPath
    $rl = if ($c.ContainsKey("REMOTE_LAN_IP")) { $c["REMOTE_LAN_IP"] } else { "192.0.2.1" }
    $rwip = if ($c.ContainsKey("REMOTE_WAN_IP")) { $c["REMOTE_WAN_IP"] } else { "198.51.100.1" }
    $ddns = if ($c.ContainsKey("REMOTE_DDNS")) { $c["REMOTE_DDNS"] } else { "remote.example.com" }
    [int]$pc = if ($c.ContainsKey("PING_COUNT")) { [int]$c["PING_COUNT"] } else { 3 }
    [int]$pto = if ($c.ContainsKey("PING_TIMEOUT")) { [int]$c["PING_TIMEOUT"] } else { 2 }
    $p1 = Invoke-IcmpPingAvgTm -HostName $rl -Count $pc -TimeoutSec $pto
    $p2 = Invoke-IcmpPingAvgTm -HostName $rwip -Count $pc -TimeoutSec $pto
    $p3 = Invoke-IcmpPingAvgTm -HostName '1.1.1.1' -Count $pc -TimeoutSec $pto
    $dn = Resolve-DdnsATm -Name $ddns
    $OkTunnel = [bool]$p1.Ok
    $OkRw = [bool]$p2.Ok
    $OkOur = [bool]$p3.Ok
    $OkDns = (-not [string]::IsNullOrWhiteSpace($dn)) -and ($dn -eq $rwip)
    $rr = Get-RouterStateLineTm
    $rch = [bool]$rr.Ok
    $RouterCount = ""
    $RouterAlertState = ""
    $lineFull = ""
    if ($rch) {
        $lineFull = ([string]$rr.Line).Trim()
        if ($lineFull -match '^([0-9]+):(UP|DOWN)$') {
            $RouterCount = $Matches[1]
            $RouterAlertState = $Matches[2]
        }
    }
    $Diag = DiagnoseTm -OkOurInternet $OkOur -OkTunnel $OkTunnel -RouterReachable $rch -RouterCount $RouterCount `
        -RouterAlertState $RouterAlertState -OkDnsMatch $OkDns -OkRemoteWan $OkRw
    $Lat1 = if ($OkTunnel -and ($null -ne $p1.Latency)) { "{0:N1}" -f $p1.Latency } else { "n/a" }
    $Lat2 = if ($OkRw -and ($null -ne $p2.Latency)) { "{0:N1}" -f $p2.Latency } else { "n/a" }
    $Lat3 = if ($OkOur -and ($null -ne $p3.Latency)) { "{0:N1}" -f $p3.Latency } else { "n/a" }
    $dnsShown = $(if (-not [string]::IsNullOrWhiteSpace($dn)) { $dn } else { "<none>" })
    Write-Output (@"
Diagnosis:        $Diag
Tunnel ping:      ok=$OkTunnel latency=$Lat1 ms
Remote WAN ping:  ok=$OkRw latency=$Lat2 ms
Our internet:     ok=$OkOur latency=$Lat3 ms
DNS:              host=$ddns resolved=$dnsShown expected=$rwip match=$OkDns
ROUTER reachable: $rch line=$(if (-not [string]::IsNullOrWhiteSpace($lineFull)){$lineFull}else{"<n/a>"})

"@)
}

if ($Subcommand -eq "diagnose") {
    Run-DiagnoseMode
    exit 0
}

# ===================== main check =====================

try {
    # outer try: always exit 0 for check failures (after logging)

    Rotate-TmLog

    try {
        $cfg = Read-ConfigEnvTm -Path $ConfigPath
    }
    catch {
        Write-TmLog "ERROR" ("config missing: {0}" -f $ConfigPath)
        exit 0
    }

    $miss = Test-EssentialBins
    if ($null -ne $miss) {
        Write-TmLog "ERROR" ("missing executable: $miss")
        exit 0
    }

    # defaults
    $REMOTE_LAN_IP = $(if ($cfg.ContainsKey("REMOTE_LAN_IP")) { $cfg["REMOTE_LAN_IP"] } else { "192.0.2.1" })
    $REMOTE_WAN_IP = $(if ($cfg.ContainsKey("REMOTE_WAN_IP")) { $cfg["REMOTE_WAN_IP"] } else { "198.51.100.1" })
    $REMOTE_DDNS = $(if ($cfg.ContainsKey("REMOTE_DDNS")) { $cfg["REMOTE_DDNS"] } else { "remote.example.com" })
    [int]$FAIL_TH = $(if ($cfg.ContainsKey("FAILURE_THRESHOLD")) { [int]$cfg["FAILURE_THRESHOLD"] } else { 3 })
    [int]$P_CNT = $(if ($cfg.ContainsKey("PING_COUNT")) { [int]$cfg["PING_COUNT"] } else { 3 })
    [int]$P_TIMEOUT = $(if ($cfg.ContainsKey("PING_TIMEOUT")) { [int]$cfg["PING_TIMEOUT"] } else { 2 })

    $prev = Read-PrevStateTm
    $pf = [int]$prev.Fail
    $pst = [string]$prev.AlertState

    # health
    $pTun = Invoke-IcmpPingAvgTm -HostName $REMOTE_LAN_IP -Count $P_CNT -TimeoutSec $P_TIMEOUT
    $pRwan = Invoke-IcmpPingAvgTm -HostName $REMOTE_WAN_IP -Count $P_CNT -TimeoutSec $P_TIMEOUT
    $pOur = Invoke-IcmpPingAvgTm -HostName '1.1.1.1' -Count $P_CNT -TimeoutSec $P_TIMEOUT
    [bool]$OK_TUNNEL = [bool]$pTun.Ok
    [bool]$OK_RWAN = [bool]$pRwan.Ok
    [bool]$OK_OUR = [bool]$pOur.Ok

    $DNS_RES = Resolve-DdnsATm -Name $REMOTE_DDNS
    [bool]$OK_DNS = (-not [string]::IsNullOrWhiteSpace($DNS_RES)) -and ($DNS_RES -eq $REMOTE_WAN_IP)

    # router SSH
    $rrx = Get-RouterStateLineTm
    [bool]$ROUTER_REACHABLE = [bool]$rrx.Ok
    [string]$ROUTER_LINE = ([string]$rrx.Line).Trim()
    [string]$ROUTER_CNT = ""
    [string]$ROUTER_ALERT = ""

    if ($ROUTER_REACHABLE) {
        if ($ROUTER_LINE -match '^([0-9]+):(UP|DOWN)$') {
            $ROUTER_CNT = $Matches[1]
            $ROUTER_ALERT = $Matches[2]
        }
        else {
            $ROUTER_REACHABLE = $false
        }
    }

    # latencies numeric or null JSON
    $latTJson = $(if (($OK_TUNNEL) -and ($null -ne $pTun.Latency)) { [double]$pTun.Latency } elseif ($OK_TUNNEL) { [double]0 } else { $null })
    $latRJson = $(if (($OK_RWAN) -and ($null -ne $pRwan.Latency)) { [double]$pRwan.Latency } elseif ($OK_RWAN) { [double]0 } else { $null })
    $latOJson = $(if (($OK_OUR) -and ($null -ne $pOur.Latency)) { [double]$pOur.Latency } elseif ($OK_OUR) { [double]0 } else { $null })

    $Diag = DiagnoseTm -OkOurInternet $OK_OUR -OkTunnel $OK_TUNNEL -RouterReachable $ROUTER_REACHABLE `
        -RouterCount $ROUTER_CNT -RouterAlertState $ROUTER_ALERT -OkDnsMatch $OK_DNS -OkRemoteWan $OK_RWAN

    $NowIso = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
    Write-TmLog "INFO" ("diagnosis={0} tunnel={1} rwan={2} our={3} dns={4} router_reachable={5} router_state={6} prev={7}:{8}" -f `
            $Diag, $OK_TUNNEL, $OK_RWAN, $OK_OUR, $OK_DNS, $ROUTER_REACHABLE, ($(if (-not [string]::IsNullOrWhiteSpace($ROUTER_LINE)) { $ROUTER_LINE } else { "<n/a>" })), $pf, $pst)

    [int]$newFailCount = [int]$pf
    [string]$newAlertState = [string]$pst
    $lastAlertTs = $prev.LastAlert
    $lastRecTs = $prev.LastRecovery

    if ($Diag -eq "OUR_INTERNET_DOWN") {
        Write-TmLog "WARN" "our internet is down; holding state"
        $stateObjHold = @{
            timestamp             = [string]$NowIso
            alert_state           = [string]$newAlertState
            failure_count         = [int]$newFailCount
            checks                = @{
                tunnel       = @{ target = [string]$REMOTE_LAN_IP; ok = [bool]$OK_TUNNEL; latency_ms = $(if ($null -eq $latTJson) { $null } else { [double]$latTJson }) }
                remote_wan   = @{ target = [string]$REMOTE_WAN_IP; ok = [bool]$OK_RWAN; latency_ms = $(if ($null -eq $latRJson) { $null } else { [double]$latRJson }) }
                our_internet = @{ target = "1.1.1.1"; ok = [bool]$OK_OUR; latency_ms = $(if ($null -eq $latOJson) { $null } else { [double]$latOJson }) }
                dns          = @{ host = [string]$REMOTE_DDNS; resolved = $(if ($null -eq $DNS_RES) { $null } else { [string]$DNS_RES }); expected = [string]$REMOTE_WAN_IP; match = [bool]$OK_DNS }
            }
            router_dedup          = @{
                reachable  = [bool]$ROUTER_REACHABLE
                state      = $(if (-not [string]::IsNullOrWhiteSpace($ROUTER_LINE)) { [string]$ROUTER_LINE } else { $null })
                checked_at = [string]$NowIso
            }
            last_alert_sent_at    = $(if ($null -ne $lastAlertTs -and (-not [string]::IsNullOrWhiteSpace(([string]$lastAlertTs)))) { [string]$lastAlertTs } else { $null })
            last_recovery_sent_at = $(if ($null -ne $lastRecTs -and (-not [string]::IsNullOrWhiteSpace(([string]$lastRecTs)))) { [string]$lastRecTs } else { $null })
            diagnosis             = [string]$Diag
        }
        try { Write-StateJsonTm $stateObjHold } catch { Write-TmLog "WARN" ("state.json write skipped: {0}" -f $_.Exception.Message) }
        exit 0
    }
    elseif ($Diag -eq "HEALTHY") {
        $newFailCount = 0
        if ($pst -eq "DOWN") {
            $recoveryBodyTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tm-rec-" + [System.IO.Path]::GetRandomFileName())
            try {
                $LanShowNum = "$(if(($OK_TUNNEL) -and($null-ne$pTun.Latency)){ "{0:N1}" -f $pTun.Latency }else{"0"})"
                $r1Txt = "$(if(($OK_RWAN) -and($null-ne$pRwan.Latency)){ "OK $( "{0:N1}" -f $pRwan.Latency) ms"}elseif($OK_RWAN){ "OK" }else{ "FAIL" })"
                $r2Txt = "$(if(($OK_OUR)-and($null-ne$pOur.Latency)){ "OK $( "{0:N1}" -f $pOur.Latency) ms"}elseif($OK_OUR){ "OK" }else{ "FAIL" })"
                $recoveryTxt = @"
The site-to-site VPN tunnel has RECOVERED.

==============================================
RECOVERY CONFIRMATION - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')
==============================================
Ping $REMOTE_LAN_IP (tunnel): $LanShowNum ms WAN line: ${r1Txt} Our net: ${r2Txt}

DNS $($REMOTE_DDNS) -> $($DNS_RES) expected $($REMOTE_WAN_IP)

"@
                $utfNb = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($recoveryBodyTmp, $recoveryTxt, $utfNb)
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SendEmailPs1 -SubjectRaw "Tunnel RECOVERED" -BodyPath $recoveryBodyTmp -ConfigPath $ConfigPath | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-TmLog "INFO" "recovery email sent"
                    $lastRecTs = [string]$NowIso
                }
                else { Write-TmLog "ERROR" "recovery email FAILED" }
            }
            finally { Remove-Item -LiteralPath $recoveryBodyTmp -Force -ErrorAction SilentlyContinue }
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $NotifyStubPs1 -Title "Tunnel RECOVERED" -Message "Tunnel back up." -LogPath $LogPath | Out-Null
        }
        $newAlertState = "UP"
    }
    else {
        $newFailCount = [int]$pf + 1
        if (($newFailCount -ge $FAIL_TH) -and ($pst -ne "DOWN")) {
            Write-TmLog "WARN" "failure threshold crossed ($newFailCount/$FAIL_TH)"
            [bool]$emailSkip = (($ROUTER_REACHABLE) -and ($ROUTER_ALERT -eq "DOWN"))
            if ($emailSkip) {
                Write-TmLog "INFO" "suppress email - ROUTER reported DOWN already"
            }
            else {
                $alertTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tm-al-" + [System.IO.Path]::GetRandomFileName())
                try {
                    $diagLineTxt = Diagnosis-ToSubjectTm $Diag
                    $nowH = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
                    if ($ROUTER_REACHABLE) {
                        $rSec = @"

  Reachable: YES
  State: $($ROUTER_LINE)
  Count: $($ROUTER_CNT)
  Alert state: $($ROUTER_ALERT)
"@
                    }
                    else {
                        $rSec = @"


  ROUTER unreachable (Windows alerting alone)
"@
                    }

                    $tStr = "$(if ($OK_TUNNEL) { ("OK $($latTJson) ms") } else { 'FAIL' })"
                    $wStr = "$(if ($OK_RWAN) { ("OK $($latRJson) ms") } else { 'FAIL' })"
                    $oStr = "$(if ($OK_OUR) { ("OK $($latOJson) ms") } else { 'FAIL' })"
                    $bodyTxt = @"
Tunnel DOWN (Windows LAN client vantage).

Minutes approx (failures*$5): $($pf)*5 baseline + current count $newFailCount

Diagnosis: $diagLineTxt

--- $nowH ---
Tunnel test $REMOTE_LAN_IP : ${tStr}
WAN test $($REMOTE_WAN_IP) : ${wStr}
Our internet : ${oStr}
DNS $($REMOTE_DDNS) resolved $($DNS_RES) vs expected $($REMOTE_WAN_IP) match=$OK_DNS

ROUTER DEDUP
$rSec

state=$StatePath log=$LogPath threshold=$FAIL_TH
"@
                    $utfNb = New-Object System.Text.UTF8Encoding $false
                    [System.IO.File]::WriteAllText($alertTmp, $bodyTxt, $utfNb)
                    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SendEmailPs1 -SubjectRaw ("Tunnel DOWN - $($diagLineTxt)") -BodyPath $alertTmp -ConfigPath $ConfigPath | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-TmLog "INFO" "alert email sent"
                        $lastAlertTs = [string]$NowIso
                    }
                    else { Write-TmLog "ERROR" "alert email FAILED" }
                }
                finally { Remove-Item -LiteralPath $alertTmp -Force -ErrorAction SilentlyContinue }
            }
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $NotifyStubPs1 -Title "Tunnel DOWN" -Message $($Diag.ToString()) -LogPath $LogPath | Out-Null
            $newAlertState = "DOWN"
        }
        elseif ($pst -eq "DOWN") { Write-TmLog "INFO" "still DOWN; no repeat email" }
        else { Write-TmLog "INFO" "${newFailCount}/${FAIL_TH} counting" }
    }

    $stateFinal = @{
        timestamp             = [string]$NowIso
        alert_state           = [string]$newAlertState
        failure_count         = [int]$newFailCount
        checks                = @{
            tunnel       = @{ target = [string]$REMOTE_LAN_IP; ok = [bool]$OK_TUNNEL; latency_ms = $(if ($null -eq $latTJson) { $null } else { [double]$latTJson }) }
            remote_wan   = @{ target = [string]$REMOTE_WAN_IP; ok = [bool]$OK_RWAN; latency_ms = $(if ($null -eq $latRJson) { $null } else { [double]$latRJson }) }
            our_internet = @{ target = "1.1.1.1"; ok = [bool]$OK_OUR; latency_ms = $(if ($null -eq $latOJson) { $null } else { [double]$latOJson }) }
            dns          = @{ host = [string]$REMOTE_DDNS; resolved = $(if ($null -eq $DNS_RES) { $null } else { [string]$DNS_RES }); expected = [string]$REMOTE_WAN_IP; match = [bool]$OK_DNS }
        }
        router_dedup          = @{
            reachable  = [bool]$ROUTER_REACHABLE
            state      = $(if (-not [string]::IsNullOrWhiteSpace($ROUTER_LINE)) { [string]$ROUTER_LINE } else { $null })
            checked_at = [string]$NowIso
        }
        last_alert_sent_at    = $(if ($null -ne $lastAlertTs -and (-not [string]::IsNullOrWhiteSpace(([string]$lastAlertTs)))) { [string]$lastAlertTs } else { $null })
        last_recovery_sent_at = $(if ($null -ne $lastRecTs -and (-not [string]::IsNullOrWhiteSpace(([string]$lastRecTs)))) { [string]$lastRecTs } else { $null })
        diagnosis             = [string]$Diag
    }
    try { Write-StateJsonTm $stateFinal } catch { Write-TmLog "ERROR" ("state write: {0}" -f $_.Exception.Message) }
}
catch {
    Write-TmLog "ERROR" ("unexpected: {0}" -f $_.Exception.Message)
}
exit 0
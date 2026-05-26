#requires -Version 5.1
<#
.SYNOPSIS
  Append NOTIFY_SKIPPED to monitor.log (desktop toasts are intentionally not used from the scheduled task).

.NOTES
  Always exit 0.
#>
param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Message,
    [Parameter(Mandatory = $true)][string]$LogPath
)
$line = "[{0:yyyy-MM-dd HH:mm:ss}] [INFO] NOTIFY_SKIPPED title='{1}' message='{2}'" -f (Get-Date), $Title.Replace("'", "''"), $Message.Replace("'", "''")
try {
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
} catch { }
Write-Output $line
exit 0

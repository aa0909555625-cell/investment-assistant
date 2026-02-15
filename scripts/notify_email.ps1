param(
  [Parameter(Mandatory=$false)]
  [string]$To = "",

  [Parameter(Mandatory=$false)]
  [string]$Subject = "Investment Assistant",

  [Parameter(Mandatory=$false)]
  [string]$Body = "Task completed."
)

$ErrorActionPreference = "Stop"
$logDir = ".\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# Stub behavior: log to file (avoid breaking pipelines)
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$line = "{0} to={1} subject={2} body={3}" -f $ts, $To, $Subject, $Body
Add-Content -Path ".\logs\notify_email.log" -Value $line -Encoding UTF8

Write-Host "OK: notify_email stub logged -> .\logs\notify_email.log" -ForegroundColor Green

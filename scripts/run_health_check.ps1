param(
  [Parameter(Mandatory=$false)]
  [switch]$OpenLog
)

$ErrorActionPreference = "Stop"
$logDir = ".\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$log = ".\logs\healthcheck_$ts.log"

try {
  & ".\scripts\health_check.ps1" 2>&1 | Tee-Object -FilePath $log | Out-Host
  Write-Host "OK: health_check done. log -> $log" -ForegroundColor Green
} catch {
  Write-Host "ERROR: health_check failed. log -> $log" -ForegroundColor Red
  throw
}

if ($OpenLog) { notepad $log }

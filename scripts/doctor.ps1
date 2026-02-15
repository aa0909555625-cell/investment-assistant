param(
  [Parameter(Mandatory=$false)]
  [int]$Cash = 300000,

  [Parameter(Mandatory=$false)]
  [int]$KeepDays = 30,

  [Parameter(Mandatory=$false)]
  [switch]$OpenLatestReport
)

$ErrorActionPreference="Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Host ("=== DOCTOR START ({0}) ===" -f (Get-Date -Format "yyyyMMdd_HHmmss")) -ForegroundColor Cyan

& ".\scripts\env_check.ps1" | Out-Host
& ".\scripts\health_check.ps1" | Out-Host
& ".\scripts\retention_cleanup.ps1" -KeepDays $KeepDays | Out-Host
& ".\scripts\lint_ps.ps1" | Out-Host

# run main if exists
if(Test-Path ".\run.ps1"){
  Write-Host "=== RUN MAIN (run.ps1) ===" -ForegroundColor Cyan
  try {
    & ".\run.ps1" -Cash $Cash | Out-Host
  } catch {
    Write-Host "WARN: run.ps1 failed (non-blocking for doctor). See error above." -ForegroundColor Yellow
  }
}

# run top report if exists
if(Test-Path ".\scripts\top20_daily.ps1"){
  Write-Host "=== RUN TOP DAILY ===" -ForegroundColor Cyan
  try {
    & ".\scripts\top20_daily.ps1" -Capital 100000 -Pick 5 | Out-Host
  } catch {
    Write-Host "WARN: top20_daily failed (non-blocking for doctor)." -ForegroundColor Yellow
  }
}

if($OpenLatestReport){
  $latest = Get-ChildItem .\reports\*.txt -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if($latest){
    notepad $latest.FullName
  } else {
    Write-Host "INFO: no report found in .\reports" -ForegroundColor DarkGray
  }
}

Write-Host "=== DOCTOR DONE ===" -ForegroundColor Green

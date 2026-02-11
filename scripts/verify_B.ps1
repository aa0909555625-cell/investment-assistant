Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

Write-Host "=== B VERIFY START ==="

# Clean old
Remove-Item -Force -ErrorAction SilentlyContinue .\reports\weekly\last_failure.json | Out-Null

# 1) Simulate failure -> should create last_failure.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\scheduled_weekly.ps1 -SimulateExitCode 9 -SimulateReason "B-VERIFY simulated failure"
$code = $LASTEXITCODE
Write-Host "scheduled_weekly simulate ExitCode=$code"
if ($code -ne 9) { throw "FAIL: simulate exit code expected 9" }

$exists = Test-Path .\reports\weekly\last_failure.json
Write-Host "last_failure.json exists? $exists"
if (-not $exists) { throw "FAIL: last_failure.json not created" }

# 2) Run notify_on_logon -> should notify, archive, and remove last_failure.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\notify_on_logon.ps1
Write-Host "notify_on_logon ExitCode=$LASTEXITCODE"

$exists2 = Test-Path .\reports\weekly\last_failure.json
Write-Host "last_failure.json exists after notifier? $exists2"
if ($exists2) { throw "FAIL: last_failure.json not removed after notifier" }

$latest = Get-ChildItem .\reports\weekly\archive -Filter "last_failure_*.json" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Desc | Select-Object -First 1

if (-not $latest) { throw "FAIL: archive snapshot not found" }

Write-Host "archive latest: $($latest.FullName)"
Write-Host "=== B VERIFY PASS ==="
exit 0
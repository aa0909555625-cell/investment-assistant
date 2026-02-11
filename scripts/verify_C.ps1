Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "=== C VERIFY START ==="

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$repDir = ".\reports\weekly"
$arcDir = ".\reports\weekly\archive"
New-Item -ItemType Directory -Force -Path $repDir,$arcDir | Out-Null

$lastFailure = Join-Path $repDir "last_failure.json"
$lastSuccess = Join-Path $repDir "last_success.json"

# 1) Simulate SUCCESS write
@{
  generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  isoWeek     = "2099-01"
  exitCode    = 0
  repo        = (Resolve-Path .).Path
  summaryPath = ""
  logPath     = ""
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $lastSuccess -Encoding utf8 -NoNewline

# Put a stale failure, then run scheduled_weekly (success should clear it ONLY when real run exits 0)
'{"exitCode":999}' | Set-Content -LiteralPath $lastFailure -Encoding utf8 -NoNewline

# Since real weekly currently exits 0 in your environment, scheduled_weekly should remove last_failure.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scheduled_weekly.ps1
$code1 = $LASTEXITCODE
if ($code1 -ne 0) { throw "scheduled_weekly expected success (0) but got $code1" }

if (-not (Test-Path $lastSuccess)) { throw "missing last_success.json after success path" }
if (Test-Path $lastFailure) { throw "last_failure.json should be cleared on success" }

# 2) Simulate FAILURE snapshot then notifier archives & clears
@{
  generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  isoWeek     = "2099-02"
  exitCode    = 9
  repo        = (Resolve-Path .).Path
  summaryPath = (Resolve-Path .\reports\weekly\weekly_summary_2026-07.txt).Path
  logPath     = (Get-ChildItem .\logs\weekly -Filter "weekly_task_*.log" | Sort-Object LastWriteTime -Desc | Select-Object -First 1).FullName
  logTail     = @("SIMULATED FAILURE","tail 1","tail 2")
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $lastFailure -Encoding utf8 -NoNewline

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\notify_on_logon.ps1
$code2 = $LASTEXITCODE
if ($code2 -ne 0) { throw "notify_on_logon expected 0 but got $code2" }

if (Test-Path $lastFailure) { throw "last_failure.json should be cleared after notifier" }

$latestArc = Get-ChildItem $arcDir -Filter "last_failure_*.json" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Desc | Select-Object -First 1
if (-not $latestArc) { throw "expected an archived last_failure_*.json snapshot" }

Write-Host ("archive latest: {0}" -f $latestArc.FullName)
Write-Host "=== C VERIFY PASS ==="
exit 0
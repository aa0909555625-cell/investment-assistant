Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "=== D VERIFY START ==="

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# Headless mode: do not open notepad
$env:IA_NO_NOTEPAD = "1"

# 1) run weekly once (should be OK/WARN, not crash)
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 weekly
$code = [int]$LASTEXITCODE
if ($code -ne 0 -and $code -ne 2) { throw "weekly returned unexpected ExitCode=$code (expected 0 or 2)" }

# 2) last_run.json exists
if (-not (Test-Path -LiteralPath ".\reports\weekly\last_run.json")) { throw "missing reports\weekly\last_run.json" }

# 3) last_success.json exists when exit code is 0/2
if (-not (Test-Path -LiteralPath ".\reports\weekly\last_success.json")) { throw "missing reports\weekly\last_success.json" }

# 4) open commands should not crash (headless prints paths/tail)
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 open last_success | Out-Null
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 open tail | Out-Null
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 open summary | Out-Null
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 open log | Out-Null

# 5) last_failure open should not crash even if missing (may fallback to archive or warn)
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 open last_failure | Out-Null

Write-Host "=== D VERIFY PASS ==="
exit 0
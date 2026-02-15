param(
  [string]$Date = "2026-02-10",
  [int]$Capital = 300000,
  [int]$Top = 4000,
  [switch]$Fetch,
  [switch]$Open
)

$ErrorActionPreference = "Stop"

# Ensure project root
try {
  $here = Split-Path -Parent $PSCommandPath
  Set-Location (Resolve-Path (Join-Path $here "..")).Path | Out-Null
} catch {
  Set-Location ".." | Out-Null
}

Write-Host "=== RUN 7.5 PIPELINE ===" -ForegroundColor Cyan
Write-Host ("Date={0} Capital={1} Top={2} Fetch={3} Open={4}" -f $Date,$Capital,$Top,$Fetch.IsPresent,$Open.IsPresent) -ForegroundColor DarkGray

# 0) optional fetch
if ($Fetch) {
  $fetchScript = ".\scripts\fetch_tw_daily.ps1"
  if (!(Test-Path $fetchScript)) {
    throw "missing -> $fetchScript`nFix: create scripts\fetch_tw_daily.ps1 (TWSE+TPEx fetch)."
  }
  Write-Host "=== FETCH TW DAILY (TWSE+TPEx) ===" -ForegroundColor Cyan
  & $fetchScript -Date $Date
}

# 1) rehab
$rehab = ".\scripts\rehab_data_schema.ps1"
if (!(Test-Path $rehab)) { throw "missing -> $rehab" }
Write-Host "=== REHAB DATA SCHEMA ===" -ForegroundColor Cyan
& $rehab

# 2) dashboard (IMPORTANT: use HASHTABLE splatting, NOT array splatting)
$dash = ".\scripts\build_dashboard_html.ps1"
if (!(Test-Path $dash)) { throw "missing -> $dash" }

$dashSplat = @{
  Capital = $Capital
  Top     = $Top
}
if ($Open) { $dashSplat["Open"] = $true }

Write-Host "=== BUILD DASHBOARD HTML ===" -ForegroundColor Cyan
& $dash @dashSplat

# 3) health check (optional)
$hc = ".\scripts\run_health_check.ps1"
if (Test-Path $hc) {
  Write-Host "=== HEALTH CHECK ===" -ForegroundColor Cyan
  & $hc
} else {
  Write-Host "WARN: missing -> $hc (skip health check)" -ForegroundColor Yellow
}

Write-Host "=== DONE 7.5 ===" -ForegroundColor Green
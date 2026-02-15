#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Date = "",
  [int]$Capital = 300000,
  [int]$Top = 4000,

  # backtest + reports
  [int]$HoldingDays = 5,
  [int]$LookbackDays = 60,
  [int]$DecisionLookbackDays = 120,
  [int]$HistoryMonths = 6,
  [int]$ScoreThreshold = 50,

  # portfolio risk params
  [switch]$UseAllocationWeights,
  [double]$ExposureCap = 0.60,
  [double]$DailyStopLoss = 0.03,
  [double]$MaxDrawdownGuard = 0.12,
  [double]$RiskOffScale = 0.25,
  [int]$ConsecLossStopDays = 2,

  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Anchor paths to project root ----
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
function Resolve-ProjectPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $ProjectRoot }
  if ([System.IO.Path]::IsPathRooted($p)) { return $p }
  $rel = $p.Trim()
  if ($rel.StartsWith(".\")) { $rel = $rel.Substring(2) }
  elseif ($rel.StartsWith("./")) { $rel = $rel.Substring(2) }
  return (Join-Path $ProjectRoot $rel)
}

function Require([string]$path) {
  if (!(Test-Path $path)) { throw "Missing required file: $path" }
}

Write-Host "=== UPDATE TO LATEST (daily/decisions + backtest + reports + dashboard) ===" -ForegroundColor Cyan
Write-Host ("[INFO] ProjectRoot   = {0}" -f $ProjectRoot) -ForegroundColor DarkGray
Write-Host ("[INFO] Capital       = {0}" -f $Capital) -ForegroundColor DarkGray
Write-Host ("[INFO] Top           = {0}" -f $Top) -ForegroundColor DarkGray
Write-Host ("[INFO] HoldingDays   = {0}" -f $HoldingDays) -ForegroundColor DarkGray
Write-Host ("[INFO] LookbackDays  = {0}" -f $LookbackDays) -ForegroundColor DarkGray
Write-Host ("[INFO] ScoreThres    = {0}" -f $ScoreThreshold) -ForegroundColor DarkGray

# ---- scripts ----
$runDashboard   = Resolve-ProjectPath ".\scripts\run_dashboard.ps1"
$buildDashboard = Resolve-ProjectPath ".\scripts\build_dashboard_html.ps1"
$rebuildDailyTs = Resolve-ProjectPath ".\scripts\rebuild_daily_timeseries.ps1"
$buildDecHist   = Resolve-ProjectPath ".\scripts\build_decisions_from_history.ps1"
$runBackWin     = Resolve-ProjectPath ".\scripts\run_backtest_window.ps1"
$perfReport     = Resolve-ProjectPath ".\scripts\performance_report.ps1"
$equityReport   = Resolve-ProjectPath ".\scripts\equity_curve_report.ps1"
$portReport     = Resolve-ProjectPath ".\scripts\portfolio_curve_report.ps1"

Require $runDashboard
Require $buildDashboard
Require $rebuildDailyTs
Require $buildDecHist
Require $runBackWin
Require $perfReport
Require $equityReport
Require $portReport

# ---- data ----
$dailyPath     = Resolve-ProjectPath ".\data\all_stocks_daily.csv"
$decisionsPath = Resolve-ProjectPath ".\data\all_stocks_decisions.csv"
$allocLogPath  = Resolve-ProjectPath ".\data\allocation_log.csv"
$reportsDir    = Resolve-ProjectPath ".\reports"
if (!(Test-Path $reportsDir)) { New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null }

# ---- STEP 1: make sure daily/decisions exist (reuse your existing pipeline) ----
# We assume daily/decisions are already OK most times. If missing, call your known scripts (if any).
# Minimal guard: if missing, fail early.
if (!(Test-Path $dailyPath))     { throw "daily.csv missing: $dailyPath (run your daily builder first)" }
if (!(Test-Path $decisionsPath)) { throw "decisions.csv missing: $decisionsPath (run your decisions builder first)" }

# Determine target date from decisions (scalar)
$rowsAll = @((Import-Csv $decisionsPath))
if ($rowsAll.Length -eq 0) { throw "decisions.csv empty: $decisionsPath" }

$targetDate = $Date
if ([string]::IsNullOrWhiteSpace($targetDate)) {
  $targetDate = ($rowsAll | Select-Object -ExpandProperty date | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
}
$targetDate = [string]$targetDate
if ([string]::IsNullOrWhiteSpace($targetDate)) { throw "Cannot determine TargetDate." }

Write-Host ("[INFO] TargetDate   = {0}" -f $targetDate) -ForegroundColor Gray

# ---- STEP 2: refresh dashboard (current decisions) ----
Write-Host "[STEP] Dashboard (current decisions)..." -ForegroundColor Yellow
& $runDashboard -Date $targetDate -Capital $Capital -Top $Top -Open:$Open | Out-Host
Write-Host "[OK] Dashboard refreshed." -ForegroundColor Green

# ---- STEP 3: ensure allocation_log exists (we will generate via backtest window later anyway) ----
if (!(Test-Path $allocLogPath)) {
  Write-Host "[WARN] allocation_log.csv missing; will be created by backtest window." -ForegroundColor Yellow
}

# ---- STEP 4: build symbol list from allocation_log (if exists) else from latest decisions top codes ----
$symbols = @()
if (Test-Path $allocLogPath) {
  try {
    $symbols = @(Import-Csv $allocLogPath | Select-Object -ExpandProperty code | Where-Object { $_ -match '^\d{4}$' } | Sort-Object -Unique)
  } catch { $symbols = @() }
}
if ($symbols.Length -eq 0) {
  $symbols = @($rowsAll | Where-Object { $_.date -eq $targetDate } |
    Sort-Object { [double]$_.total_score } -Descending |
    Select-Object -First 20 -ExpandProperty code |
    Where-Object { $_ -match '^\d{4}$' } | Sort-Object -Unique)
}

if ($symbols.Length -eq 0) { throw "No symbols found for history rebuild." }

Write-Host ("[INFO] Symbols ({0}): {1}" -f $symbols.Length, ($symbols -join ",")) -ForegroundColor Gray

# ---- STEP 5: rebuild daily timeseries for symbols (6 months) ----
Write-Host "[STEP] Rebuild daily timeseries (history)..." -ForegroundColor Yellow
& $rebuildDailyTs -Months $HistoryMonths -Symbols ($symbols -join ",") -KeepRaw | Out-Host
Require $dailyPath
Write-Host "[OK] all_stocks_daily.csv ready." -ForegroundColor Green

# ---- STEP 6: rebuild decisions from history (lookback 120) ----
Write-Host "[STEP] Build decisions from history..." -ForegroundColor Yellow
& $buildDecHist -LookbackDays $DecisionLookbackDays | Out-Host
Require $decisionsPath
Write-Host "[OK] all_stocks_decisions.csv rebuilt." -ForegroundColor Green

# ---- STEP 7: backtest window (ensure future exists) ----
# EndDate = TargetDate - (HoldingDays + 2) to guarantee future rows exist for performance calculations.
$endDate = (Get-Date $targetDate).AddDays(-1 * ($HoldingDays + 2)).ToString("yyyy-MM-dd")
Write-Host ("[STEP] Backtest window... EndDate={0}" -f $endDate) -ForegroundColor Yellow
& $runBackWin -Capital $Capital -LookbackDays $LookbackDays -ScoreThreshold $ScoreThreshold -EndDate $endDate | Out-Host
Require $allocLogPath
Write-Host "[OK] allocation_log.csv rebuilt by backtest window." -ForegroundColor Green

# ---- STEP 8: reports ----
Write-Host "[STEP] performance_report..." -ForegroundColor Yellow
& $perfReport -HoldingDays $HoldingDays -Open:$Open -AllowPartial | Out-Host

Write-Host "[STEP] equity_curve_report..." -ForegroundColor Yellow
& $equityReport -HoldingDays $HoldingDays -Open:$Open | Out-Host

Write-Host "[STEP] portfolio_curve_report (risk control)..." -ForegroundColor Yellow
$portArgs = @()
if ($UseAllocationWeights) { $portArgs += "-UseAllocationWeights" }
$portArgs += @(
  "-ExposureCap", $ExposureCap,
  "-DailyStopLoss", $DailyStopLoss,
  "-MaxDrawdownGuard", $MaxDrawdownGuard,
  "-RiskOffScale", $RiskOffScale,
  "-ConsecLossStopDays", $ConsecLossStopDays
)
& $portReport @portArgs -Open:$Open | Out-Host

Write-Host "[OK] Reports generated." -ForegroundColor Green

# ---- STEP 9: final dashboard (now includes quick links + risk card reading latest reports) ----
Write-Host "[STEP] Final dashboard (with Quick Links + Risk Card)..." -ForegroundColor Yellow
& $runDashboard -Date $targetDate -Capital $Capital -Top $Top -Open:$Open | Out-Host
Write-Host "[DONE] update_to_latest completed." -ForegroundColor Cyan
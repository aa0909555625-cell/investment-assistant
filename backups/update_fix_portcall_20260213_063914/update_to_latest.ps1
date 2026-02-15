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

Write-Host "=== UPDATE TO LATEST (daily -> decisions -> backtest -> reports -> dashboard) ===" -ForegroundColor Cyan
Write-Host ("[INFO] ProjectRoot   = {0}" -f $ProjectRoot) -ForegroundColor DarkGray
Write-Host ("[INFO] Capital       = {0}" -f $Capital) -ForegroundColor DarkGray
Write-Host ("[INFO] Top           = {0}" -f $Top) -ForegroundColor DarkGray
Write-Host ("[INFO] HoldingDays   = {0}" -f $HoldingDays) -ForegroundColor DarkGray
Write-Host ("[INFO] LookbackDays  = {0}" -f $LookbackDays) -ForegroundColor DarkGray
Write-Host ("[INFO] ScoreThres    = {0}" -f $ScoreThreshold) -ForegroundColor DarkGray
Write-Host ("[INFO] HistoryMonths = {0}" -f $HistoryMonths) -ForegroundColor DarkGray

# ---- scripts ----
$runDashboard   = Resolve-ProjectPath ".\scripts\run_dashboard.ps1"
$rebuildDailyTs = Resolve-ProjectPath ".\scripts\rebuild_daily_timeseries.ps1"
$buildDecHist   = Resolve-ProjectPath ".\scripts\build_decisions_from_history.ps1"
$runBackWin     = Resolve-ProjectPath ".\scripts\run_backtest_window.ps1"
$perfReport     = Resolve-ProjectPath ".\scripts\performance_report.ps1"
$equityReport   = Resolve-ProjectPath ".\scripts\equity_curve_report.ps1"
$portReport     = Resolve-ProjectPath ".\scripts\portfolio_curve_report.ps1"

Require $runDashboard
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

# ---- STEP A: pick symbols (prefer allocation_log; else decisions; else hard fail) ----
$symbols = @()
if (Test-Path $allocLogPath) {
  try {
    $symbols = @(Import-Csv $allocLogPath | Select-Object -ExpandProperty code | Where-Object { $_ -match '^\d{4}$' } | Sort-Object -Unique)
  } catch { $symbols = @() }
}

if ($symbols.Length -eq 0 -and (Test-Path $decisionsPath)) {
  $rowsAll = @((Import-Csv $decisionsPath))
  if ($rowsAll.Length -gt 0) {
    $targetDateTmp = $Date
    if ([string]::IsNullOrWhiteSpace($targetDateTmp)) {
      $targetDateTmp = ($rowsAll | Select-Object -ExpandProperty date | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
    }
    $symbols = @($rowsAll | Where-Object { $_.date -eq $targetDateTmp } |
      Sort-Object { [double]$_.total_score } -Descending |
      Select-Object -First 20 -ExpandProperty code |
      Where-Object { $_ -match '^\d{4}$' } | Sort-Object -Unique)
  }
}

if ($symbols.Length -eq 0) {
  throw "No symbols available. Need allocation_log.csv or decisions.csv to derive symbols."
}

Write-Host ("[INFO] Symbols ({0}): {1}" -f $symbols.Length, ($symbols -join ",")) -ForegroundColor Gray

# ---- STEP 1: ensure daily exists by rebuilding from history ----
Write-Host "[STEP] Rebuild daily timeseries (history)..." -ForegroundColor Yellow
& $rebuildDailyTs -Months $HistoryMonths -Symbols ($symbols -join ",") -KeepRaw | Out-Host
Require $dailyPath
Write-Host "[OK] all_stocks_daily.csv ready." -ForegroundColor Green

# ---- STEP 2: build decisions from history ----
Write-Host "[STEP] Build decisions from history..." -ForegroundColor Yellow
& $buildDecHist -LookbackDays $DecisionLookbackDays | Out-Host
Require $decisionsPath
Write-Host "[OK] all_stocks_decisions.csv rebuilt." -ForegroundColor Green

# ---- STEP 3: determine target date from decisions (scalar) ----
$rowsAll2 = @((Import-Csv $decisionsPath))
if ($rowsAll2.Length -eq 0) { throw "decisions.csv empty: $decisionsPath" }

$targetDate = $Date
if ([string]::IsNullOrWhiteSpace($targetDate)) {
  $targetDate = ($rowsAll2 | Select-Object -ExpandProperty date | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
}
$targetDate = [string]$targetDate
if ([string]::IsNullOrWhiteSpace($targetDate)) { throw "Cannot determine TargetDate." }

Write-Host ("[INFO] TargetDate   = {0}" -f $targetDate) -ForegroundColor Gray

# ---- STEP 4: backtest window (ensure future exists for reports) ----
$endDate = (Get-Date $targetDate).AddDays(-1 * ($HoldingDays + 2)).ToString("yyyy-MM-dd")
Write-Host ("[STEP] Backtest window... EndDate={0}" -f $endDate) -ForegroundColor Yellow
& $runBackWin -Capital $Capital -LookbackDays $LookbackDays -ScoreThreshold $ScoreThreshold -EndDate $endDate | Out-Host
Require $allocLogPath
Write-Host "[OK] allocation_log.csv rebuilt by backtest window." -ForegroundColor Green

# ---- STEP 5: reports ----
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

# ---- STEP 6: dashboard (final) ----
Write-Host "[STEP] Dashboard (final)..." -ForegroundColor Yellow
& $runDashboard -Date $targetDate -Capital $Capital -Top $Top -Open:$Open | Out-Host

Write-Host "[DONE] update_to_latest completed." -ForegroundColor Cyan
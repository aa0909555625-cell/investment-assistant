#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Date = "",
  [int]$Capital = 300000,
  [int]$Top = 4000,
  [string]$OutDir = ".\reports",
  [switch]$Open,
  [switch]$ListDates
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

function ToDoubleSafe([object]$v, [double]$fallback = 0.0) {
  if ($null -eq $v) { return $fallback }
  $s = [string]$v
  if ([string]::IsNullOrWhiteSpace($s)) { return $fallback }
  try { return [double]$s } catch { return $fallback }
}
function HtmlEncode([string]$s){
  if ($null -eq $s) { return "" }
  return [System.Net.WebUtility]::HtmlEncode($s)
}

$decisionsPath = Resolve-ProjectPath ".\data\all_stocks_decisions.csv"
$resolvedOutDir = Resolve-ProjectPath $OutDir
if (!(Test-Path $decisionsPath)) { throw "decisions csv not found: $decisionsPath" }
if (!(Test-Path $resolvedOutDir)) { New-Item -ItemType Directory -Force -Path $resolvedOutDir | Out-Null }

$rowsAll = @((Import-Csv $decisionsPath))
if ($rowsAll.Length -eq 0) { throw "decisions csv is empty: $decisionsPath" }

# ListDates mode
if ($ListDates) {
  $dates = @($rowsAll | Select-Object -ExpandProperty date | Where-Object { $_ } | Sort-Object -Unique)
  $dates -join ", " | Write-Output
  return
}

# Determine target date (MUST be scalar string)
$targetDate = $Date
if ([string]::IsNullOrWhiteSpace($targetDate)) {
  $targetDate = ($rowsAll | Select-Object -ExpandProperty date | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
}
$targetDate = [string]$targetDate
if ([string]::IsNullOrWhiteSpace($targetDate)) { throw "Cannot determine target date." }

$rows = @($rowsAll | Where-Object { $_.date -eq $targetDate })
if ($rows.Length -eq 0) { throw "No rows for date=$targetDate in decisions csv." }

# ---- Top table ----
$topRows = @($rows | Sort-Object { ToDoubleSafe $_.total_score 0 } -Descending | Select-Object -First $Top)

# KPI: score bands
$scores = @($rows | ForEach-Object { ToDoubleSafe $_.total_score 0 })
$avgScore = 0.0
if ($scores.Length -gt 0) { $avgScore = [math]::Round((($scores | Measure-Object -Average).Average), 2) }

$cnt70 = (@($rows | Where-Object { (ToDoubleSafe $_.total_score 0) -ge 70 })).Length
$cnt60 = (@($rows | Where-Object { (ToDoubleSafe $_.total_score 0) -ge 60 -and (ToDoubleSafe $_.total_score 0) -lt 70 })).Length
$cnt50 = (@($rows | Where-Object { (ToDoubleSafe $_.total_score 0) -ge 50 -and (ToDoubleSafe $_.total_score 0) -lt 60 })).Length
$cntLt50 = $rows.Length - $cnt70 - $cnt60 - $cnt50

# ---- Risk Card: latest portfolio_curve_*.csv ----
$risk = [ordered]@{
  HasData = $false
  CsvName = ""
  Days = ""
  TotalRet = ""
  WinRate = ""
  AvgPnl = ""
  Mdd = ""
  ModeToday = ""
  RiskOffNext = ""
  ExposureToday = ""
}

try {
  $pc = Get-ChildItem (Resolve-ProjectPath ".\reports") -Filter "portfolio_curve_*.csv" -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($pc) {
    $pRows = @((Import-Csv $pc.FullName))
    if ($pRows.Length -gt 0) {
      $risk.HasData = $true
      $risk.CsvName = $pc.Name
      $risk.Days = [string]$pRows.Length

      $last = $pRows[-1]
      $finalEq = ToDoubleSafe $last.equity 1.0
      $risk.TotalRet = [string][math]::Round(($finalEq - 1.0), 6)

      $wins = (@($pRows | Where-Object { (ToDoubleSafe $_.pnl 0) -gt 0 })).Length
      $risk.WinRate = [string][math]::Round(($wins / $pRows.Length), 4)

      $risk.AvgPnl = [string][math]::Round((($pRows | Measure-Object pnl -Average).Average), 6)
      $risk.Mdd    = [string][math]::Round((($pRows | Measure-Object drawdown -Maximum).Maximum), 6)

      if ($last.PSObject.Properties.Name -contains "mode") { $risk.ModeToday = [string]$last.mode }
      if ($last.PSObject.Properties.Name -contains "risk_off_next") { $risk.RiskOffNext = [string]$last.risk_off_next }
      if ($last.PSObject.Properties.Name -contains "exposure") { $risk.ExposureToday = [string]$last.exposure }
    }
  }
} catch { }

# ---- Risk hint ----
$riskHint = "N/A"
if ($risk.HasData) {
  $riskHint = "NORMAL"
  if ($risk.RiskOffNext -match '^(True|true|1)$') { $riskHint = "RISK_OFF (tomorrow)" }
}

# ---- Allocation Suggestion (simple) ----
$cands = @($topRows | Where-Object { (ToDoubleSafe $_.total_score 0) -ge 50 })
$allocHtml = ""
if ($cands.Length -gt 0) {
  $per = [math]::Floor($Capital / $cands.Length)
  $allocLines = @()
  foreach ($c in $cands) {
    $allocLines += ("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>" -f
      (HtmlEncode $c.code),
      (HtmlEncode $c.name),
      (ToDoubleSafe $c.total_score 0),
      $per
    )
  }
  $allocHtml = ($allocLines -join "`n")
} else {
  $allocHtml = "<tr><td colspan='4'>No candidates with score >= 50.</td></tr>"
}

# ---- Main table rows ----
$tableLines = @()
foreach ($r in $topRows) {
  $tableLines += ("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>" -f
    (HtmlEncode $r.code),
    (HtmlEncode $r.name),
    (HtmlEncode $r.sector),
    ([math]::Round((ToDoubleSafe $r.change_percent 0), 4)),
    ([math]::Round((ToDoubleSafe $r.total_score 0), 2)),
    (HtmlEncode $r.warnings)
  )
}
$rowsHtml = ($tableLines -join "`n")

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$outPath = Join-Path $resolvedOutDir ("tw_dashboard_{0}_{1}.html" -f $targetDate, $ts)

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>TW Dashboard</title>
<style>
body { font-family: Arial; background:#111; color:#eee; margin:0; padding:18px; }
h2 { margin: 0 0 10px 0; }
.grid { display:grid; grid-template-columns: repeat(4, 1fr); gap:12px; }
.card { background:#1a1a1a; padding:12px; border-radius:10px; border:1px solid #2a2a2a; }
.small { color:#aaa; font-size:12px; }
.kpi { font-size:22px; font-weight:bold; margin-top:6px; }
.badge { display:inline-block; padding:4px 8px; border-radius:999px; background:#222; border:1px solid #333; font-size:12px; }
table { width:100%; border-collapse: collapse; margin-top:12px; }
th, td { padding:8px; border:1px solid #444; text-align:center; }
th { background:#222; }
.section { margin-top:14px; }
</style>
</head>
<body>

<h2>Market Overview (Decisions)  $targetDate</h2>
<div class="small">ProjectRoot: $ProjectRoot</div>
<div class="small">Decisions: $decisionsPath</div>
<div class="small">Out: $outPath</div>

<div class="section grid">
  <div class="card">
    <div class="small">Rows (date)</div>
    <div class="kpi">$($rows.Length)</div>
    <div class="small">Top displayed: $($topRows.Length)</div>
  </div>

  <div class="card">
    <div class="small">Avg Score</div>
    <div class="kpi">$avgScore</div>
    <div class="small">70+: $cnt70 | 60-69: $cnt60</div>
  </div>

  <div class="card">
    <div class="small">Score Bands</div>
    <div class="kpi">$cnt50</div>
    <div class="small">50-59 count (entry band)</div>
  </div>

  <div class="card">
    <div class="small">Risk Mode Hint</div>
    <div class="kpi">$riskHint</div>
    <div class="small">Based on latest portfolio_curve CSV</div>
  </div>
</div>

<div class="section card">
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <div><b>Risk Control Card (Day-level Portfolio Curve)</b></div>
    <div class="badge">CSV: $([System.Net.WebUtility]::HtmlEncode($risk.CsvName))</div>
  </div>
  <div class="small">Days=$($risk.Days) | ModeToday=$($risk.ModeToday) | RiskOffNext=$($risk.RiskOffNext) | Exposure=$($risk.ExposureToday)</div>

  <div class="grid" style="grid-template-columns: repeat(4, 1fr); margin-top:10px;">
    <div class="card">
      <div class="small">Total Return</div>
      <div class="kpi">$($risk.TotalRet)</div>
    </div>
    <div class="card">
      <div class="small">MDD</div>
      <div class="kpi">$($risk.Mdd)</div>
    </div>
    <div class="card">
      <div class="small">Win Rate (days)</div>
      <div class="kpi">$($risk.WinRate)</div>
    </div>
    <div class="card">
      <div class="small">Avg PnL / day</div>
      <div class="kpi">$($risk.AvgPnl)</div>
    </div>
  </div>

  <div class="small" style="margin-top:8px;">
    If RiskOffNext=True: reduce exposure tomorrow (RiskOffScale). If MDD approaches guard: lower ExposureCap or increase ScoreThreshold.
  </div>
</div>

<div class="section card">
  <b>Capital Allocation Suggestion (simple)</b>
  <div class="small">Capital=$Capital | Candidates=score>=50 among Top</div>
  <table>
    <tr><th>Code</th><th>Name</th><th>Score</th><th>Suggested Allocation (NTD)</th></tr>
    $allocHtml
  </table>
</div>

<div class="section">
  <div class="card">
    <b>Top Candidates</b>
    <table>
      <tr><th>Code</th><th>Name</th><th>Sector</th><th>Chg%</th><th>Score</th><th>Warnings</th></tr>
      $rowsHtml
    </table>
  </div>
</div>

</body>
</html>
"@

[System.IO.File]::WriteAllText($outPath, $html.Replace("`r`n","`n").Replace("`n","`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("OK: wrote HTML -> {0}" -f $outPath) -ForegroundColor Green
if ($Open) { Start-Process $outPath | Out-Null }
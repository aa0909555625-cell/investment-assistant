#Requires -Version 5.1
[CmdletBinding()]
param(
  [double]$InitialEquity = 1.0,
  [string]$OutDir = ".\reports",

  # ---- Risk Controls ----
  [double]$DailyStopLoss = 0.03,        # daily pnl <= -3% => risk-off next day
  [double]$MaxDrawdownGuard = 0.15,     # MDD >= 15% => risk-off
  [double]$RiskOffScale = 0.25,         # exposure scaling in risk-off mode (e.g. 25%)

  # ---- Portfolio Controls ----
  [double]$ExposureCap = 0.60,          # max exposure each day (0~1). e.g. 0.60 => only deploy 60% capital
  [int]$ConsecLossStopDays = 2,         # if consecutive losing days >= N => risk-off next day
  [switch]$UseAllocationWeights,        # ON => weighted by allocation; OFF => equal-weight (fallback)

  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
function Resolve-ProjectPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $ProjectRoot }
  if ([System.IO.Path]::IsPathRooted($p)) { return $p }
  $rel = $p.Trim()
  if ($rel.StartsWith(".\")) { $rel = $rel.Substring(2) }
  elseif ($rel.StartsWith("./")) { $rel = $rel.Substring(2) }
  return (Join-Path $ProjectRoot $rel)
}

function Clamp01([double]$x){
  if ($x -lt 0) { return 0.0 }
  if ($x -gt 1) { return 1.0 }
  return $x
}

$ExposureCap = Clamp01 $ExposureCap
$RiskOffScale = Clamp01 $RiskOffScale

$logPath   = Resolve-ProjectPath ".\data\allocation_log.csv"
$dailyPath = Resolve-ProjectPath ".\data\all_stocks_daily.csv"
$resolvedOutDir = Resolve-ProjectPath $OutDir

if (!(Test-Path $logPath))   { throw "allocation_log.csv not found: $logPath" }
if (!(Test-Path $dailyPath)) { throw "all_stocks_daily.csv not found: $dailyPath" }
if (!(Test-Path $resolvedOutDir)) { New-Item -ItemType Directory -Force -Path $resolvedOutDir | Out-Null }

$log   = @((Import-Csv $logPath))
$daily = @((Import-Csv $dailyPath))
if ($log.Length -eq 0)   { throw "allocation_log.csv is empty: $logPath" }
if ($daily.Length -eq 0) { throw "all_stocks_daily.csv is empty: $dailyPath" }

# Index: (date|code) -> change_percent
$px = @{}
foreach ($r in $daily) {
  if (-not $r.date -or -not $r.code) { continue }
  $k = ("{0}|{1}" -f $r.date, $r.code)
  $px[$k] = [double]$r.change_percent
}

# Group allocation log by date => list of entries {code, allocation}
$byDate = @{}
foreach ($e in $log) {
  if (-not $e.date -or -not $e.code) { continue }
  $d = [string]$e.date
  if (-not $byDate.ContainsKey($d)) { $byDate[$d] = New-Object System.Collections.ArrayList }

  $alloc = 0.0
  if ($null -ne $e.allocation -and $e.allocation -ne "") {
    try { $alloc = [double]$e.allocation } catch { $alloc = 0.0 }
  }

  [void]$byDate[$d].Add([PSCustomObject]@{
    code = [string]$e.code
    allocation = $alloc
  })
}

$dates = @($byDate.Keys | Sort-Object)

# day-level curve
$equity = [double]$InitialEquity
$peak = $equity
$mdd = 0.0

$riskOff = $false
$consecLoss = 0

$rows = @()

foreach ($d in $dates) {
  $entries = @($byDate[$d])

  # Unique by code; if duplicates exist, keep max allocation
  $tmp = @{}
  foreach ($en in $entries) {
    if (-not $en.code) { continue }
    if (-not $tmp.ContainsKey($en.code)) { $tmp[$en.code] = [double]$en.allocation }
    else {
      if ([double]$en.allocation -gt [double]$tmp[$en.code]) { $tmp[$en.code] = [double]$en.allocation }
    }
  }

  $codes = @($tmp.Keys | Sort-Object)
  if ($codes.Length -eq 0) { continue }

  # Build returns + weights
  $rets = @()
  $wts  = @()

  if ($UseAllocationWeights) {
    $sumAlloc = 0.0
    foreach ($c in $codes) { $sumAlloc += [double]$tmp[$c] }

    # if allocations are missing/zero, fallback to equal weight
    if ($sumAlloc -le 0) {
      foreach ($c in $codes) {
        $k = ("{0}|{1}" -f $d, $c)
        if ($px.ContainsKey($k)) {
          $rets += ($px[$k] / 100.0)
          $wts  += (1.0)
        }
      }
    } else {
      foreach ($c in $codes) {
        $k = ("{0}|{1}" -f $d, $c)
        if ($px.ContainsKey($k)) {
          $rets += ($px[$k] / 100.0)
          $wts  += ([double]$tmp[$c] / $sumAlloc)
        }
      }
    }
  } else {
    foreach ($c in $codes) {
      $k = ("{0}|{1}" -f $d, $c)
      if ($px.ContainsKey($k)) {
        $rets += ($px[$k] / 100.0)
        $wts  += (1.0)
      }
    }
  }

  if ($rets.Length -eq 0) { continue }

  # Weighted avg return
  $avgDayRet = 0.0
  if ($UseAllocationWeights -and ($wts | Measure-Object -Sum).Sum -gt 0) {
    for ($i=0; $i -lt $rets.Length; $i++) { $avgDayRet += ([double]$rets[$i] * [double]$wts[$i]) }
  } else {
    $avgDayRet = ($rets | Measure-Object -Average).Average
  }

  # exposure scaling (risk mode + exposure cap)
  $exposureScale = $ExposureCap
  if ($riskOff) { $exposureScale = [double]$RiskOffScale }

  $pnl = $avgDayRet * $exposureScale

  $equity = [math]::Round($equity * (1.0 + $pnl), 6)

  if ($equity -gt $peak) { $peak = $equity }
  $dd = 0.0
  if ($peak -gt 0) { $dd = ($peak - $equity) / $peak }
  if ($dd -gt $mdd) { $mdd = $dd }

  # Update streak
  if ($pnl -lt 0) { $consecLoss++ } else { $consecLoss = 0 }

  # Determine next risk mode
  $nextRiskOff = $false
  if ($pnl -le -[double]$DailyStopLoss) { $nextRiskOff = $true }
  if ($dd -ge [double]$MaxDrawdownGuard) { $nextRiskOff = $true }
  if ($ConsecLossStopDays -ge 1 -and $consecLoss -ge $ConsecLossStopDays) { $nextRiskOff = $true }

  $rows += [PSCustomObject]@{
    date = $d
    holdings = $rets.Length
    mode = $(if($riskOff){"RISK_OFF"}else{"NORMAL"})
    avg_ret = [math]::Round($avgDayRet, 6)
    exposure = [math]::Round($exposureScale, 4)
    pnl = [math]::Round($pnl, 6)
    equity = $equity
    peak = $peak
    drawdown = [math]::Round($dd, 6)
    consec_loss = $consecLoss
    risk_off_next = $nextRiskOff
  }

  $riskOff = $nextRiskOff
}

if ($rows.Length -eq 0) { throw "No portfolio curve rows generated. Check date overlap between allocation_log and all_stocks_daily." }

# Metrics
$finalEq = $equity
$totalRet = [math]::Round(($finalEq - $InitialEquity), 6)
$mdd = [math]::Round($mdd, 6)
$wins = (@($rows | Where-Object { $_.pnl -gt 0 })).Length
$winRate = [math]::Round(($wins / $rows.Length), 4)
$avgPnl = [math]::Round((($rows | Measure-Object pnl -Average).Average), 6)

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$csvOut  = Join-Path $resolvedOutDir "portfolio_curve_$ts.csv"
$htmlOut = Join-Path $resolvedOutDir "portfolio_curve_$ts.html"
$rows | Export-Csv $csvOut -NoTypeInformation -Encoding UTF8

# SVG
$w = 1000
$h = 260
$pad = 30
$eqVals = @($rows | Select-Object -ExpandProperty equity)
$minEq = ($eqVals | Measure-Object -Minimum).Minimum
$maxEq = ($eqVals | Measure-Object -Maximum).Maximum
if ($maxEq -eq $minEq) { $maxEq = $minEq + 1 }

function MapX([int]$i, [int]$count){
  if ($count -le 1) { return $pad }
  return [int]($pad + ($i-1) * (($w - 2*$pad) / ($count - 1)))
}
function MapY([double]$v){
  return [int]($pad + (($maxEq - $v) / ($maxEq - $minEq)) * ($h - 2*$pad))
}

$pts = ""
for ($i=1; $i -le $rows.Length; $i++) {
  $x = MapX $i $rows.Length
  $y = MapY ([double]$rows[$i-1].equity)
  $pts += "$x,$y "
}

$tail = ($rows | Select-Object -Last 160) | ForEach-Object {
  "<tr><td>$($_.date)</td><td>$($_.holdings)</td><td>$($_.mode)</td><td>$($_.avg_ret)</td><td>$($_.exposure)</td><td>$($_.pnl)</td><td>$($_.equity)</td><td>$($_.drawdown)</td><td>$($_.consec_loss)</td><td>$($_.risk_off_next)</td></tr>"
}
$tailHtml = ($tail -join "`n")

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>Portfolio Curve Report</title>
<style>
body { font-family: Arial; background:#111; color:#eee; }
.card { background:#1a1a1a; padding:12px; border-radius:8px; margin:10px 0; }
.small { color:#aaa; }
table { border-collapse: collapse; width:100%; margin-top:10px; }
th, td { padding:8px; border:1px solid #444; text-align:center; }
th { background:#222; }
</style>
</head>
<body>
<h2>Day-level Portfolio Curve (Weighted) + Risk Controls</h2>

<div class="card">
<div class="small">ProjectRoot=$ProjectRoot</div>
<div class="small">OutDir=$resolvedOutDir</div>
<div class="small">Days=$($rows.Length) | InitialEquity=$InitialEquity</div>
<div class="small">UseAllocationWeights=$UseAllocationWeights | ExposureCap=$ExposureCap</div>
<div class="small">DailyStopLoss=$DailyStopLoss | MaxDrawdownGuard=$MaxDrawdownGuard | RiskOffScale=$RiskOffScale | ConsecLossStopDays=$ConsecLossStopDays</div>
<p>Total Return: $totalRet</p>
<p>Win Rate (days): $winRate</p>
<p>Avg PnL / day: $avgPnl</p>
<p><b>Max Drawdown (MDD): $mdd</b></p>
<div class="small">CSV: $csvOut</div>
</div>

<div class="card">
<svg width="$w" height="$h" viewBox="0 0 $w $h" xmlns="http://www.w3.org/2000/svg">
  <rect x="0" y="0" width="$w" height="$h" fill="#111" />
  <polyline points="$pts" fill="none" stroke="#66ccff" stroke-width="2"/>
  <text x="$pad" y="18" fill="#aaa" font-size="12">Equity: min=$minEq max=$maxEq</text>
</svg>
</div>

<table>
<tr>
<th>Date</th><th>Holdings</th><th>Mode</th><th>AvgRet</th><th>Exposure</th><th>PnL</th><th>Equity</th><th>DD</th><th>ConsecLoss</th><th>RiskOffNext</th>
</tr>
$tailHtml
</table>
</body>
</html>
"@

[System.IO.File]::WriteAllText($htmlOut, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK: portfolio curve report generated -> $htmlOut" -ForegroundColor Green
Write-Host "OK: portfolio curve csv -> $csvOut" -ForegroundColor Green
if ($Open) { Start-Process $htmlOut | Out-Null }
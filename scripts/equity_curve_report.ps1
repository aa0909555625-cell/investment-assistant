#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$HoldingDays = 5,
  [double]$InitialEquity = 1.0,
  [string]$OutDir = ".\reports",
  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Anchor to project root (NOT current working directory) ----
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path

function Resolve-ProjectPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $ProjectRoot }
  if ([System.IO.Path]::IsPathRooted($p)) { return $p }

  $rel = $p.Trim()
  if ($rel.StartsWith(".\")) { $rel = $rel.Substring(2) }
  elseif ($rel.StartsWith("./")) { $rel = $rel.Substring(2) }

  return (Join-Path $ProjectRoot $rel)
}

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

# index: code -> sorted rows
$byCode = @{}
foreach ($r in $daily) {
  if (-not $r.code -or -not $r.date) { continue }
  if (-not $byCode.ContainsKey($r.code)) { $byCode[$r.code] = New-Object System.Collections.ArrayList }
  [void]$byCode[$r.code].Add($r)
}
foreach ($k in @($byCode.Keys)) {
  $byCode[$k] = @($byCode[$k] | Sort-Object date)
}

function Get-FutureRows([object[]]$codeRows, [datetime]$entryDate, [int]$n){
  $future = @()
  foreach ($rr in $codeRows) {
    if (-not $rr.date) { continue }
    $d = [datetime]$rr.date
    if ($d -gt $entryDate) { $future += $rr }
    if ($future.Length -ge $n) { break }
  }
  return @($future)
}

# compute trade returns
$trades = @()
foreach ($e in $log) {
  if (-not $e.code -or -not $e.date) { continue }
  $codeSym = [string]$e.code
  if (-not $byCode.ContainsKey($codeSym)) { continue }

  $entryDate = [datetime]$e.date
  $rows = @($byCode[$codeSym])

  $futureRows = Get-FutureRows -codeRows $rows -entryDate $entryDate -n $HoldingDays
  if ($futureRows.Length -ne $HoldingDays) { continue }

  $sumPct = 0.0
  foreach ($fr in $futureRows) { $sumPct += [double]$fr.change_percent }

  $ret = [math]::Round(($sumPct / 100.0), 4)

  $alloc = 0.0
  if ($null -ne $e.allocation -and $e.allocation -ne "") { $alloc = [double]$e.allocation }

  $trades += [PSCustomObject]@{
    date = $e.date
    code = $codeSym
    allocation = $alloc
    return = $ret
  }
}

$trades = @($trades | Sort-Object date, code)

if ($trades.Length -eq 0) {
  throw "No trades available for equity curve (insufficient future rows for HoldingDays=$HoldingDays)."
}

# equity curve (trade-level compounding)
$equity = [double]$InitialEquity
$peak = $equity
$mdd = 0.0

$curve = @()
$idx = 0

foreach ($t in $trades) {
  $idx++
  $equity = [math]::Round($equity * (1.0 + [double]$t.return), 6)

  if ($equity -gt $peak) { $peak = $equity }
  $dd = 0.0
  if ($peak -gt 0) { $dd = ($peak - $equity) / $peak }
  if ($dd -gt $mdd) { $mdd = $dd }

  $curve += [PSCustomObject]@{
    n = $idx
    date = $t.date
    code = $t.code
    ret = $t.return
    equity = $equity
    drawdown = [math]::Round($dd, 6)
  }
}

# metrics
$avgRet = [math]::Round((($trades | Measure-Object return -Average).Average), 4)
$win = (@($trades | Where-Object { $_.return -gt 0 })).Length
$winRate = [math]::Round(($win / $trades.Length), 4)
$totalRet = [math]::Round(($equity - $InitialEquity), 6)
$mdd = [math]::Round($mdd, 6)

$best  = $trades | Sort-Object return -Descending | Select-Object -First 1
$worst = $trades | Sort-Object return            | Select-Object -First 1

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$csvOut  = Join-Path $resolvedOutDir "equity_curve_$ts.csv"
$htmlOut = Join-Path $resolvedOutDir "equity_curve_$ts.html"

$curve | Export-Csv $csvOut -NoTypeInformation -Encoding UTF8

# simple SVG chart
$w = 1000
$h = 260
$pad = 30

$eqVals = @($curve | Select-Object -ExpandProperty equity)
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
for ($i=1; $i -le $curve.Length; $i++) {
  $x = MapX $i $curve.Length
  $y = MapY ([double]$curve[$i-1].equity)
  $pts += "$x,$y "
}

$lastRows = ($curve | Select-Object -Last 120) | ForEach-Object {
  "<tr><td>$($_.n)</td><td>$($_.date)</td><td>$($_.code)</td><td>$($_.ret)</td><td>$($_.equity)</td><td>$($_.drawdown)</td></tr>"
}
$lastRowsHtml = ($lastRows -join "`n")

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>Equity Curve Report</title>
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

<h2>Equity Curve + Max Drawdown (Trade-level)</h2>

<div class="card">
<div class="small">ProjectRoot=$ProjectRoot</div>
<div class="small">OutDir=$resolvedOutDir</div>
<div class="small">HoldingDays=$HoldingDays | Trades=$($trades.Length) | InitialEquity=$InitialEquity</div>
<p>Total Return: $totalRet</p>
<p>Win Rate: $winRate</p>
<p>Average Return / trade: $avgRet</p>
<p><b>Max Drawdown (MDD): $mdd</b></p>
<div class="small">Best: $($best.code) $([math]::Round([double]$best.return,4)) | Worst: $($worst.code) $([math]::Round([double]$worst.return,4))</div>
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
<th>#</th><th>Date</th><th>Code</th><th>Return</th><th>Equity</th><th>Drawdown</th>
</tr>
$lastRowsHtml
</table>

</body>
</html>
"@

[System.IO.File]::WriteAllText($htmlOut, $html, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "OK: equity curve report generated -> $htmlOut" -ForegroundColor Green
Write-Host "OK: equity curve csv -> $csvOut" -ForegroundColor Green

if ($Open) { Start-Process $htmlOut | Out-Null }
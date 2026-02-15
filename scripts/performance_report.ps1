#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$HoldingDays = 5,
  [string]$OutDir = ".\reports",
  [switch]$AllowPartial,
  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Anchor to project root ----
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
$outDirAbs = Resolve-ProjectPath $OutDir

if (!(Test-Path $logPath))   { throw "allocation_log.csv not found: $logPath" }
if (!(Test-Path $dailyPath)) { throw "all_stocks_daily.csv not found: $dailyPath" }
if (!(Test-Path $outDirAbs)) { New-Item -ItemType Directory -Force -Path $outDirAbs | Out-Null }

$log   = @((Import-Csv $logPath))
$daily = @((Import-Csv $dailyPath))

if ($log.Length -eq 0)   { throw "allocation_log.csv is empty: $logPath" }
if ($daily.Length -eq 0) { throw "all_stocks_daily.csv is empty: $dailyPath" }

# index daily by code, sorted by date
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

$used = @()
$missingCode = 0
$noFuture = 0
$full = 0
$partial = 0

foreach ($e in $log) {
  if (-not $e.code -or -not $e.date) { continue }

  $code = [string]$e.code
  if (-not $byCode.ContainsKey($code)) { $missingCode++; continue }

  $entryDate = [datetime]$e.date
  $rows = @($byCode[$code])

  $futureRows = Get-FutureRows -codeRows $rows -entryDate $entryDate -n $HoldingDays

  if ($futureRows.Length -lt 1) { $noFuture++; continue }

  $isPartial = $false
  if ($futureRows.Length -ne $HoldingDays) {
    if (-not $AllowPartial) { $noFuture++; continue }
    $isPartial = $true
  }

  $sumPct = 0.0
  foreach ($fr in $futureRows) { $sumPct += [double]$fr.change_percent }

  $ret = [math]::Round(($sumPct / 100.0), 6)

  $alloc = 0.0
  if ($null -ne $e.allocation -and $e.allocation -ne "") { $alloc = [double]$e.allocation }

  if ($isPartial) { $partial++ } else { $full++ }

  $used += [PSCustomObject]@{
    entry_date = $e.date
    code = $code
    allocation = $alloc
    holding_days_used = $futureRows.Length
    return = $ret
    partial = $isPartial
  }
}

$used = @($used | Sort-Object entry_date, code)

if ($used.Length -eq 0) {
  throw ("No performance data available. total_log={0} missing_code={1} no_future_or_insufficient={2}. Tip: use -AllowPartial or reduce -HoldingDays." -f $log.Length, $missingCode, $noFuture)
}

# metrics
$avgRet = [math]::Round((($used | Measure-Object return -Average).Average), 6)
$win = (@($used | Where-Object { $_.return -gt 0 })).Length
$winRate = [math]::Round(($win / $used.Length), 4)
$totalRet = [math]::Round((($used | Measure-Object return -Sum).Sum), 6)

$best  = $used | Sort-Object return -Descending | Select-Object -First 1
$worst = $used | Sort-Object return            | Select-Object -First 1

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$htmlOut = Join-Path $outDirAbs ("performance_report_{0}.html" -f $ts)
$csvOut  = Join-Path $outDirAbs ("performance_report_{0}.csv" -f $ts)

$used | Export-Csv $csvOut -NoTypeInformation -Encoding UTF8

$rowsHtml = ($used | Select-Object -First 400 | ForEach-Object {
  $p = if ($_.partial) { "Y" } else { "" }
  "<tr><td>$($_.entry_date)</td><td>$($_.code)</td><td>$($_.allocation)</td><td>$($_.holding_days_used)</td><td>$($_.return)</td><td>$p</td></tr>"
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>Performance Report</title>
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

<h2>Performance Report (HoldingDays=$HoldingDays)</h2>

<div class="card">
<div class="small">ProjectRoot=$ProjectRoot</div>
<div class="small">OutDir=$outDirAbs</div>
<div class="small">AllowPartial: $AllowPartial | Records used: $($used.Length)</div>
<div class="small">Missing code in daily: $missingCode | No future/insufficient: $noFuture</div>
<div class="small">Full: $full | Partial: $partial</div>
<p>Total Return (sum of trade returns): $totalRet</p>
<p>Win Rate: $winRate</p>
<p>Average Return / trade: $avgRet</p>
<div class="small">Best: $($best.code) $([math]::Round([double]$best.return,6)) | Worst: $($worst.code) $([math]::Round([double]$worst.return,6))</div>
<div class="small">CSV: $csvOut</div>
</div>

<table>
<tr><th>Entry Date</th><th>Code</th><th>Allocation</th><th>Days Used</th><th>Return</th><th>Partial</th></tr>
$rowsHtml
</table>

</body>
</html>
"@

[System.IO.File]::WriteAllText($htmlOut, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK: performance report generated -> $htmlOut" -ForegroundColor Green
Write-Host "OK: performance csv -> $csvOut" -ForegroundColor Green
if ($Open) { Start-Process $htmlOut | Out-Null }
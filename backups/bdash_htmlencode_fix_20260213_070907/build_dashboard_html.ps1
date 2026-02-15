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

function HtmlEncode([string]$s){
  if ($null -eq $s) { return "" }
  return [System.Net.WebUtility]::HtmlEncode($s)
}

$decisionsPath = Resolve-ProjectPath ".\data\all_stocks_decisions.csv"
$marketSnapPath = Resolve-ProjectPath ".\data\market_snapshot.csv"
$outDirPath = Resolve-ProjectPath $OutDir

if (!(Test-Path $decisionsPath)) { throw "decisions.csv not found: $decisionsPath" }
if (!(Test-Path $outDirPath)) { New-Item -ItemType Directory -Force -Path $outDirPath | Out-Null }

$decisions = @((Import-Csv $decisionsPath))
if ($decisions.Length -eq 0) { throw "decisions.csv is empty: $decisionsPath" }

$allDates = @($decisions | Select-Object -ExpandProperty date | Where-Object { $_ } | Sort-Object -Unique)
if ($ListDates) {
  $allDates -join ", "
  return
}

$targetDate = $Date
if ([string]::IsNullOrWhiteSpace($targetDate)) {
  $targetDate = ($allDates | Sort-Object | Select-Object -Last 1)
}
if ([string]::IsNullOrWhiteSpace($targetDate)) { throw "Cannot determine target date from decisions." }

$rows = @($decisions | Where-Object { $_.date -eq $targetDate })
if ($rows.Length -eq 0) { throw "No decisions rows for Date=$targetDate in $decisionsPath" }

# ---- Score bands summary (to feel like "盤口") ----
$cnt80 = (@($rows | Where-Object { [double]$_.total_score -ge 80 })).Length
$cnt70 = (@($rows | Where-Object { [double]$_.total_score -ge 70 -and [double]$_.total_score -lt 80 })).Length
$cnt60 = (@($rows | Where-Object { [double]$_.total_score -ge 60 -and [double]$_.total_score -lt 70 })).Length
$cntLo = $rows.Length - $cnt80 - $cnt70 - $cnt60

$avgScore = [math]::Round((($rows | Measure-Object total_score -Average).Average), 2)
$avgChg   = [math]::Round((($rows | Measure-Object change_percent -Average).Average), 4)

# ---- Capital allocation (simple, stable) ----
# pick top N (cap at 20) from the decisions rows by total_score desc
$pickN = 12
$picks = @($rows | Sort-Object { [double]$_.total_score } -Descending | Select-Object -First $pickN)

# weights = positive scores (avoid divide by 0)
$weights = @()
foreach ($p in $picks) {
  $w = [double]$p.total_score
  if ($w -lt 1) { $w = 1 }
  $weights += $w
}
$wSum = ($weights | Measure-Object -Sum).Sum
if ($null -eq $wSum -or $wSum -le 0) { $wSum = 1 }

$allocRows = @()
for ($i=0; $i -lt $picks.Length; $i++) {
  $p = $picks[$i]
  $w = $weights[$i]
  $alloc = [math]::Floor($Capital * ($w / $wSum))
  $allocRows += [PSCustomObject]@{
    code = [string]$p.code
    name = [string]$p.name
    sector = [string]$p.sector
    change = [double]$p.change_percent
    score = [double]$p.total_score
    allocation = $alloc
    warnings = [string]$p.warnings
  }
}

# ---- Market Snapshot (optional) ----
$ms = $null
$sectorHeat = @()
if (Test-Path $marketSnapPath) {
  try {
    $msRows = @((Import-Csv $marketSnapPath))
    $ms = @{}
    foreach ($r in $msRows) {
      if ($r.kind -eq "snapshot") { $ms[$r.key] = $r.value }
      elseif ($r.kind -eq "sector_heat") { $sectorHeat += $r.value }
    }
  } catch {
    # ignore snapshot parsing errors (dashboard must still work)
    $ms = $null
    $sectorHeat = @()
  }
}

function GetMS([string]$k, [string]$fallback=""){
  if ($null -eq $ms) { return $fallback }
  if ($ms.ContainsKey($k)) { return [string]$ms[$k] }
  return $fallback
}

$msDate = GetMS "date" ""
$msUniverse = GetMS "universe" ""
$msUp = GetMS "up" ""
$msDown = GetMS "down" ""
$msFlat = GetMS "flat" ""
$msAvg = GetMS "avg_change" ""
$msMed = GetMS "median_change" ""
$msTone = GetMS "risk_tone" ""

$sectorHeatRowsHtml = ""
if ($sectorHeat.Length -gt 0) {
  foreach ($line in $sectorHeat) {
    # format: sector|n=..|avg_score=..|avg_change=..
    $parts = $line -split "\|"
    $sec = if ($parts.Length -ge 1) { $parts[0] } else { "unknown" }
    $n   = if ($parts.Length -ge 2) { $parts[1] } else { "" }
    $as  = if ($parts.Length -ge 3) { $parts[2] } else { "" }
    $ac  = if ($parts.Length -ge 4) { $parts[3] } else { "" }
    $sectorHeatRowsHtml += "<tr><td>" + (HtmlEncode $sec) + "</td><td>" + (HtmlEncode $n) + "</td><td>" + (HtmlEncode $as) + "</td><td>" + (HtmlEncode $ac) + "</td></tr>`n"
  }
} else {
  $sectorHeatRowsHtml = "<tr><td colspan=`"4`" class=`"muted`">market_snapshot.csv not found or no sector heat data</td></tr>`n"
}

# ---- Build HTML ----
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$outPath = Join-Path $outDirPath ("tw_dashboard_{0}_{1}.html" -f $targetDate, $ts)

$allocHtml = ""
foreach ($a in $allocRows) {
  $allocHtml += "<tr>" +
    "<td>" + (HtmlEncode $a.code) + "</td>" +
    "<td>" + (HtmlEncode $a.name) + "</td>" +
    "<td>" + (HtmlEncode $a.sector) + "</td>" +
    "<td>" + ([math]::Round([double]$a.change,4)) + "%</td>" +
    "<td>" + ([math]::Round([double]$a.score,2)) + "</td>" +
    "<td>" + ([int]$a.allocation) + "</td>" +
    "<td class=`"muted`">" + (HtmlEncode $a.warnings) + "</td>" +
  "</tr>`n"
}

$marketCard = @"
<div class="card">
  <h3>Market Tape (Snapshot)</h3>
  <div class="grid">
    <div class="kpi"><div class="k">Date</div><div class="v">$([HtmlEncode]($msDate))</div></div>
    <div class="kpi"><div class="k">Universe</div><div class="v">$([HtmlEncode]($msUniverse))</div></div>
    <div class="kpi"><div class="k">Up / Down / Flat</div><div class="v">$([HtmlEncode]($msUp)) / $([HtmlEncode]($msDown)) / $([HtmlEncode]($msFlat))</div></div>
    <div class="kpi"><div class="k">Avg% / Med%</div><div class="v">$([HtmlEncode]($msAvg)) / $([HtmlEncode]($msMed))</div></div>
    <div class="kpi"><div class="k">Risk Tone</div><div class="v badge">$([HtmlEncode]($msTone))</div></div>
  </div>

  <h4 style="margin-top:14px;">Sector Heat (Top)</h4>
  <table>
    <tr><th>Sector</th><th>n</th><th>avg_score</th><th>avg_change</th></tr>
    $sectorHeatRowsHtml
  </table>

  <div class="muted" style="margin-top:10px;">
    If snapshot looks empty: run <code>.\scripts\build_market_snapshot.ps1</code> after rebuilding daily.
  </div>
</div>
"@

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>TW Dashboard</title>
<style>
body { font-family: Arial, sans-serif; background:#0f0f10; color:#eee; margin:18px; }
h2,h3,h4 { margin: 6px 0 10px 0; }
.card { background:#17171a; border:1px solid #2a2a2f; border-radius:10px; padding:14px; margin:12px 0; }
.muted { color:#a8a8b3; font-size:12px; }
.grid { display:grid; grid-template-columns: repeat(5, minmax(160px, 1fr)); gap:10px; }
.kpi { background:#121215; border:1px solid #2a2a2f; border-radius:10px; padding:10px; }
.k { font-size:12px; color:#a8a8b3; }
.v { font-size:18px; font-weight:700; margin-top:6px; }
.badge { display:inline-block; padding:3px 10px; border-radius:999px; border:1px solid #2a2a2f; }
table { border-collapse: collapse; width:100%; margin-top:10px; }
th, td { padding:8px; border:1px solid #2a2a2f; text-align:center; }
th { background:#1f1f25; }
code { background:#0b0b0c; padding:2px 6px; border-radius:6px; border:1px solid #2a2a2f; }
</style>
</head>
<body>

<h2>TW Dashboard</h2>
<div class="muted">ProjectRoot: $ProjectRoot</div>
<div class="muted">Source: all_stocks_decisions.csv | Date=$targetDate | Capital=$Capital</div>

$marketCard

<div class="card">
  <h3>Decision Tape (Score Bands)</h3>
  <div class="grid" style="grid-template-columns: repeat(5, minmax(160px, 1fr));">
    <div class="kpi"><div class="k">Avg Score</div><div class="v">$avgScore</div></div>
    <div class="kpi"><div class="k">Avg Change%</div><div class="v">$avgChg%</div></div>
    <div class="kpi"><div class="k">>= 80</div><div class="v">$cnt80</div></div>
    <div class="kpi"><div class="k">70-79</div><div class="v">$cnt70</div></div>
    <div class="kpi"><div class="k">< 70</div><div class="v">$($cnt60 + $cntLo)</div></div>
  </div>
  <div class="muted" style="margin-top:10px;">
    Interpretation hint: more 80+ means stronger conviction set; risk tone helps decide exposure.
  </div>
</div>

<div class="card">
  <h3>Suggested Allocation (Top $pickN)</h3>
  <table>
    <tr>
      <th>Code</th><th>Name</th><th>Sector</th><th>Chg%</th><th>Score</th><th>NTD</th><th>Warnings</th>
    </tr>
    $allocHtml
  </table>
  <div class="muted" style="margin-top:10px;">
    Note: allocation is proportional to total_score (stable baseline). Risk controls are handled in portfolio_curve_report.
  </div>
</div>

</body>
</html>
"@

[System.IO.File]::WriteAllText($outPath, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("OK: wrote HTML -> {0}" -f $outPath) -ForegroundColor Green
if ($Open) { Start-Process $outPath | Out-Null }
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

function SafeTrim([object]$v){
  if($null -eq $v){ return "" }
  return ($v.ToString()).Trim()
}
function ToInt([object]$v, [int]$def=0){
  $s = SafeTrim $v
  if([string]::IsNullOrWhiteSpace($s)){ return $def }
  try { return [int]([double]$s) } catch { return $def }
}
function ToDbl([object]$v, [double]$def=0){
  $s = SafeTrim $v
  if([string]::IsNullOrWhiteSpace($s)){ return $def }
  try { return [double]$s } catch { return $def }
}
function HtmlEncode([string]$s){
  if($null -eq $s){ return "" }
  return [System.Net.WebUtility]::HtmlEncode($s)
}

function Read-AllStocksDaily([string]$path){
  if(!(Test-Path $path)){ throw ("Missing file: {0}" -f $path) }
  $rows = Import-Csv $path
  if(@($rows).Count -lt 1){ throw ("Empty csv: {0}" -f $path) }
  return @($rows)
}

function Get-AvailableDates($rows){
  return @($rows | Select-Object -ExpandProperty date -Unique | Sort-Object)
}

function Read-MarketSnapshot([string]$path){
  if(!(Test-Path $path)){ return $null }
  try{
    $raw = Get-Content $path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
  }catch{
    return $null
  }
}

function Pick-TargetDate([string]$dateParam, $rows, $mkt){
  $dates = @(Get-AvailableDates $rows)

  if($ListDates){
    $dates | ForEach-Object { $_ } | Out-Host
    exit 0
  }

  # If user specified, respect (must exist or prefix-match)
  if(-not [string]::IsNullOrWhiteSpace($dateParam)){
    if($dates -contains $dateParam){ return $dateParam }
    $match = @($dates | Where-Object { $_ -like "$dateParam*" } | Select-Object -Last 1)
    if(@($match).Count -gt 0){ return $match[0] }
    throw ("Date not found in all_stocks_daily.csv: {0}" -f $dateParam)
  }

  # Prefer market snapshot date if it exists in CSV dates (prevents weekend query-date mismatch)
  if($null -ne $mkt -and $null -ne $mkt.date){
    $md = SafeTrim $mkt.date
    if(-not [string]::IsNullOrWhiteSpace($md) -and ($dates -contains $md)){
      return $md
    }
  }

  # Fallback: latest available date in CSV
  return $dates[-1]
}

function Build-ScoreBuckets([double]$avgScore){
  if($avgScore -ge 80){
    return @{
      band = "HOT"
      suggestion = "Market is hot: pick only high-score names; scale-in; tighten risk control."
      ranges = @(
        @{ name="ATTACK"; min=85; max=100 },
        @{ name="CORE";   min=78; max=85  },
        @{ name="WATCH";  min=70; max=78  },
        @{ name="AVOID";  min=0;  max=70  }
      )
    }
  } elseif($avgScore -ge 65){
    return @{
      band = "NEUTRAL_BULL"
      suggestion = "Neutral-bull: focus CORE, small ATTACK, WATCH for confirmation."
      ranges = @(
        @{ name="ATTACK"; min=80; max=100 },
        @{ name="CORE";   min=70; max=80  },
        @{ name="WATCH";  min=60; max=70  },
        @{ name="AVOID";  min=0;  max=60  }
      )
    }
  } else {
    return @{
      band = "COLD"
      suggestion = "Market is cold: reduce trades; rely on market filter; emphasize risk control."
      ranges = @(
        @{ name="ATTACK"; min=78; max=100 },
        @{ name="CORE";   min=65; max=78  },
        @{ name="WATCH";  min=55; max=65  },
        @{ name="AVOID";  min=0;  max=55  }
      )
    }
  }
}

# ---- main ----
$root = (Resolve-Path ".").Path
$dataPath = Join-Path $root "data\all_stocks_daily.csv"
$rows = Read-AllStocksDaily $dataPath

$mkt = Read-MarketSnapshot (Join-Path $root "data\market_snapshot_taiex.json")
$targetDate = Pick-TargetDate $Date $rows $mkt
Write-Host ("[INFO] TargetDate = {0}" -f $targetDate) -ForegroundColor Cyan

$todayRows = @($rows | Where-Object { $_.date -eq $targetDate })
if($todayRows.Count -lt 1){ throw ("No rows for date={0}" -f $targetDate) }

$total = $todayRows.Count
$topN = [Math]::Min($Top, $total)

$avgScore = 0.0
$maxScore = -1e9
$minScore = 1e9
$pos = 0
$neg = 0

foreach($r in $todayRows){
  $s = ToDbl $r.total_score 0
  $avgScore += $s
  if($s -gt $maxScore){ $maxScore = $s }
  if($s -lt $minScore){ $minScore = $s }
  $cp = ToDbl $r.change_percent 0
  if($cp -ge 0){ $pos++ } else { $neg++ }
}
$avgScore = if($total -gt 0){ $avgScore / $total } else { 0 }

$topRows = @(
  $todayRows |
    Sort-Object @{Expression={ ToDbl $_.total_score 0 }; Descending=$true} |
    Select-Object -First $topN
)

$bucket = Build-ScoreBuckets $avgScore

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add(("Universe {0} | Up {1} | Down {2} | AvgScore {3:N1} | Max {4:N1} | Min {5:N1}" -f $total, $pos, $neg, $avgScore, $maxScore, $minScore))
$summaryLines.Add(("ScoreBand {0}: {1}" -f $bucket.band, $bucket.suggestion))

if($null -ne $mkt){
  $summaryLines.Add(("TAIEX {0} | Close {1:N0} | Chg {2:N2}% | SMA50 {3:N0} | SMA200 {4:N0} | MarketOK={5} | TrendOK={6} | {7}" -f $mkt.date, $mkt.close, $mkt.chg_pct, $mkt.sma_fast, $mkt.sma_slow, $mkt.market_ok, $mkt.trend_ok, $mkt.risk_mode))
} else {
  $summaryLines.Add("TAIEX: market_snapshot_taiex.json missing (run scripts/market_snapshot.py)")
}

$kpiHtml = @"
<div class="grid">
  <div class="card">
    <div class="label">MARKET OVERVIEW</div>
    <div class="value">$((HtmlEncode $targetDate))</div>
    <div class="muted">rows=$total / Top=$topN / capital=$Capital</div>
  </div>
  <div class="card">
    <div class="label">SCORE</div>
    <div class="value">avg $([Math]::Round($avgScore,1))</div>
    <div class="muted">min $([Math]::Round($minScore,1)) / max $([Math]::Round($maxScore,1))</div>
  </div>
  <div class="card">
    <div class="label">ADV/DEC</div>
    <div class="value">+$pos / -$neg</div>
    <div class="muted">adv% $([Math]::Round(($pos*100.0)/[Math]::Max(1,$total),1))%</div>
  </div>
"@

if($null -ne $mkt){
  $riskBadge = if($mkt.risk_mode -eq "RISK_ON"){ "badge on" } else { "badge off" }
  $kpiHtml += @"
  <div class="card">
    <div class="label">TAIEX</div>
    <div class="value">$([Math]::Round([double]$mkt.close,0))</div>
    <div class="muted">
      <span class="$riskBadge">$((HtmlEncode $mkt.risk_mode))</span>
      <span style="margin-left:10px;">date $((HtmlEncode $mkt.date))</span>
      <span style="margin-left:10px;">chg $([Math]::Round([double]$mkt.chg_pct,2))%</span>
      <span style="margin-left:10px;">SMA50 $([Math]::Round([double]$mkt.sma_fast,0))</span>
      <span style="margin-left:10px;">SMA200 $([Math]::Round([double]$mkt.sma_slow,0))</span>
    </div>
  </div>
"@
} else {
  $kpiHtml += @"
  <div class="card">
    <div class="label">TAIEX</div>
    <div class="value">N/A</div>
    <div class="muted">missing market snapshot json</div>
  </div>
"@
}
$kpiHtml += "</div>"

$rangeRows = $bucket.ranges | ForEach-Object {
  "<tr><td class='tdname'>$(HtmlEncode $_.name)</td><td>$($_.min) ~ $($_.max)</td></tr>"
} | Out-String

$rangeHtml = @"
<div class="card" style="margin-top:14px;">
  <div class="label">SCORE BAND ($((HtmlEncode $bucket.band)))</div>
  <div class="muted" style="margin-top:6px;">$((HtmlEncode $bucket.suggestion))</div>
  <table class="tbl" style="margin-top:10px;">
    <thead><tr><th>BUCKET</th><th>RANGE</th></tr></thead>
    <tbody>
      $rangeRows
    </tbody>
  </table>
</div>
"@

$summaryHtml = ($summaryLines | ForEach-Object { "<li>" + (HtmlEncode $_) + "</li>" }) -join "`n"
$summaryBox = @"
<div class="card" style="margin-top:14px;">
  <div class="label">TAPE SUMMARY</div>
  <ul class="ul">
    $summaryHtml
  </ul>
</div>
"@

$topTr = $topRows | ForEach-Object {
  $code = HtmlEncode (SafeTrim $_.code)
  $name = HtmlEncode (SafeTrim $_.name)
  $sector = HtmlEncode (SafeTrim $_.sector)
  $chg = [Math]::Round((ToDbl $_.change_percent 0), 2)
  $score = [Math]::Round((ToDbl $_.total_score 0), 2)
  "<tr><td class='mono'>$code</td><td>$name</td><td>$sector</td><td class='num'>$chg</td><td class='num'>$score</td></tr>"
} | Out-String

$topTable = @"
<div class="card" style="margin-top:14px;">
  <div class="label">TOP $topN (by score)</div>
  <table class="tbl" style="margin-top:10px;">
    <thead><tr><th>CODE</th><th>NAME</th><th>SECTOR</th><th>CHG%</th><th>SCORE</th></tr></thead>
    <tbody>
      $topTr
    </tbody>
  </table>
</div>
"@

$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dashboard - $targetDate</title>
<style>
  body{ font-family: -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans TC",Arial,sans-serif; margin:18px; background:#0b0f14; color:#e8eef6;}
  .wrap{ max-width: 1200px; margin: 0 auto; }
  .h1{ font-size: 22px; font-weight: 800; margin: 0 0 12px 0; }
  .grid{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; }
  .card{ background: #111826; border:1px solid #1f2b3d; border-radius: 14px; padding: 14px 14px; box-shadow: 0 10px 30px rgba(0,0,0,0.25); }
  .label{ font-size: 12px; letter-spacing: .08em; color:#9bb0c9; }
  .value{ font-size: 22px; font-weight: 750; margin-top:6px; }
  .muted{ color:#b9c7db; font-size: 13px; margin-top:6px; line-height: 1.45; }
  .badge{ display:inline-block; padding:2px 10px; border-radius:999px; font-size:12px; border:1px solid #2b3b52; }
  .badge.on{ background: rgba(46,204,113,.12); border-color: rgba(46,204,113,.35); }
  .badge.off{ background: rgba(231,76,60,.12); border-color: rgba(231,76,60,.35); }
  table{ width:100%; border-collapse: collapse; }
  th, td{ padding: 10px 10px; border-bottom: 1px solid #1f2b3d; }
  th{ text-align:left; color:#9bb0c9; font-weight:600; }
  .mono{ font-family: ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono","Courier New",monospace; }
  .num{ text-align:right; font-variant-numeric: tabular-nums; }
  .ul{ margin:10px 0 0 18px; padding:0; }
  @media (max-width: 1000px){ .grid{ grid-template-columns: repeat(2, 1fr); } }
  @media (max-width: 520px){ .grid{ grid-template-columns: 1fr; } }
</style>
</head>
<body>
<div class="wrap">
  <div class="h1">Market Dashboard + Market Filter ($targetDate)</div>
  $kpiHtml
  $summaryBox
  $rangeHtml
  $topTable
  <div class="muted" style="margin-top:14px;">Generated by scripts/build_dashboard_html.ps1</div>
</div>
</body>
</html>
"@

if(!(Test-Path $OutDir)){ New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$outPath = Join-Path (Resolve-Path $OutDir).Path ("dashboard_{0}.html" -f $targetDate)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outPath, $html.Replace("`r`n","`n").Replace("`n","`r`n"), $utf8NoBom)

Write-Host ("OK: wrote HTML -> {0}" -f $outPath) -ForegroundColor Green
if($Open){ Start-Process $outPath | Out-Null }
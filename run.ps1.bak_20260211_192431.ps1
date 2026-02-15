param(
  [Parameter(Mandatory=$false)]
  [int]$Cash = 300000,

  [Parameter(Mandatory=$false)]
  [switch]$OpenReport,

  [Parameter(Mandatory=$false)]
  [switch]$EnsureSampleData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$path) {
  if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

function Ensure-File([string]$path, [string]$content) {
  if (Test-Path $path) {
    Write-Host "SKIP: exists -> $path"
  } else {
    $content | Set-Content -Path $path -Encoding UTF8
    Write-Host "OK: created -> $path"
  }
}

function Get-LevelWeight([string]$level) {
  switch ($level) {
    "HOT3" { 3 }
    "HOT2" { 2 }
    "HOT1" { 1 }
    default { 0 }
  }
}

# ----------------------------
# Paths
# ----------------------------
$basePath   = ".\data"
$reportsDir = ".\reports"
Ensure-Dir $basePath
Ensure-Dir $reportsDir

$indexFile  = Join-Path $basePath "index_daily.csv"
$stockFile  = Join-Path $basePath "stocks_daily.csv"
$marketFile = Join-Path $basePath "market_daily.csv"

# ----------------------------
# Optional: create sample data (only if missing)
# ----------------------------
if ($EnsureSampleData) {
  Ensure-File $indexFile @"
index_code,date,close
TWSE,2026-02-10,19120.30
TWSE,2026-02-11,19230.45
OTC,2026-02-10,244.20
OTC,2026-02-11,243.18
"@

  Ensure-File $stockFile @"
stock_id,sector,change_percent
2330,半導體,1.8
2317,半導體,-0.3
2454,半導體,0.5
AI001,AI,2.5
AI002,AI,1.9
AI003,AI,-0.4
AI004,AI,2.1
2603,航運,-1.6
2609,航運,-2.0
2615,航運,-1.8
"@

  Ensure-File $marketFile @"
date,up_count,down_count,flat_count,limit_up,limit_down,volume
2026-02-10,720,680,150,30,12,3100
2026-02-11,812,632,128,42,9,3820
"@
}

# ----------------------------
# Require data files
# ----------------------------
$missing = @()
foreach ($f in @($indexFile,$stockFile,$marketFile)) {
  if (!(Test-Path $f)) { $missing += $f }
}
if ($missing.Count -gt 0) {
  Write-Host "MISSING FILES:" -ForegroundColor Red
  $missing | ForEach-Object { Write-Host $_ }
  Write-Host "`nFix options:"
  Write-Host "  1) .\run.ps1 -EnsureSampleData"
  Write-Host "  2) Put real CSVs into .\data\ (index_daily.csv / stocks_daily.csv / market_daily.csv)"
  exit 1
}

# ----------------------------
# Load CSVs
# ----------------------------
$indexData  = Import-Csv $indexFile
$stockData  = Import-Csv $stockFile
$marketData = Import-Csv $marketFile

$heatWeight = 10
$now = Get-Date
$stamp = $now.ToString("yyyyMMdd_HHmmss")

# ----------------------------
# 1) INDEX SUMMARY
# ----------------------------
$indexSummary = @()
$indexData | Group-Object index_code | ForEach-Object {
  $grp = @($_.Group)  # FIX: force array
  if ($grp.Count -lt 2) { return }

  $rows = $grp | Sort-Object { [datetime]$_.date }
  $today = $rows[-1]; $y = $rows[-2]
  $todayClose = [double]$today.close; $yClose = [double]$y.close
  if ($yClose -eq 0) { return }

  $chg = $todayClose - $yClose
  $pct = ($chg / $yClose) * 100
  $dir = if ($pct -gt 0) { "UP" } elseif ($pct -lt 0) { "DOWN" } else { "FLAT" }

  $indexSummary += [pscustomobject]@{
    index_code   = $today.index_code
    date         = $today.date
    close        = [math]::Round($todayClose,2)
    change_point = [math]::Round($chg,2)
    change_pct   = [math]::Round($pct,2)
    direction    = $dir
  }
}

# ----------------------------
# 2) SECTOR HEAT
# ----------------------------
$sectorHeat = @()
$stockData | Group-Object sector | ForEach-Object {
  $g = @($_.Group)  # FIX: force array (prevents Count error under StrictMode)
  if ($g.Count -eq 0) { return }

  $up   = ($g | Where-Object { [double]$_.change_percent -gt 0 }).Count
  $down = ($g | Where-Object { [double]$_.change_percent -lt 0 }).Count
  $flat = ($g | Where-Object { [double]$_.change_percent -eq 0 }).Count
  $avg  = ($g | Measure-Object change_percent -Average).Average
  if ($null -eq $avg) { $avg = 0 }

  $score = ($up - $down) + ($avg * $heatWeight)

  $level = if ($score -ge 20) { "HOT3" }
    elseif ($score -ge 10) { "HOT2" }
    elseif ($score -gt 0) { "HOT1" }
    elseif ($score -eq 0) { "NEUTRAL" }
    elseif ($score -le -10) { "COLD3" }
    else { "COLD1" }

  $sectorHeat += [pscustomobject]@{
    sector     = $_.Name
    score      = [math]::Round([double]$score,2)
    level      = $level
    up         = $up
    down       = $down
    flat       = $flat
    avg_change = [math]::Round([double]$avg,2)
  }
}

$sectorHeat = @($sectorHeat | Sort-Object score -Descending)
$hotSectors = @($sectorHeat | Where-Object { $_.level -in @("HOT3","HOT2","HOT1") })

$wTotal = 0
foreach ($s in $hotSectors) { $wTotal += (Get-LevelWeight $s.level) }

function Build-SectorAllocation([int]$investCash) {
  $alloc = @()
  foreach ($s in $hotSectors) {
    $w = Get-LevelWeight $s.level
    $r = if ($wTotal -gt 0) { $w / $wTotal } else { 0 }
    $alloc += [pscustomobject]@{
      sector = $s.sector
      level  = $s.level
      score  = $s.score
      weight = $w
      ratio  = [math]::Round($r,4)
      cash   = [math]::Round($investCash * $r)
    }
  }
  return @($alloc | Sort-Object cash -Descending)
}

# ----------------------------
# 3) MARKET TREND + REASONS
# ----------------------------
$marketTrend = "UNKNOWN"
$trendReasons = @()
if (@($marketData).Count -ge 2) {
  $rows = @($marketData | Sort-Object { [datetime]$_.date })
  $t = $rows[-1]; $y = $rows[-2]

  $c1 = ([int]$t.up_count -gt [int]$t.down_count)
  $c2 = ([double]$t.volume -gt [double]$y.volume)
  $c3 = ([int]$t.limit_up -gt [int]$t.limit_down)

  $trendReasons += $(if ($c1) { "advancers>decliners" } else { "advancers<=decliners" })
  $trendReasons += $(if ($c2) { "volume_up" } else { "volume_down_or_flat" })
  $trendReasons += $(if ($c3) { "limit_up>limit_down" } else { "limit_up<=limit_down" })

  $marketTrend = if ($c1 -and $c2 -and $c3) { "BULL" } else { "BEAR" }
}

# ----------------------------
# 4) Step 7-4 Dashboard
# ----------------------------
$investRatio = switch ($marketTrend) {
  "BULL" { 0.6 }
  "BEAR" { 0.2 }
  default { 0.4 }
}

$investCash  = [math]::Round($Cash * $investRatio)
$reserveCash = $Cash - $investCash
$dashAlloc   = Build-SectorAllocation $investCash

$dashboard = [pscustomobject]@{
  generated_at = $now.ToString("s")
  inputs = @{ user_cash=$Cash; heat_weight=$heatWeight }
  index_summary = $indexSummary
  market_trend = @{
    trend = $marketTrend
    reasons = $trendReasons
    invest_ratio = $investRatio
    invest_cash = $investCash
    reserve_cash = $reserveCash
  }
  sector_heat = $sectorHeat
  sector_allocation = $dashAlloc
}

$dashJson = Join-Path $reportsDir ("dashboard_{0}.json" -f $stamp)
$dashTxt  = Join-Path $reportsDir ("dashboard_{0}.txt"  -f $stamp)
$dashboard | ConvertTo-Json -Depth 10 | Set-Content -Path $dashJson -Encoding UTF8

$lines = @()
$lines += "DASHBOARD"
$lines += "generated_at=$($dashboard.generated_at)"
$lines += "user_cash=$Cash"
$lines += ""
$lines += "[INDEX]"
foreach ($i in $indexSummary) { $lines += ("{0} close={1} {2} {3}% (chg={4})" -f $i.index_code,$i.close,$i.direction,$i.change_pct,$i.change_point) }
$lines += ""
$lines += "[MARKET]"
$lines += ("trend={0} reasons={1}" -f $marketTrend, ($trendReasons -join ", "))
$lines += ("invest_ratio={0} invest_cash={1} reserve_cash={2}" -f $investRatio,$investCash,$reserveCash)
$lines += ""
$lines += "[SECTOR ALLOCATION]"
if (@($dashAlloc).Count -eq 0) { $lines += "(none)" } else {
  foreach ($a in $dashAlloc) { $lines += ("- {0} {1} cash={2} (ratio={3})" -f $a.sector,$a.level,$a.cash,$a.ratio) }
}
$lines | Set-Content -Path $dashTxt -Encoding UTF8

# ----------------------------
# 5) Step 7-5 Scenarios
# ----------------------------
$scenarioRatios = @()
if ($marketTrend -eq "BULL") {
  $scenarioRatios = @(
    @{ name="CONSERVATIVE"; ratio=0.40 },
    @{ name="BALANCED";     ratio=0.60 },
    @{ name="AGGRESSIVE";   ratio=0.80 }
  )
} elseif ($marketTrend -eq "BEAR") {
  $scenarioRatios = @(
    @{ name="CONSERVATIVE"; ratio=0.10 },
    @{ name="BALANCED";     ratio=0.20 },
    @{ name="AGGRESSIVE";   ratio=0.30 }
  )
} else {
  $scenarioRatios = @(
    @{ name="CONSERVATIVE"; ratio=0.30 },
    @{ name="BALANCED";     ratio=0.40 },
    @{ name="AGGRESSIVE";   ratio=0.50 }
  )
}

$scenarios = @()
foreach ($sr in $scenarioRatios) {
  $ic  = [math]::Round($Cash * [double]$sr.ratio)
  $rc  = $Cash - $ic
  $alloc = Build-SectorAllocation $ic
  $scenarios += [pscustomobject]@{
    scenario = $sr.name
    invest_ratio = [double]$sr.ratio
    invest_cash = $ic
    reserve_cash = $rc
    allocation = $alloc
  }
}

$scenarioReport = [pscustomobject]@{
  generated_at = $now.ToString("s")
  inputs = @{ user_cash=$Cash; heat_weight=$heatWeight }
  market_trend = $marketTrend
  sector_heat = $sectorHeat
  scenarios = $scenarios
}

$scJson = Join-Path $reportsDir ("scenarios_{0}.json" -f $stamp)
$scTxt  = Join-Path $reportsDir ("scenarios_{0}.txt"  -f $stamp)
$scenarioReport | ConvertTo-Json -Depth 10 | Set-Content -Path $scJson -Encoding UTF8

$lines = @()
$lines += "SCENARIOS"
$lines += "generated_at=$($scenarioReport.generated_at)"
$lines += "market_trend=$marketTrend"
$lines += "user_cash=$Cash"
$lines += ""
$lines += "[SECTOR HEAT]"
$lines += "sector,score,level"
foreach ($s in $sectorHeat) { $lines += ("{0},{1},{2}" -f $s.sector,$s.score,$s.level) }
$lines += ""
$lines += "[SCENARIOS]"
foreach ($sc in $scenarios) {
  $lines += ""
  $lines += ("== {0} ==" -f $sc.scenario)
  $lines += ("invest_ratio={0} invest_cash={1} reserve_cash={2}" -f $sc.invest_ratio,$sc.invest_cash,$sc.reserve_cash)
  $lines += "allocation:"
  foreach ($a in $sc.allocation) { $lines += ("- {0} {1} cash={2} (ratio={3})" -f $a.sector,$a.level,$a.cash,$a.ratio) }
}
$lines | Set-Content -Path $scTxt -Encoding UTF8

# ----------------------------
# 6) Step 7-6 Post-market Summary (+ risk alerts)
# ----------------------------
$riskAlerts = @()
if (@($marketData).Count -ge 2) {
  $rows = @($marketData | Sort-Object { [datetime]$_.date })
  $t = $rows[-1]; $y = $rows[-2]
  if ([int]$t.up_count -gt [int]$t.down_count -and [double]$t.volume -le [double]$y.volume) {
    $riskAlerts += "Breadth positive but volume not expanding: consider smaller position sizes."
  }
}
if ((@($sectorHeat | Where-Object { $_.level -eq "HOT3" })).Count -gt 0) {
  $riskAlerts += "HOT3 sectors detected: avoid all-in, prefer staged entries."
}
if (@($hotSectors).Count -eq 0) {
  $riskAlerts += "No HOT sectors today: prefer cash-heavy stance."
}

$postmarket = [pscustomobject]@{
  generated_at = $now.ToString("s")
  user_cash = $Cash
  index_summary = $indexSummary
  market_trend = @{ trend=$marketTrend; reasons=$trendReasons }
  sector_heat = $sectorHeat
  scenarios = $scenarios
  risk_alerts = $riskAlerts
}

$pmJson = Join-Path $reportsDir ("postmarket_{0}.json" -f $stamp)
$pmTxt  = Join-Path $reportsDir ("postmarket_{0}.txt"  -f $stamp)
$postmarket | ConvertTo-Json -Depth 10 | Set-Content -Path $pmJson -Encoding UTF8

$lines = @()
$lines += "POST-MARKET SUMMARY"
$lines += "generated_at=$($postmarket.generated_at)"
$lines += "user_cash=$Cash"
$lines += ""
$lines += "[INDEX]"
foreach ($i in $indexSummary) { $lines += ("{0} close={1} {2} {3}% (chg={4})" -f $i.index_code,$i.close,$i.direction,$i.change_pct,$i.change_point) }
$lines += ""
$lines += "[MARKET TREND]"
$lines += ("trend={0}" -f $marketTrend)
$lines += ("reasons={0}" -f ($trendReasons -join ", "))
$lines += ""
$lines += "[SECTOR HEAT TOP]"
$top = $sectorHeat | Select-Object -First 5
foreach ($s in $top) { $lines += ("{0} score={1} level={2} up={3} down={4} avg={5}" -f $s.sector,$s.score,$s.level,$s.up,$s.down,$s.avg_change) }
$lines += ""
$lines += "[SCENARIOS]"
foreach ($sc in $scenarios) {
  $lines += ""
  $lines += ("== {0} ==" -f $sc.scenario)
  $lines += ("invest_ratio={0} invest_cash={1} reserve_cash={2}" -f $sc.invest_ratio,$sc.invest_cash,$sc.reserve_cash)
  $lines += "allocation:"
  foreach ($a in $sc.allocation) { $lines += ("- {0} {1} cash={2} (ratio={3})" -f $a.sector,$a.level,$a.cash,$a.ratio) }
}
$lines += ""
$lines += "[RISK ALERTS]"
if (@($riskAlerts).Count -eq 0) { $lines += "(none)" } else { foreach ($r in $riskAlerts) { $lines += ("- " + $r) } }
$lines | Set-Content -Path $pmTxt -Encoding UTF8

Write-Host "OK: wrote dashboard  -> $dashTxt"
Write-Host "OK: wrote scenarios  -> $scTxt"
Write-Host "OK: wrote postmarket -> $pmTxt"

if ($OpenReport) { notepad $pmTxt }

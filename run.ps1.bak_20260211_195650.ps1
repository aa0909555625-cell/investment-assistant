param(
  [Parameter(Mandatory=$false)]
  [int]$Cash = 300000,

  [Parameter(Mandatory=$false)]
  [ValidateSet("CONSERVATIVE","BALANCED","AGGRESSIVE","ALL")]
  [string]$Scenario = "ALL",

  [Parameter(Mandatory=$false)]
  [switch]$OpenReport,

  [Parameter(Mandatory=$false)]
  [switch]$EnsureSampleData,

  [Parameter(Mandatory=$false)]
  [switch]$ColorConsole
)

# ✅ 防止你 Profile 的 StrictMode 影響此工具（重要）
Set-StrictMode -Off
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

function Write-Utf8NoBom([string]$path, [string]$text) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
}

function Get-LevelWeight([string]$level) {
  switch ($level) {
    "HOT3" { 3 }
    "HOT2" { 2 }
    "HOT1" { 1 }
    default { 0 }
  }
}

function HeatEmoji([string]$level) {
  switch ($level) {
    "HOT3" { "🔥🔥🔥" }
    "HOT2" { "🔥🔥" }
    "HOT1" { "🔥" }
    "NEUTRAL" { "⚪" }
    "COLD1" { "❄️" }
    "COLD3" { "❄️❄️❄️" }
    default { "⚪" }
  }
}

function ArrowMark([double]$pct) {
  if ($pct -gt 0) { return "▲" }
  elseif ($pct -lt 0) { return "▼" }
  else { return "■" }
}

function ArrowColor([double]$pct) {
  if ($pct -gt 0) { return "Red" }
  elseif ($pct -lt 0) { return "Green" }
  else { return "Gray" }
}

function VolumeStrength([double]$pct) {
  if ($pct -ge 30) { return "爆量" }
  elseif ($pct -ge 10) { return "放量" }
  elseif ($pct -gt -10) { return "平量" }
  elseif ($pct -gt -30) { return "縮量" }
  else { return "急縮量" }
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
$indexData  = @(Import-Csv $indexFile)
$stockData  = @(Import-Csv $stockFile)
$marketData = @(Import-Csv $marketFile)

$heatWeight = 10
$now = Get-Date
$stamp = $now.ToString("yyyyMMdd_HHmmss")

# ----------------------------
# 1) INDEX SUMMARY
# ----------------------------
$indexSummary = @()
$indexGroups = @($indexData | Group-Object -Property index_code)
foreach ($grp in $indexGroups) {
  $rows = @($grp.Group | Sort-Object { [datetime]$_.date })
  if ($rows.Count -lt 2) { continue }

  $today = $rows[-1]; $y = $rows[-2]
  $todayClose = [double]$today.close
  $yClose = [double]$y.close
  if ($yClose -eq 0) { continue }

  $chg = $todayClose - $yClose
  $pct = ($chg / $yClose) * 100
  $dir = if ($pct -gt 0) { "UP" } elseif ($pct -lt 0) { "DOWN" } else { "FLAT" }
  $arrow = ArrowMark $pct

  $indexSummary += [pscustomobject]@{
    index_code   = $today.index_code
    date         = $today.date
    close        = [math]::Round($todayClose,2)
    change_point = [math]::Round($chg,2)
    change_pct   = [math]::Round($pct,2)
    direction    = $dir
    arrow        = $arrow
  }
}

function FindIndex([string]$code) {
  $hit = $indexSummary | Where-Object { $_.index_code -eq $code } | Select-Object -First 1
  return $hit
}

# ----------------------------
# 2) SECTOR HEAT
# ----------------------------
$sectorHeat = @()
$sectorGroups = @($stockData | Group-Object -Property sector)

foreach ($grp in $sectorGroups) {
  $g = @($grp.Group)
  if ($g.Count -eq 0) { continue }

  $up   = @($g | Where-Object { [double]$_.change_percent -gt 0 }).Count
  $down = @($g | Where-Object { [double]$_.change_percent -lt 0 }).Count
  $flat = @($g | Where-Object { [double]$_.change_percent -eq 0 }).Count
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
    sector     = $grp.Name
    score      = [math]::Round([double]$score,2)
    level      = $level
    emoji      = (HeatEmoji $level)
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
      emoji  = $s.emoji
      score  = $s.score
      weight = $w
      ratio  = [math]::Round($r,4)
      cash   = [math]::Round($investCash * $r)
    }
  }
  @($alloc | Sort-Object cash -Descending)
}

# ----------------------------
# 3) MARKET TREND + BOARD SNAPSHOT
# ----------------------------
$marketTrend = "UNKNOWN"
$trendReasons = @()

$board = $null
if ($marketData.Count -ge 2) {
  $rows = @($marketData | Sort-Object { [datetime]$_.date })
  $t = $rows[-1]; $y = $rows[-2]

  $c1 = ([int]$t.up_count -gt [int]$t.down_count)
  $c2 = ([double]$t.volume -gt [double]$y.volume)
  $c3 = ([int]$t.limit_up -gt [int]$t.limit_down)

  $trendReasons += $(if ($c1) { "advancers>decliners" } else { "advancers<=decliners" })
  $trendReasons += $(if ($c2) { "volume_up" } else { "volume_down_or_flat" })
  $trendReasons += $(if ($c3) { "limit_up>limit_down" } else { "limit_up<=limit_down" })

  $marketTrend = if ($c1 -and $c2 -and $c3) { "BULL" } else { "BEAR" }

  $volToday = [double]$t.volume
  $volY = [double]$y.volume
  $volChgPct = if ($volY -ne 0) { (($volToday - $volY) / $volY) * 100 } else { 0 }
  $volStrength = VolumeStrength $volChgPct

  $board = [pscustomobject]@{
    date = $t.date
    up_count = [int]$t.up_count
    down_count = [int]$t.down_count
    flat_count = [int]$t.flat_count
    limit_up = [int]$t.limit_up
    limit_down = [int]$t.limit_down
    volume = [math]::Round($volToday,2)
    volume_yesterday = [math]::Round($volY,2)
    volume_change_pct = [math]::Round($volChgPct,2)
    volume_strength = $volStrength
  }
}

# ----------------------------
# Step 7-4 Dashboard
# ----------------------------
$investRatio = switch ($marketTrend) {
  "BULL" { 0.6 }
  "BEAR" { 0.2 }
  default { 0.4 }
}

# ----------------------------
# Step 7-5 Scenarios
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

$scenariosForOutput = $scenarios
if ($Scenario -ne "ALL") {
  $scenariosForOutput = @($scenarios | Where-Object { $_.scenario -eq $Scenario })
}

# ----------------------------
# Risk Alerts
# ----------------------------
$riskAlerts = @()
if ($marketData.Count -ge 2) {
  $rows = @($marketData | Sort-Object { [datetime]$_.date })
  $t = $rows[-1]; $y = $rows[-2]
  if ([int]$t.up_count -gt [int]$t.down_count -and [double]$t.volume -le [double]$y.volume) {
    $riskAlerts += "Breadth positive but volume not expanding: consider smaller position sizes."
  }
}
if (@($sectorHeat | Where-Object { $_.level -eq "HOT3" }).Count -gt 0) {
  $riskAlerts += "HOT3 sectors detected: avoid all-in, prefer staged entries."
}
if (@($hotSectors).Count -eq 0) {
  $riskAlerts += "No HOT sectors today: prefer cash-heavy stance."
}

# ----------------------------
# Outputs
# ----------------------------
$reportsDir = ".\reports"
Ensure-Dir $reportsDir

$dashTxt  = Join-Path $reportsDir ("dashboard_{0}.txt"  -f $stamp)
$pmTxt    = Join-Path $reportsDir ("postmarket_{0}.txt"  -f $stamp)

$twse = FindIndex "TWSE"
$otc  = FindIndex "OTC"

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("====================")
$lines.Add("MARKET DASHBOARD")
$lines.Add("generated_at=$($now.ToString('s'))")
$lines.Add("====================")
$lines.Add("")

if ($twse) { $lines.Add(("📈 加權指數  {0:N2}  {1} {2:+0.00;-0.00;0.00}%" -f $twse.close, $twse.arrow, $twse.change_pct)) }
if ($otc)  { $lines.Add(("📉 櫃買指數  {0:N2}  {1} {2:+0.00;-0.00;0.00}%" -f $otc.close,  $otc.arrow,  $otc.change_pct)) }

$lines.Add("")
$lines.Add("📊 盤口摘要")
if ($board) {
  $lines.Add(("- 上漲家數：{0}" -f $board.up_count))
  $lines.Add(("- 下跌家數：{0}" -f $board.down_count))
  $lines.Add(("- 平盤：{0}" -f $board.flat_count))
  $lines.Add(("- 漲停：{0}" -f $board.limit_up))
  $lines.Add(("- 跌停：{0}" -f $board.limit_down))
  $lines.Add(("- 成交量：{0}（昨日 {1}）" -f $board.volume, $board.volume_yesterday))
  $lines.Add(("- 量能變化：{0:+0.00;-0.00;0.00}%（{1}）" -f $board.volume_change_pct, $board.volume_strength))
}
$lines.Add(("- 多空判斷：{0}（{1}）" -f $(if ($marketTrend -eq "BULL") { "偏多" } else { "偏空" }), ($trendReasons -join ", ")))

$lines.Add("")
$lines.Add("🔥 類股熱度（Top 5）")
$top = @($sectorHeat | Select-Object -First 5)
foreach ($s in $top) {
  $lines.Add(("- {0}  {1}  score={2}  avg={3}% (up={4}, down={5}, flat={6})" -f $s.sector,$s.emoji,$s.score,$s.avg_change,$s.up,$s.down,$s.flat))
}

$lines.Add("")
$lines.Add("❄️ 類股熱度（Bottom 5）")
$botAll = @($sectorHeat | Sort-Object score)
$bot = @()
foreach ($s in $botAll) {
  # ✅ 這裡修正：永遠用 @(...).Count，避免單一物件沒有 Count
  if (@($top | Where-Object { $_.sector -eq $s.sector }).Count -eq 0) {
    $bot += $s
  }
  if ($bot.Count -ge 5) { break }
}
foreach ($s in $bot) {
  $lines.Add(("- {0}  {1}  score={2}  avg={3}% (up={4}, down={5}, flat={6})" -f $s.sector,$s.emoji,$s.score,$s.avg_change,$s.up,$s.down,$s.flat))
}
if ($bot.Count -eq 0) { $lines.Add("(none)") }

$lines.Add("")
$lines.Add("💰 資金配置建議（情境：$Scenario）")
$lines.Add(("可用資金：{0}" -f $Cash))

foreach ($sc in $scenariosForOutput) {
  $title = switch ($sc.scenario) {
    "CONSERVATIVE" { "保守" }
    "BALANCED"     { "平衡" }
    "AGGRESSIVE"   { "積極" }
    default { $sc.scenario }
  }
  $lines.Add("")
  $lines.Add(("== {0} ==" -f $title))
  $lines.Add(("投入比例：{0:P0}  → 建議投入：{1}  保留：{2}" -f $sc.invest_ratio, $sc.invest_cash, $sc.reserve_cash))
  foreach ($a in $sc.allocation) {
    $lines.Add(("- {0} {1}：{2}（ratio={3}）" -f $a.sector,$a.emoji,$a.cash,$a.ratio))
  }
}

$lines.Add("")
$lines.Add("⚠️ 風險提示")
if ($riskAlerts.Count -eq 0) { $lines.Add("(none)") } else { foreach ($r in $riskAlerts) { $lines.Add("- $r") } }

Write-Utf8NoBom $pmTxt ($lines -join "`r`n")
Write-Utf8NoBom $dashTxt ($lines -join "`r`n")

Write-Host "OK: wrote dashboard  -> $dashTxt"
Write-Host "OK: wrote postmarket -> $pmTxt"

# ----------------------------
# Color Console Output
# ----------------------------
if ($ColorConsole) {
  Write-Host ""
  Write-Host "====================" -ForegroundColor DarkGray
  Write-Host "MARKET DASHBOARD" -ForegroundColor White
  Write-Host ("generated_at={0}" -f $now.ToString("s")) -ForegroundColor DarkGray
  Write-Host "====================" -ForegroundColor DarkGray
  Write-Host ""

  if ($twse) {
    Write-Host "📈 加權指數  " -NoNewline
    Write-Host ("{0:N2}  " -f $twse.close) -NoNewline -ForegroundColor White
    Write-Host ("{0} " -f $twse.arrow) -NoNewline -ForegroundColor (ArrowColor $twse.change_pct)
    Write-Host ("{0:+0.00;-0.00;0.00}%" -f $twse.change_pct) -ForegroundColor (ArrowColor $twse.change_pct)
  }
  if ($otc) {
    Write-Host "📉 櫃買指數  " -NoNewline
    Write-Host ("{0:N2}  " -f $otc.close) -NoNewline -ForegroundColor White
    Write-Host ("{0} " -f $otc.arrow) -NoNewline -ForegroundColor (ArrowColor $otc.change_pct)
    Write-Host ("{0:+0.00;-0.00;0.00}%" -f $otc.change_pct) -ForegroundColor (ArrowColor $otc.change_pct)
  }

  Write-Host ""
  Write-Host "📊 盤口摘要" -ForegroundColor Yellow
  if ($board) {
    Write-Host ("- 上漲家數：{0}" -f $board.up_count)
    Write-Host ("- 下跌家數：{0}" -f $board.down_count)
    Write-Host ("- 平盤：{0}" -f $board.flat_count)
    Write-Host ("- 漲停：{0}" -f $board.limit_up)
    Write-Host ("- 跌停：{0}" -f $board.limit_down)
    Write-Host ("- 成交量：{0}（昨日 {1}）" -f $board.volume, $board.volume_yesterday)
    Write-Host ("- 量能變化：{0:+0.00;-0.00;0.00}%（{1}）" -f $board.volume_change_pct, $board.volume_strength)
  }
  $trendColor = if ($marketTrend -eq "BULL") { "Red" } else { "Green" }
  Write-Host ("- 多空判斷：" ) -NoNewline
  Write-Host ($(if ($marketTrend -eq "BULL") { "偏多" } else { "偏空" })) -NoNewline -ForegroundColor $trendColor
  Write-Host ("（{0}）" -f ($trendReasons -join ", "))

  Write-Host ""
  Write-Host "🔥 類股熱度（Top 5）" -ForegroundColor Yellow
  foreach ($s in $top) {
    $c = if ($s.level -like "HOT*") { "Red" } elseif ($s.level -like "COLD*") { "Green" } else { "Gray" }
    Write-Host ("- {0}  " -f $s.sector) -NoNewline
    Write-Host ("{0}  " -f $s.emoji) -NoNewline -ForegroundColor $c
    Write-Host ("score={0} avg={1}% (up={2}, down={3}, flat={4})" -f $s.score,$s.avg_change,$s.up,$s.down,$s.flat)
  }

  Write-Host ""
  Write-Host "💰 資金配置（情境：$Scenario）" -ForegroundColor Yellow
  Write-Host ("可用資金：{0}" -f $Cash)
  foreach ($sc in $scenariosForOutput) {
    $title = switch ($sc.scenario) {
      "CONSERVATIVE" { "保守" }
      "BALANCED"     { "平衡" }
      "AGGRESSIVE"   { "積極" }
      default { $sc.scenario }
    }
    Write-Host ""
    Write-Host ("== {0} ==" -f $title) -ForegroundColor White
    Write-Host ("投入比例：{0:P0}  → 建議投入：{1}  保留：{2}" -f $sc.invest_ratio, $sc.invest_cash, $sc.reserve_cash)
    foreach ($a in $sc.allocation) {
      Write-Host ("- {0} {1}：{2}（ratio={3}）" -f $a.sector,$a.emoji,$a.cash,$a.ratio)
    }
  }

  Write-Host ""
  Write-Host "⚠️ 風險提示" -ForegroundColor Yellow
  if ($riskAlerts.Count -eq 0) { Write-Host "(none)" -ForegroundColor Gray } else { foreach ($r in $riskAlerts) { Write-Host "- $r" -ForegroundColor Yellow } }
}

if ($OpenReport) { notepad $pmTxt }

#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$DailyPath = ".\data\all_stocks_daily.csv",
  [string]$OutPath  = ".\data\market_snapshot.csv",
  [int]$SectorTop   = 10
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

$dailyPath = Resolve-ProjectPath $DailyPath
$outPath   = Resolve-ProjectPath $OutPath

if (!(Test-Path $dailyPath)) { throw "DailyPath not found: $dailyPath" }

$rows = @((Import-Csv $dailyPath))
if ($rows.Length -eq 0) { throw "Daily CSV is empty: $dailyPath" }

# latest date
$latestDate = ($rows | Sort-Object date -Descending | Select-Object -First 1).date
if ([string]::IsNullOrWhiteSpace($latestDate)) { throw "Cannot determine latest date from daily CSV." }

$today = @($rows | Where-Object { $_.date -eq $latestDate })
if ($today.Length -eq 0) { throw "No rows for latest date=$latestDate" }

# market breadth
$up   = (@($today | Where-Object { [double]$_.change_percent -gt 0 })).Length
$down = (@($today | Where-Object { [double]$_.change_percent -lt 0 })).Length
$flat = $today.Length - $up - $down

$avgChg = [math]::Round((($today | Measure-Object change_percent -Average).Average), 4)

# median (safe)
$sortedChg = @($today | Sort-Object { [double]$_.change_percent } | Select-Object -ExpandProperty change_percent)
$mid = [int]($sortedChg.Length / 2)
$medChg = [math]::Round([double]$sortedChg[$mid], 4)

# sector heat (using existing 'sector' field; if empty -> "unknown")
$bySector =
  $today | ForEach-Object {
    $sec = $_.sector
    if ([string]::IsNullOrWhiteSpace($sec)) { $sec = "unknown" }
    [PSCustomObject]@{
      sector = $sec
      change_percent = [double]$_.change_percent
      total_score    = [double]$_.total_score
    }
  } |
  Group-Object sector |
  ForEach-Object {
    $avgS = [math]::Round((($_.Group | Measure-Object total_score -Average).Average), 2)
    $avgC = [math]::Round((($_.Group | Measure-Object change_percent -Average).Average), 4)
    [PSCustomObject]@{
      sector = $_.Name
      n = $_.Count
      avg_score = $avgS
      avg_change = $avgC
    }
  } |
  Sort-Object `
    @{ Expression = 'avg_score';  Descending = $true }, `
    @{ Expression = 'avg_change'; Descending = $true } |
  Select-Object -First $SectorTop

# risk tone (simple heuristic)
$riskTone = "neutral"
if ($avgChg -ge 0.6 -and ($up -gt $down)) { $riskTone = "risk_on" }
elseif ($avgChg -le -0.6 -and ($down -gt $up)) { $riskTone = "risk_off" }

# snapshot rows (key/value) + sector heat rows
$out = @()

$out += [PSCustomObject]@{ kind="snapshot"; key="date"; value="$latestDate" }
$out += [PSCustomObject]@{ kind="snapshot"; key="universe"; value="$($today.Length)" }
$out += [PSCustomObject]@{ kind="snapshot"; key="up"; value="$up" }
$out += [PSCustomObject]@{ kind="snapshot"; key="down"; value="$down" }
$out += [PSCustomObject]@{ kind="snapshot"; key="flat"; value="$flat" }
$out += [PSCustomObject]@{ kind="snapshot"; key="avg_change"; value="$avgChg" }
$out += [PSCustomObject]@{ kind="snapshot"; key="median_change"; value="$medChg" }
$out += [PSCustomObject]@{ kind="snapshot"; key="risk_tone"; value="$riskTone" }

$rank = 0
foreach ($s in $bySector) {
  $rank++
  $out += [PSCustomObject]@{
    kind="sector_heat"
    key=("rank_{0:00}" -f $rank)
    value=("{0}|n={1}|avg_score={2}|avg_change={3}" -f $s.sector, $s.n, $s.avg_score, $s.avg_change)
  }
}

# ensure out dir exists
$outDir = Split-Path -Parent $outPath
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$out | Export-Csv $outPath -NoTypeInformation -Encoding UTF8

Write-Host "OK: built market snapshot -> $outPath" -ForegroundColor Green
Write-Host ("INFO: date={0} universe={1} up={2} down={3} avg_change={4} tone={5}" -f $latestDate, $today.Length, $up, $down, $avgChg, $riskTone) -ForegroundColor DarkGray
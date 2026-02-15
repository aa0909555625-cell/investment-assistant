#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Months = 6,
  [string]$Symbols = "",
  [string]$OutDaily = ".\data\all_stocks_daily.csv",
  [switch]$KeepRaw
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

function Parse-Symbols([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return @() }
  $parts = $s -split "[,\s]+" | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() }
  # keep only 4-digit TW codes (prevents AI001 etc)
  return @($parts | Where-Object { $_ -match '^\d{4}$' } | Sort-Object -Unique)
}

function UnixSeconds([datetime]$dt) {
  $epoch = [datetime]"1970-01-01T00:00:00Z"
  return [int][math]::Floor(($dt.ToUniversalTime() - $epoch).TotalSeconds)
}

function Fetch-YahooHistory([string]$sym, [int]$months) {
  $end = Get-Date
  $start = $end.AddDays(-1 * [math]::Max(30, [int]([math]::Round($months * 31.0))))
  $p1 = UnixSeconds $start
  $p2 = UnixSeconds $end

  $url = "https://query1.finance.yahoo.com/v8/finance/chart/$sym.TW?period1=$p1&period2=$p2&interval=1d&events=history"
  Write-Host "[Fetch:yahoo] GET $url" -ForegroundColor DarkGray

  $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30
  if ($resp.StatusCode -ne 200) { throw "yahoo http $($resp.StatusCode)" }

  $json = $resp.Content | ConvertFrom-Json
  if ($null -eq $json.chart -or $null -eq $json.chart.result -or $json.chart.result.Count -eq 0) {
    $err = ""
    try { $err = ($json.chart.error | ConvertTo-Json -Compress) } catch {}
    throw "chart_error:$err"
  }

  $r0 = $json.chart.result[0]
  $ts = @($r0.timestamp)
  $cl = @($r0.indicators.quote[0].close)

  if ($ts.Count -eq 0 -or $cl.Count -eq 0) { throw "no_rows" }

  $rows = @()
  for ($i=0; $i -lt $ts.Count; $i++) {
    $t = $ts[$i]
    $c = $cl[$i]
    if ($null -eq $t -or $null -eq $c) { continue }
    $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$t).DateTime.ToString("yyyy-MM-dd")
    $rows += [PSCustomObject]@{ date=$d; close=[double]$c }
  }

  if ($rows.Count -lt 20) { throw "too_few_rows:$($rows.Count)" }
  return @($rows | Sort-Object date)
}

function Build-DailyRows([string]$sym, [object[]]$hist) {
  # columns needed by downstream scripts:
  # date, code, name, sector, change_percent, total_score, liquidity, volatility, momentum, warnings
  $out = @()

  $prevClose = $null
  $window = New-Object System.Collections.Generic.List[double]

  foreach ($h in $hist) {
    $chg = 0.0
    if ($null -ne $prevClose -and $prevClose -ne 0) {
      $chg = (([double]$h.close - $prevClose) / $prevClose) * 100.0
    }
    $prevClose = [double]$h.close

    # momentum: average of last 5 change%
    $window.Add($chg)
    if ($window.Count -gt 5) { $window.RemoveAt(0) }
    $mom = 0.0
    if ($window.Count -gt 0) { $mom = ($window | Measure-Object -Average).Average }

    # volatility proxy: abs(change%)
    $vol = [math]::Abs($chg)

    # heuristic score (0..100)
    $score = 50.0 + (0.8 * $mom) - (0.4 * $vol)
    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    $out += [PSCustomObject]@{
      date           = [string]$h.date
      code           = $sym
      name           = $sym
      sector         = "unknown"
      change_percent = [math]::Round($chg, 4)
      total_score    = [math]::Round($score, 2)
      liquidity      = 50
      volatility     = [math]::Round($vol, 2)
      momentum       = [math]::Round($mom, 4)
      warnings       = ""
    }
  }

  return $out
}

# ---- main ----
$syms = Parse-Symbols $Symbols
if ($syms.Count -eq 0) { throw "No valid symbols. Provide -Symbols like 2330,2317,2454" }

Write-Host ("[INFO] Symbols: {0}" -f ($syms -join ",")) -ForegroundColor Gray

$histDir = Resolve-ProjectPath ".\data\history"
if (!(Test-Path $histDir)) { New-Item -ItemType Directory -Force -Path $histDir | Out-Null }

$allDaily = @()

foreach ($sym in $syms) {
  Write-Host ("[FETCH] {0} months={1}" -f $sym, $Months) -ForegroundColor Cyan

  $hist = $null
  try {
    $hist = Fetch-YahooHistory -sym $sym -months $Months
  } catch {
    Write-Host ("[ERROR] fetch failed for {0}: {1}" -f $sym, $_.Exception.Message) -ForegroundColor Red
    throw
  }

  $rawOut = Join-Path $histDir ("{0}.csv" -f $sym)
  if ($KeepRaw) {
    $hist | Export-Csv $rawOut -NoTypeInformation -Encoding UTF8
    Write-Host ("OK fetched {0} -> {1} rows={2} via=yahoo" -f $sym, ("data\history\{0}.csv" -f $sym), $hist.Count) -ForegroundColor Green
  } else {
    # still write raw for traceability
    $hist | Export-Csv $rawOut -NoTypeInformation -Encoding UTF8
  }

  $dailyRows = Build-DailyRows -sym $sym -hist $hist
  $allDaily += $dailyRows
}

$outPath = Resolve-ProjectPath $OutDaily
$outDir = Split-Path -Parent $outPath
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$allDaily = @($allDaily | Sort-Object date, code)
$allDaily | Export-Csv $outPath -NoTypeInformation -Encoding UTF8

Write-Host ("OK: rebuilt -> {0} (rows={1}, months={2})" -f $OutDaily, $allDaily.Count, $Months) -ForegroundColor Green
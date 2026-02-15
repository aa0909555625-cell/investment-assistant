#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Months = 6,
  [string]$OutDir = ".\data",
  [switch]$KeepRaw,
  [string[]]$Symbols = @()   # optional override
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$python = ".\.venv\Scripts\python.exe"
$fetchScript = ".\scripts\data_fetch_stooq.py"

if (!(Test-Path $python)) { throw "Python venv not found: $python" }
if (!(Test-Path $fetchScript)) { throw "Fetch script not found: $fetchScript" }

if (!(Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$historyDir = Join-Path $OutDir "history"
if (!(Test-Path $historyDir)) { New-Item -ItemType Directory -Force -Path $historyDir | Out-Null }

$finalDaily = Join-Path $OutDir "all_stocks_daily.csv"

function Get-SymbolsFromAllocationLog {
  $logPath = ".\data\allocation_log.csv"
  if (!(Test-Path $logPath)) { return @() }

  $codes = @(
    Import-Csv $logPath |
    Select-Object -ExpandProperty code -ErrorAction SilentlyContinue
  )

  # only keep Taiwan numeric tickers like 2330, 2317...
  $codes = @(
    $codes |
    Where-Object { $_ -match '^\d{4}$' } |
    Sort-Object -Unique
  )

  return $codes
}

function Get-ColumnName([string[]]$props, [string[]]$candidates){
  foreach ($c in $candidates) {
    if ($props -contains $c) { return $c }
  }
  return $null
}

function Compute-ChangePercentRows([string]$code, [object[]]$rows, [datetime]$startDate) {
  $rows = @($rows | Where-Object { $_.date } | Sort-Object date)

  if ($rows.Length -lt 30) { return @() }

  $props = @($rows[0].PSObject.Properties.Name)

  # try to find close column (case variants)
  $closeCol = Get-ColumnName $props @("close","Close","adj_close","AdjClose","Adj_Close","adjclose")
  if (-not $closeCol) { return @() }

  $out = @()
  $prev = $null

  foreach ($r in $rows) {
    $d = [datetime]$r.date
    if ($d -lt $startDate) { continue }

    $close = [double]($r.$closeCol)

    if ($prev -ne $null -and $prev -gt 0) {
      $chg = (($close - $prev) / $prev) * 100.0
      $chg = [math]::Round($chg, 4)

      $out += [PSCustomObject]@{
        date = $d.ToString("yyyy-MM-dd")
        code = $code
        name = $code
        sector = "unknown"
        change_percent = $chg
        total_score = 0
        liquidity = 0
        volatility = 0
        momentum = 0
        warnings = ""
      }
    }

    $prev = $close
  }

  return @($out)
}

# ===== decide symbols =====
if ($Symbols.Length -eq 0) {
  $Symbols = Get-SymbolsFromAllocationLog
}

if ($Symbols.Length -eq 0) {
  throw "No symbols found. Provide -Symbols 2330,2317,... or generate allocation_log.csv first."
}

Write-Host ("[INFO] Symbols: {0}" -f ($Symbols -join ",")) -ForegroundColor Cyan

$startDate = (Get-Date).AddMonths(-1 * $Months).Date

# clean previous final + optional history
if (Test-Path $finalDaily) { Remove-Item $finalDaily -Force }
if (-not $KeepRaw) { Remove-Item (Join-Path $historyDir "*.csv") -ErrorAction SilentlyContinue }

$all = @()

foreach ($sym in $Symbols) {
  $rawOut = Join-Path $historyDir ("{0}.csv" -f $sym)

  Write-Host ("[FETCH] {0} months={1}" -f $sym, $Months) -ForegroundColor Cyan

  & $python $fetchScript --symbol $sym --out $rawOut --months $Months --timeout 20 --force --min_rows 50
  if ($LASTEXITCODE -ne 0) { throw "Fetch failed for $sym (exit=$LASTEXITCODE)" }
  if (!(Test-Path $rawOut)) { throw "Raw file missing for ${sym}: $rawOut" }

  $rows = Import-Csv $rawOut

  $cp = Compute-ChangePercentRows -code $sym -rows $rows -startDate $startDate
  if ($cp.Length -eq 0) {
    Write-Host ("[WARN] No usable rows for {0} (missing close? too few rows?)" -f $sym) -ForegroundColor Yellow
    continue
  }

  $all += $cp
}

$all = @($all | Sort-Object date, code)

if ($all.Length -lt 50) {
  throw "Rebuild produced too few rows: $($all.Length). Possibly fetch output missing close column or too short history."
}

$all | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $finalDaily
Write-Host ("OK: rebuilt -> {0} (rows={1}, months={2})" -f $finalDaily, $all.Length, $Months) -ForegroundColor Green
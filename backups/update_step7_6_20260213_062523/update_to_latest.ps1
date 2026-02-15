#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Capital = 300000,
  [int]$Top = 4000,
  [switch]$Open,
  [string]$Runner = "",
  [string]$TargetDate = ""
)

function Get-LatestDateFromIndexDaily([string]$indexPath) {
  if (!(Test-Path $indexPath)) { throw "index file not found: $indexPath" }
  $lines = Get-Content -Path $indexPath -Encoding UTF8
  if (!$lines -or $lines.Count -lt 2) { throw "index file empty or missing header: $indexPath" }

  $header = $lines[0]
  $cols = $header.Split(",") | ForEach-Object { $_.Trim(' ', '"') }
  $dateCol = 0
  for ($i=0; $i -lt $cols.Count; $i++) {
    if ($cols[$i] -ieq "date") { $dateCol = $i; break }
  }

  $dates = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines | Select-Object -Skip 1) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line.Split(",")
    if ($parts.Count -le $dateCol) { continue }
    $d = $parts[$dateCol].Trim(' ', '"')
    if ($d -match '^\d{4}-\d{2}-\d{2}$') { $dates.Add($d) }
  }
  if ($dates.Count -eq 0) { throw "no valid YYYY-MM-DD dates found in: $indexPath" }
  return ($dates | Sort-Object)[-1]
}

function Test-DateExistsInCsv([string]$csvPath, [string]$date) {
  if (!(Test-Path $csvPath)) { return $false }
  # fast scan: look for "YYYY-MM-DD" token boundary
  $pattern = "(^|,|`")$date(`"|,|$)"
  return (Select-String -Path $csvPath -Pattern $pattern -Quiet)
}

function Select-Runner([string]$scriptsDir, [string]$explicitRunner) {
  if (![string]::IsNullOrWhiteSpace($explicitRunner)) {
    if (!(Test-Path $explicitRunner)) { throw "Runner not found: $explicitRunner" }
    return (Resolve-Path $explicitRunner).Path
  }

  $prefer = @((Join-Path $scriptsDir "run_75.ps1"), (Join-Path $scriptsDir "run.ps1"))
  foreach ($p in $prefer) { if (Test-Path $p) { return (Resolve-Path $p).Path } }

  $any = Get-ChildItem -Path $scriptsDir -Filter "run*.ps1" -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending |
         Select-Object -First 1
  if ($null -ne $any) { return $any.FullName }

  throw "No runner script found under: $scriptsDir"
}

function Get-RunnerParamNames([string]$runnerPath) {
  try {
    $cmd = Get-Command $runnerPath -ErrorAction Stop
    if ($cmd -and $cmd.Parameters -and $cmd.Parameters.Keys.Count -gt 0) {
      return $cmd.Parameters.Keys
    }
  } catch { }
  return @()
}

function Invoke-RunnerSafe(
  [string]$runnerPath,
  [string]$date,
  [int]$capital,
  [int]$top,
  [switch]$open,
  [switch]$forceFetch
) {
  Write-Host "[INFO] Runner = $runnerPath" -ForegroundColor Cyan
  Write-Host ("[INFO] Run for date={0} capital={1} top={2} open={3} forceFetch={4}" -f $date,$capital,$top,$open.IsPresent,$forceFetch.IsPresent) -ForegroundColor Cyan

  $paramNames = Get-RunnerParamNames -runnerPath $runnerPath
  $hasDate  = ($paramNames | Where-Object { $_ -ieq "Date" }).Count -gt 0
  $hasFetch = ($paramNames | Where-Object { $_ -ieq "Fetch" }).Count -gt 0
  $hasOpen  = ($paramNames | Where-Object { $_ -ieq "Open" }).Count -gt 0
  $hasCap   = ($paramNames | Where-Object { $_ -ieq "Capital" }).Count -gt 0
  $hasTop   = ($paramNames | Where-Object { $_ -ieq "Top" }).Count -gt 0

  if ($hasDate) {
    Write-Host "[INFO] Runner invoke mode: named" -ForegroundColor DarkGray
    $args = @{}
    if ($hasDate) { $args["Date"] = $date }
    if ($hasCap)  { $args["Capital"] = $capital }
    if ($hasTop)  { $args["Top"] = $top }
    if ($hasFetch -and $forceFetch.IsPresent) { $args["Fetch"] = $true }
    if ($hasOpen -and $open.IsPresent) { $args["Open"] = $true }

    & $runnerPath @args
    if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
      throw "Runner failed with exit code: $LASTEXITCODE"
    }
    return
  }

  # positional fallback only if runner doesn't have -Date
  Write-Host "[WARN] Runner named bind unavailable; try positional fallback..." -ForegroundColor Yellow
  if ($forceFetch.IsPresent) {
    if ($open.IsPresent) { & $runnerPath $date $capital $top $true $true }
    else { & $runnerPath $date $capital $top $true }
  } else {
    if ($open.IsPresent) { & $runnerPath $date $capital $top $true }
    else { & $runnerPath $date $capital $top }
  }

  if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
    throw "Runner failed with exit code: $LASTEXITCODE"
  }
}

function Invoke-Dashboard([string]$dashboardScript) {
  if (!(Test-Path $dashboardScript)) { throw "Dashboard script not found: $dashboardScript" }
  Write-Host "[INFO] Run dashboard: $dashboardScript" -ForegroundColor Cyan
  & $dashboardScript
  if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
    throw "Dashboard script failed with exit code: $LASTEXITCODE"
  }
}

# ---------------- main ----------------
$root = (Get-Location).Path
$scriptsDir = Join-Path $root "scripts"
$dataDir = Join-Path $root "data"

$indexPath = Join-Path $dataDir "index_daily.csv"
$dailyPath = Join-Path $dataDir "all_stocks_daily.csv"
$decisionsPath = Join-Path $dataDir "all_stocks_decisions.csv"
$dashboardScript = Join-Path $scriptsDir "run_dashboard.ps1"

Write-Host "=== UPDATE TO LATEST (daily/decisions) ===" -ForegroundColor Green

if ([string]::IsNullOrWhiteSpace($TargetDate)) {
  $TargetDate = Get-LatestDateFromIndexDaily -indexPath $indexPath
}
Write-Host ("[INFO] TargetDate   = {0}" -f $TargetDate) -ForegroundColor Yellow

$hasDaily = Test-DateExistsInCsv -csvPath $dailyPath -date $TargetDate
$hasDecisions = Test-DateExistsInCsv -csvPath $decisionsPath -date $TargetDate

Write-Host ("[INFO] daily.csv     = {0}" -f ($(if($hasDaily){"OK"}else{"MISSING"}))) -ForegroundColor Gray
Write-Host ("[INFO] decisions.csv = {0}" -f ($(if($hasDecisions){"OK"}else{"MISSING"}))) -ForegroundColor Gray

if (-not $hasDaily -or -not $hasDecisions) {
  Write-Host "[WARN] Missing data for target date, will run runner to backfill..." -ForegroundColor Yellow
  $runnerPath = Select-Runner -scriptsDir $scriptsDir -explicitRunner $Runner
  Invoke-RunnerSafe -runnerPath $runnerPath -date $TargetDate -capital $Capital -top $Top -open:$Open -forceFetch
} else {
  Write-Host "[INFO] Data already present for target date. Skip runner." -ForegroundColor DarkGray
}

$hasDaily2 = Test-DateExistsInCsv -csvPath $dailyPath -date $TargetDate
$hasDecisions2 = Test-DateExistsInCsv -csvPath $decisionsPath -date $TargetDate
if (-not $hasDaily2 -or -not $hasDecisions2) {
  $missing = @()
  if (-not $hasDaily2) { $missing += "all_stocks_daily.csv" }
  if (-not $hasDecisions2) { $missing += "all_stocks_decisions.csv" }
  throw ("Backfill finished but still missing target date in: {0}" -f ($missing -join ", "))
}

Write-Host "[OK] Data ready. Refresh dashboard..." -ForegroundColor Green
Invoke-Dashboard -dashboardScript $dashboardScript
Write-Host "[DONE] update_to_latest completed." -ForegroundColor Green
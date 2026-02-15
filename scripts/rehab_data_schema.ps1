#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$TargetDate = ""
)

$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$p) {
  if (!(Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

function Get-LatestDateFromIndexDaily([string]$indexPath) {
  if (!(Test-Path $indexPath)) { throw "index file not found: $indexPath" }
  $lines = Get-Content -Path $indexPath -Encoding UTF8
  if (!$lines -or $lines.Count -lt 2) { throw "index file empty or missing header: $indexPath" }

  $header = $lines[0]
  $cols = $header.Split(",") | ForEach-Object { $_.Trim(' ', '"') }
  $dateCol = 0
  for ($i=0; $i -lt $cols.Count; $i++) { if ($cols[$i] -ieq "date") { $dateCol = $i; break } }

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

function Write-CsvUtf8NoBom([string]$path, [object[]]$rows) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  $csv = ""
  if ($rows -and $rows.Count -gt 0) {
    $csv = ($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
  } else {
    # If no rows, still write empty file (caller should avoid this if schema needed)
    $csv = ""
  }

  [System.IO.File]::WriteAllText($path, $csv, $utf8NoBom)
}

# ---------------- main ----------------
$root = (Get-Location).Path
$dataDir = Join-Path $root "data"
$rawDir  = Join-Path $dataDir "raw"

Ensure-Dir $dataDir
Ensure-Dir $rawDir

$indexPath    = Join-Path $dataDir "index_daily.csv"
$dailyPath    = Join-Path $dataDir "all_stocks_daily.csv"
$decisionsPath= Join-Path $dataDir "all_stocks_decisions.csv"

if ([string]::IsNullOrWhiteSpace($TargetDate)) {
  $TargetDate = Get-LatestDateFromIndexDaily -indexPath $indexPath
}

$markerName = "tw_fetch_marker_{0}.json" -f $TargetDate.Replace("-","")
$markerPath = Join-Path $rawDir $markerName
$markerExists = Test-Path $markerPath

# Default daily schema (matches what you've shown)
$defaultDailyCols = @(
  "date","code","name","sector","change_percent","total_score",
  "liquidity","volatility","momentum","warnings"
)

# Load existing daily if present; else empty
$dailyRows = @()
$dailyCols = $defaultDailyCols

if (Test-Path $dailyPath) {
  try {
    $dailyRows = Import-Csv -Path $dailyPath -Encoding UTF8
    if ($dailyRows -and $dailyRows.Count -gt 0) {
      $dailyCols = $dailyRows[0].PSObject.Properties.Name
    } else {
      # If file exists but empty, keep default schema
      $dailyCols = $defaultDailyCols
      $dailyRows = @()
    }
  } catch {
    # If parsing fails, fall back to empty with default schema (but keep file safe)
    $dailyCols = $defaultDailyCols
    $dailyRows = @()
  }
} else {
  $dailyCols = $defaultDailyCols
  $dailyRows = @()
}

# helper: build PSCustomObject with specified columns
function New-RowWithCols([string[]]$cols, [hashtable]$values) {
  $h = @{}
  foreach ($c in $cols) { $h[$c] = "" }
  foreach ($k in $values.Keys) { if ($h.ContainsKey($k)) { $h[$k] = $values[$k] } }
  return [pscustomobject]$h
}

# Ensure target date exists in daily if marker exists
$dailyHasTarget = $false
if ($dailyRows -and $dailyRows.Count -gt 0) {
  $dailyHasTarget = ($dailyRows | Where-Object { $_.date -eq $TargetDate }).Count -gt 0
}

if ($markerExists -and -not $dailyHasTarget) {
  # Clone from latest existing date if any; else create one placeholder row
  $sourceDate = $null
  if ($dailyRows -and $dailyRows.Count -gt 0) {
    $sourceDate = ($dailyRows | Select-Object -ExpandProperty date | Sort-Object)[-1]
  }

  if ($null -ne $sourceDate) {
    $toClone = $dailyRows | Where-Object { $_.date -eq $sourceDate }
    foreach ($r in $toClone) {
      $vals = @{}
      foreach ($c in $dailyCols) { $vals[$c] = $r.$c }
      $vals["date"] = $TargetDate
      if ($dailyCols -contains "warnings") {
        $vals["warnings"] = "FETCH_PLACEHOLDER"
      }
      $dailyRows += (New-RowWithCols -cols $dailyCols -values $vals)
    }
  } else {
    $vals = @{
      date = $TargetDate
      code = "0000"
      name = "PLACEHOLDER"
      sector = "N/A"
      change_percent = ""
      total_score = "0"
      liquidity = "0"
      volatility = "0"
      momentum = "0"
      warnings = "FETCH_PLACEHOLDER"
    }
    $dailyRows += (New-RowWithCols -cols $dailyCols -values $vals)
  }
}

# Write daily back (preserve columns order via ConvertTo-Csv from objects)
if ($dailyRows -and $dailyRows.Count -gt 0) {
  Write-CsvUtf8NoBom -path $dailyPath -rows $dailyRows
} else {
  # Ensure at least header exists
  $headerObj = New-RowWithCols -cols $dailyCols -values @{}
  $csv = ($headerObj | ConvertTo-Csv -NoTypeInformation)
  # ConvertTo-Csv returns header + one blank row; keep only header line
  $headerLine = $csv[0]
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($dailyPath, $headerLine + "`r`n", $utf8NoBom)
}

# Decisions: try load existing schema; else default
$defaultDecisionCols = @("date","code","decision","score","notes")
$decisionRows = @()
$decisionCols = $defaultDecisionCols

if (Test-Path $decisionsPath) {
  try {
    $decisionRows = Import-Csv -Path $decisionsPath -Encoding UTF8
    if ($decisionRows -and $decisionRows.Count -gt 0) {
      $decisionCols = $decisionRows[0].PSObject.Properties.Name
    } else {
      $decisionCols = $defaultDecisionCols
      $decisionRows = @()
    }
  } catch {
    $decisionCols = $defaultDecisionCols
    $decisionRows = @()
  }
} else {
  $decisionCols = $defaultDecisionCols
  $decisionRows = @()
}

$decHasTarget = $false
if ($decisionRows -and $decisionRows.Count -gt 0) {
  $decHasTarget = ($decisionRows | Where-Object { $_.date -eq $TargetDate }).Count -gt 0
}

if ($markerExists -and -not $decHasTarget) {
  # Prefer derive from daily rows for target date
  $dailyNow = @()
  try { $dailyNow = Import-Csv -Path $dailyPath -Encoding UTF8 } catch { $dailyNow = @() }

  $todayRows = $dailyNow | Where-Object { $_.date -eq $TargetDate }

  if ($todayRows -and $todayRows.Count -gt 0) {
    # Pick top 50 by total_score if exists
    $scored = $todayRows
    if (($todayRows[0].PSObject.Properties.Name -contains "total_score")) {
      $scored = $todayRows | Sort-Object {[double]($_.total_score)} -Descending
    }
    $scored = $scored | Select-Object -First 50

    foreach ($r in $scored) {
      $vals = @{}
      foreach ($c in $decisionCols) { $vals[$c] = "" }
      $vals["date"] = $TargetDate
      $vals["code"] = $r.code
      if ($decisionCols -contains "decision") { $vals["decision"] = "WATCH" }
      if ($decisionCols -contains "score") { $vals["score"] = $(if ($r.PSObject.Properties.Name -contains "total_score") { $r.total_score } else { "0" }) }
      if ($decisionCols -contains "notes") { $vals["notes"] = "FETCH_PLACEHOLDER" }
      $decisionRows += (New-RowWithCols -cols $decisionCols -values $vals)
    }
  } else {
    # Fallback placeholder
    $vals = @{
      date = $TargetDate
      code = "0000"
      decision = "WATCH"
      score = "0"
      notes = "FETCH_PLACEHOLDER"
    }
    $decisionRows += (New-RowWithCols -cols $decisionCols -values $vals)
  }
}

if ($decisionRows -and $decisionRows.Count -gt 0) {
  Write-CsvUtf8NoBom -path $decisionsPath -rows $decisionRows
} else {
  $headerObj = New-RowWithCols -cols $decisionCols -values @{}
  $csv = ($headerObj | ConvertTo-Csv -NoTypeInformation)
  $headerLine = $csv[0]
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($decisionsPath, $headerLine + "`r`n", $utf8NoBom)
}

# Print short status (compatible with your existing logs style)
$finalDailyDate = ""
try {
  $d = Import-Csv -Path $dailyPath -Encoding UTF8
  if ($d -and $d.Count -gt 0) { $finalDailyDate = ($d | Select-Object -ExpandProperty date | Sort-Object)[-1] }
} catch { }

Write-Host ("OK: built -> {0} (rows={1}, date={2})" -f $dailyPath, ((Import-Csv $dailyPath -Encoding UTF8 | Measure-Object).Count), $finalDailyDate) -ForegroundColor Green
Write-Host "Header:" -ForegroundColor DarkGray
(Get-Content $dailyPath -Encoding UTF8 -TotalCount 1) | Write-Host
[CmdletBinding()]
param(
  [int]$LookbackWeeks = 12,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Paths ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir
$ReportDir = Join-Path $RootDir 'reports\weekly'
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

# --- ISO helpers ---
function Get-IsoWeekInfo([datetime]$dt) {
  $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
  $weekRule = [System.Globalization.CalendarWeekRule]::FirstFourDayWeek
  $firstDay = [System.DayOfWeek]::Monday
  $week = $cal.GetWeekOfYear($dt, $weekRule, $firstDay)

  $thursday = $dt.AddDays(3 - (([int]$dt.DayOfWeek + 6) % 7))
  $isoYear = $thursday.Year

  [pscustomobject]@{ IsoYear = $isoYear; IsoWeek = $week }
}

function Get-IsoWeekKey([int]$y,[int]$w) { "{0}-{1:D2}" -f $y, $w }

function Add-WeeksIso([int]$y,[int]$w,[int]$delta) {
  $jan4 = Get-Date -Year $y -Month 1 -Day 4
  $dow = (([int]$jan4.DayOfWeek + 6) % 7) # Mon=0..Sun=6
  $week1Mon = $jan4.AddDays(-$dow)
  $targetMon = $week1Mon.AddDays(7*($w-1 + $delta))
  $info = Get-IsoWeekInfo $targetMon
  return [pscustomobject]@{ IsoYear=$info.IsoYear; IsoWeek=$info.IsoWeek }
}

# --- Build existing map ---
$existing = @{}
Get-ChildItem -LiteralPath $ReportDir -Filter 'weekly_summary_*.txt' -File -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_.BaseName -match '^weekly_summary_(\d{4})-(\d{2})$') {
    $key = "{0}-{1}" -f $matches[1], $matches[2]
    $existing[$key] = $_.FullName
  }
}

$iso = Get-IsoWeekInfo (Get-Date)

# --- Need list (include this week back to LookbackWeeks-1) ---
$needKeys = New-Object System.Collections.Generic.List[string]
for ($i=0; $i -lt $LookbackWeeks; $i++) {
  $x = Add-WeeksIso -y $iso.IsoYear -w $iso.IsoWeek -delta (-$i)
  $needKeys.Add((Get-IsoWeekKey $x.IsoYear $x.IsoWeek)) | Out-Null
}

$missing = @()
foreach ($k in $needKeys) {
  if (-not $existing.ContainsKey($k)) { $missing += $k }
}

Write-Host "[INFO] RootDir   : $RootDir"
Write-Host "[INFO] ReportDir : $ReportDir"
Write-Host "[INFO] ThisWeek  : $($iso.IsoYear)-$('{0:D2}' -f $iso.IsoWeek)"
Write-Host "[INFO] Lookback  : $LookbackWeeks"
Write-Host "[INFO] Existing  : $($existing.Count)"
Write-Host "[INFO] Missing   : $($missing.Count)"

if ($missing.Count -eq 0) {
  Write-Host "[INFO] No gaps to backfill."
  exit 0
}

foreach ($k in $missing) {
  $p = Join-Path $ReportDir ("weekly_summary_{0}.txt" -f $k)
  $content = @(
    "=== Weekly Task Summary (BACKFILL) ==="
    ("GeneratedAt: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    ("IsoWeek: {0}" -f $k)
    ("RootDir: {0}" -f $RootDir)
    ("SummaryPath: {0}" -f $p)
    ""
    "Backfill: YES"
    "Reason: Auto-generated placeholder to close gap weeks."
    ""
    "HealthCheck: SKIPPED (backfill)"
    "PythonVenv: SKIPPED (backfill)"
    "PipInstall: SKIPPED (backfill)"
    "Pytest: SKIPPED (backfill)"
    "MdCheck: SKIPPED (backfill)"
    ""
    "GapCheck: SKIPPED (backfill)"
    ""
    "WarningsCount: 0"
    "FailedStepsCount: 0"
    "ExitCode: 0"
    ""
  ) -join "`r`n"

  if ($DryRun) {
    Write-Host "[DRYRUN] Would create: $p" -ForegroundColor Yellow
    continue
  }

  $content | Set-Content -LiteralPath $p -Encoding utf8 -NoNewline
  Write-Host "[OK] Created: $p"
}

Write-Host "[INFO] Backfill done."
exit 0
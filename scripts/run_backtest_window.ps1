#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Capital = 300000,
  [int]$LookbackDays = 60,
  [double]$ScoreThreshold = 50,
  [string]$EndDate = ""   # e.g. "2026-02-03"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$decisionsPath = ".\data\all_stocks_decisions.csv"
$logPath = ".\data\allocation_log.csv"

if (!(Test-Path $decisionsPath)) { throw "decisions file not found: $decisionsPath" }

$data = Import-Csv $decisionsPath

# dates list
$datesAll = @($data.date | Sort-Object -Unique | Sort-Object)
if ($datesAll.Length -eq 0) { throw "no dates in decisions" }

# apply EndDate cutoff (optional)
if ([string]::IsNullOrWhiteSpace($EndDate)) {
  $dates = $datesAll
} else {
  $cut = [datetime]$EndDate
  $dates = @($datesAll | Where-Object { ([datetime]$_) -le $cut })
}

if ($dates.Length -eq 0) { throw "no dates after applying EndDate cutoff: $EndDate" }

# last N days
$recentDates = @($dates | Select-Object -Last $LookbackDays)

# rebuild log
if (Test-Path $logPath) { Remove-Item $logPath -Force }

$logEntries = @()

foreach ($date in $recentDates) {

  $dailyData = @($data | Where-Object { $_.date -eq $date })
  if ($dailyData.Length -eq 0) { continue }

  $strong = @(
    $dailyData | Where-Object { [double]$_.total_score -ge $ScoreThreshold }
  )

  if ($strong.Length -eq 0) { continue }

  $sum = [double](($strong | Measure-Object -Property total_score -Sum).Sum)
  if ($sum -le 0) { continue }

  foreach ($s in $strong) {
    $w = [double]$s.total_score / $sum
    $alloc = [math]::Round($Capital * $w, 0)
    if ($alloc -lt 5000) { continue }

    $logEntries += [PSCustomObject]@{
      date = $date
      code = $s.code
      score = $s.total_score
      allocation = $alloc
      capital = $Capital
    }
  }
}

$logEntries = @($logEntries)

if ($logEntries.Length -eq 0) {
  Write-Host "No allocations generated in selected window." -ForegroundColor Yellow
  return
}

$logEntries | Export-Csv $logPath -NoTypeInformation -Encoding UTF8
Write-Host ("OK: allocation_log rebuilt -> {0} (rows={1})" -f $logPath, $logEntries.Length) -ForegroundColor Green
Write-Host ("[INFO] Window EndDate={0} LookbackDays={1} Threshold={2}" -f ($EndDate -as [string]), $LookbackDays, $ScoreThreshold) -ForegroundColor DarkGray
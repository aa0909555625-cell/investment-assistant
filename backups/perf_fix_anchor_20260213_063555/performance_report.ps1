#Requires -Version 5.1
[CmdletBinding()]
param(
    [int]$HoldingDays = 5,
    [string]$OutDir = ".\reports",
    [switch]$AllowPartial,         # allow using < HoldingDays if not enough future rows
    [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$logPath  = ".\data\allocation_log.csv"
$dailyPath = ".\data\all_stocks_daily.csv"

if (!(Test-Path $logPath))  { throw "allocation_log.csv not found." }
if (!(Test-Path $dailyPath)) { throw "all_stocks_daily.csv not found." }

$log  = @((Import-Csv $logPath))
$daily = @((Import-Csv $dailyPath))

if ($log.Length -eq 0) { throw "allocation_log.csv is empty." }
if ($daily.Length -eq 0) { throw "all_stocks_daily.csv is empty." }

# Normalize / guard
# daily needs: date, code, change_percent
$results = @()

$stats_total = $log.Length
$stats_code_missing = 0
$stats_no_future = 0
$stats_partial = 0
$stats_full = 0

foreach ($entry in $log) {

    if (-not $entry.code -or -not $entry.date) { continue }

    $entryDate = Get-Date $entry.date
    $code = [string]$entry.code

    # filter daily rows for this code
    $codeRows = @($daily | Where-Object { $_.code -eq $code })

    if ($codeRows.Length -eq 0) {
        $stats_code_missing++
        continue
    }

    $futureRowsRaw = $codeRows | Where-Object {
        $_.date -and (Get-Date $_.date) -gt $entryDate
    } | Sort-Object date | Select-Object -First $HoldingDays

    $futureRows = @($futureRowsRaw)

    if ($futureRows.Length -eq 0) {
        $stats_no_future++
        continue
    }

    if (($futureRows.Length -lt $HoldingDays) -and (-not $AllowPartial)) {
        $stats_no_future++
        continue
    }

    $daysUsed = $futureRows.Length
    if ($daysUsed -lt $HoldingDays) { $stats_partial++ } else { $stats_full++ }

    $sumPct = 0.0
    foreach ($r in $futureRows) {
        $sumPct += [double]$r.change_percent
    }

    # convert percent-sum to decimal return
    $ret = [math]::Round(($sumPct / 100.0), 4)

    $results += [PSCustomObject]@{
        date = $entry.date
        code = $code
        days_used = $daysUsed
        return = $ret
    }
}

$results = @($results)

if ($results.Length -eq 0) {
    throw ("No performance data available. total_log={0} missing_code={1} no_future_or_insufficient={2}. Tip: use -AllowPartial or reduce -HoldingDays." -f $stats_total, $stats_code_missing, $stats_no_future)
}

$avgReturn = [math]::Round((($results | Measure-Object return -Average).Average), 4)
$winRate   = [math]::Round(((@($results | Where-Object { $_.return -gt 0 })).Length / $results.Length), 4)
$totalReturn = [math]::Round((($results | Measure-Object return -Sum).Sum), 4)

if (!(Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outPath = Join-Path $OutDir "performance_report_$timestamp.html"

$rows = ""
foreach ($r in $results) {
    $rows += "<tr>"
    $rows += "<td>$($r.date)</td>"
    $rows += "<td>$($r.code)</td>"
    $rows += "<td>$($r.days_used)</td>"
    $rows += "<td>$($r.return)</td>"
    $rows += "</tr>"
}

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>Performance Report</title>
<style>
body { font-family: Arial; background:#111; color:#eee; }
table { border-collapse: collapse; width:100%; }
th, td { padding:8px; border:1px solid #444; text-align:center; }
th { background:#222; }
.card { background:#1a1a1a; padding:12px; border-radius:6px; margin-bottom:12px; }
.small { color:#aaa; }
</style>
</head>
<body>

<h2>Strategy Performance Report (Change % Based)</h2>

<div class="card">
<div class="small">
HoldingDays target: $HoldingDays |
AllowPartial: $AllowPartial |
Records used: $($results.Length)
</div>
<div class="small">
Log total: $stats_total |
Missing code in daily: $stats_code_missing |
No future/insufficient: $stats_no_future |
Full: $stats_full |
Partial: $stats_partial
</div>
</div>

<div class="card">
<p>Average Return: $avgReturn</p>
<p>Win Rate: $winRate</p>
<p>Total Return (sum): $totalReturn</p>
</div>

<table>
<tr>
<th>Date</th>
<th>Code</th>
<th>Days Used</th>
<th>Return</th>
</tr>
$rows
</table>

</body>
</html>
"@

[System.IO.File]::WriteAllText($outPath, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK: performance report generated -> $outPath" -ForegroundColor Green

if ($Open) { Start-Process $outPath | Out-Null }
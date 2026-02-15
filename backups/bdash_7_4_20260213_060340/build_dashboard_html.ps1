#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Date = "",
    [int]$Capital = 300000,
    [int]$Top = 4000,
    [string]$OutDir = ".\reports",
    [switch]$Open,
    [switch]$ListDates
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$csvPath = ".\data\all_stocks_decisions.csv"
$logPath = ".\data\allocation_log.csv"

if (!(Test-Path $csvPath)) { throw "CSV not found." }

$data = Import-Csv $csvPath

if ($ListDates) {
    $data.date | Sort-Object -Unique
    return
}

if ($Date -eq "") {
    $Date = ($data.date | Sort-Object -Descending | Select-Object -First 1)
}

$filtered = $data | Where-Object { $_.date -eq $Date }
if (!$filtered) { throw "No data for date $Date" }

if (!(Test-Path $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

# ================================
# RISK CONTROL SETTINGS
# ================================
$cashReserveRate = 0.1
$maxPerStockRate = 0.2
$minAllocation = 5000

$deployableCapital = [math]::Round($Capital * (1 - $cashReserveRate),0)
$maxPerStock = [math]::Round($deployableCapital * $maxPerStockRate,0)

# ================================
# Strong Stock Filter
# ================================
$strongStocks = @($filtered | Where-Object { [double]$_.total_score -ge 70 })

$allocationRows = ""
$logEntries = @()

if ($strongStocks.Length -gt 0) {

    $measure = $strongStocks | Measure-Object -Property total_score -Sum
    $totalScoreSum = [double]$measure.Sum

    if ($totalScoreSum -gt 0) {

        foreach ($s in $strongStocks) {

            $weight = [double]$s.total_score / $totalScoreSum
            $rawAllocation = $deployableCapital * $weight

            if ($rawAllocation -gt $maxPerStock) {
                $allocation = $maxPerStock
            }
            else {
                $allocation = $rawAllocation
            }

            $allocation = [math]::Round($allocation,0)

            if ($allocation -lt $minAllocation) {
                continue
            }

            # HTML row
            $allocationRows += "<tr>"
            $allocationRows += "<td>$($s.code)</td>"
            $allocationRows += "<td>$($s.total_score)</td>"
            $allocationRows += "<td>$([math]::Round($weight,4))</td>"
            $allocationRows += "<td>$allocation</td>"
            $allocationRows += "</tr>"

            # Log entry
            $logEntries += [PSCustomObject]@{
                date = $Date
                code = $s.code
                score = $s.total_score
                allocation = $allocation
                capital = $Capital
            }

        }

    }

}

if ($allocationRows -eq "") {
    $allocationRows = "<tr><td colspan='4'>No valid allocation</td></tr>"
}

# ================================
# WRITE LOG
# ================================
if ($logEntries.Count -gt 0) {

    if (!(Test-Path $logPath)) {
        $logEntries | Export-Csv $logPath -NoTypeInformation -Encoding UTF8
    }
    else {
        $logEntries | Export-Csv $logPath -NoTypeInformation -Append -Encoding UTF8
    }

}

# ================================
# STOCK TABLE
# ================================
$rowsHtml = ""
foreach ($row in $filtered) {
    $rowsHtml += "<tr>"
    $rowsHtml += "<td>$($row.code)</td>"
    $rowsHtml += "<td>$($row.name)</td>"
    $rowsHtml += "<td>$($row.total_score)</td>"
    $rowsHtml += "<td>$($row.change_percent)%</td>"
    $rowsHtml += "</tr>"
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outPath = Join-Path $OutDir "tw_dashboard_${Date}_$timestamp.html"

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>TW Market Dashboard - $Date</title>
<style>
body { font-family: Arial; background:#111; color:#eee; }
.card { padding:15px; margin:10px 0; background:#1a1a1a; border-radius:6px; }
table { border-collapse: collapse; width:100%; }
th, td { padding:8px; border:1px solid #444; text-align:center; }
th { background:#222; }
tr:nth-child(even) { background:#1a1a1a; }
.info { color:#aaa; margin-bottom:10px; }
</style>
</head>
<body>

<h2>TW Market Dashboard - $Date</h2>

<div class="card">
<div class="info">
Capital: $Capital |
Deployable: $deployableCapital |
Max Per Stock: $maxPerStock
</div>

<b>Capital Allocation Plan (Risk Controlled)</b>
<table>
<tr>
<th>Code</th>
<th>Score</th>
<th>Weight</th>
<th>Suggested Allocation</th>
</tr>
$allocationRows
</table>
</div>

<div class="card">
<b>All Stocks</b>
<table>
<tr>
<th>Code</th>
<th>Name</th>
<th>Total Score</th>
<th>Change %</th>
</tr>
$rowsHtml
</table>
</div>

</body>
</html>
"@

[System.IO.File]::WriteAllText($outPath, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK: wrote HTML -> $outPath" -ForegroundColor Green
Write-Host "OK: allocation log updated -> $logPath" -ForegroundColor Cyan

if ($Open) { Start-Process $outPath }
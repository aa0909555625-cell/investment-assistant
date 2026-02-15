param(
  [Parameter(Mandatory=$true)][string]$Date,
  [string]$DecisionsPath = ".\data\all_stocks_decisions.csv",
  [string]$TicketsCsv = "",
  [string]$OutMd = ""
)

if ($TicketsCsv -eq "") { $TicketsCsv = ".\reports\order_tickets_$($Date.Replace('-','')).csv" }
if ($OutMd -eq "") { $OutMd = ".\reports\daily_report_$($Date.Replace('-','')).md" }

if (!(Test-Path $DecisionsPath)) { throw "Missing: $DecisionsPath" }

$rows = Import-Csv $DecisionsPath | Where-Object { $_.date -eq $Date }
$ready = $rows | Where-Object { $_.action -eq "READY" -and $_.gate_final -eq "True" } | Sort-Object {[double]$_.total_score} -Descending
$observe = $rows | Where-Object { $_.action -eq "OBSERVE" } | Sort-Object {[double]$_.total_score} -Descending

$marketRisk = ($rows | Select-Object -First 1).market_risk
$idxChg = ($rows | Select-Object -First 1).market_index_change

$md = @()
$md += "# Daily Report ($Date)"
$md += ""
$md += "## Market Regime"
$md += "- risk: **$marketRisk**"
$md += "- index_change(proxy): **$idxChg**"
$md += ""
$md += "## Top READY Picks (Actionable)"
if ($ready.Count -eq 0) {
  $md += "- None (gates filtered or score not high enough)."
} else {
  $md += "|Rank|Code|Name|Score|RiskTag|Reason|"
  $md += "|---:|---:|---|---:|---|---|"
  $i=1
  foreach ($r in ($ready | Select-Object -First 20)) {
    $md += "|$i|$($r.code)|$($r.name)|$($r.total_score)|$($r.risk_tag)|$($r.reason)|"
    $i++
  }
}
$md += ""
$md += "## OBSERVE (Watchlist)"
if ($observe.Count -eq 0) {
  $md += "- None."
} else {
  $md += "|Code|Name|Score|RiskTag|"
  $md += "|---:|---|---:|---|"
  foreach ($r in ($observe | Select-Object -First 20)) {
    $md += "|$($r.code)|$($r.name)|$($r.total_score)|$($r.risk_tag)|"
  }
}
$md += ""
$md += "## Notes / Risk"
$md += "- System is advice-only. You confirm & place orders manually."
$md += "- If no_price exists, sizing/entry cannot be computed yet (data source upgrade needed)."

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$dir = Split-Path -Parent $OutMd
if (!(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllLines((Resolve-Path $dir).Path + "\" + (Split-Path -Leaf $OutMd), $md, $utf8NoBom)

Write-Host "OK: wrote -> $OutMd" -ForegroundColor Green
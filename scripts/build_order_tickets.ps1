param(
  [Parameter(Mandatory=$true)][string]$Date,
  [double]$Capital = 300000,
  [double]$RiskPerTrade = 0.01,
  [int]$MaxPicks = 20,
  [string]$InPath = ".\data\all_stocks_decisions.csv",
  [string]$OutCsv = "",
  [string]$OutMd  = ""
)

function To-Num($v, $default=0.0) {
  if ($null -eq $v) { return [double]$default }
  $s = "$v".Trim()
  if ($s -eq "") { return [double]$default }
  $n = 0.0
  if ([double]::TryParse($s, [ref]$n)) { return [double]$n }
  return [double]$default
}

if (!(Test-Path $InPath)) { throw "Missing input: $InPath" }
if ($OutCsv -eq "") { $OutCsv = ".\reports\order_tickets_$($Date.Replace('-','')).csv" }
if ($OutMd  -eq "") { $OutMd  = ".\reports\order_tickets_$($Date.Replace('-','')).md" }

$rows = Import-Csv $InPath | Where-Object { $_.date -eq $Date }

$picks = $rows |
  Where-Object { $_.action -eq "READY" -and $_.gate_final -eq "True" } |
  Sort-Object {[double]$_.total_score} -Descending |
  Select-Object -First $MaxPicks

$allocEach = if ($picks.Count -gt 0) { $Capital / $picks.Count } else { 0 }

$out = foreach ($p in $picks) {
  $entryMid = $null
  if ($p.entry_low -ne "" -and $p.entry_high -ne "") {
    $entryMid = ((To-Num $p.entry_low 0) + (To-Num $p.entry_high 0)) / 2.0
  }

  $sharesFixed = ""
  $sharesRisk = ""
  $mode = "FIXED_AMOUNT"

  if ($null -ne $entryMid -and $entryMid -gt 0) {
    $sharesFixed = [math]::Floor($allocEach / $entryMid)
  }

  if ($p.stop_price -ne "" -and $null -ne $entryMid -and $entryMid -gt 0) {
    $stop = To-Num $p.stop_price 0
    $riskBudget = $Capital * $RiskPerTrade
    $riskPerShare = [math]::Max(0.0001, ($entryMid - $stop))
    $sharesRisk = [math]::Floor($riskBudget / $riskPerShare)
    $mode = "RISK_PER_TRADE"
  }

  [pscustomobject]@{
    date = $Date
    rank = ""
    code = $p.code
    name = $p.name
    score = $p.total_score
    action = "BUY"
    entry_low = $p.entry_low
    entry_high = $p.entry_high
    stop = $p.stop_price
    shares_fixed = $sharesFixed
    shares_risk  = $sharesRisk
    risk_tag = $p.risk_tag
    reason = $p.reason
    sizing_mode = $mode
  }
}

# ensure rank
$i = 1
$out2 = foreach ($x in $out) { $x.rank = $i; $i++; $x }

# write CSV: if no picks, still output header-only file
$dir = Split-Path -Parent $OutCsv
if (!(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

if ($out2.Count -eq 0) {
  $header = "date,rank,code,name,score,action,entry_low,entry_high,stop,shares_fixed,shares_risk,risk_tag,reason,sizing_mode"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Resolve-Path $dir).Path + "\" + (Split-Path -Leaf $OutCsv), $header + "`r`n", $utf8NoBom)
} else {
  $out2 | Export-Csv $OutCsv -NoTypeInformation -Encoding UTF8
}

# Markdown ticket
$md = @()
$md += "# Order Tickets ($Date)"
$md += ""
if ($out2.Count -eq 0) {
  $md += "- No READY picks today."
} else {
  $md += "|Rank|Code|Name|Score|EntryRange|Stop|Shares(Fixed)|Shares(Risk)|RiskTag|"
  $md += "|---:|---:|---|---:|---|---|---:|---:|---|"
  foreach ($x in $out2) {
    $range = if ($x.entry_low -ne "" -and $x.entry_high -ne "") { "$($x.entry_low) ~ $($x.entry_high)" } else { "(no price)" }
    $md += "|$($x.rank)|$($x.code)|$($x.name)|$($x.score)|$range|$($x.stop)|$($x.shares_fixed)|$($x.shares_risk)|$($x.risk_tag)|"
  }
  $md += ""
  $md += "Notes: Shares(Fixed)=equal allocation. Shares(Risk)=Capital*RiskPerTrade sizing if stop exists."
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$mdDir = Split-Path -Parent $OutMd
if (!(Test-Path $mdDir)) { New-Item -ItemType Directory -Force -Path $mdDir | Out-Null }
[System.IO.File]::WriteAllLines((Resolve-Path $mdDir).Path + "\" + (Split-Path -Leaf $OutMd), $md, $utf8NoBom)

Write-Host "OK: wrote -> $OutCsv" -ForegroundColor Green
Write-Host "OK: wrote -> $OutMd" -ForegroundColor Green
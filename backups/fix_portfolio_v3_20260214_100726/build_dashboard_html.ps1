#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Date = "",
  [int]$Capital = 300000,
  [int]$Top = 200,
  [string]$OutDir = ".\reports",
  [switch]$Open,
  [switch]$ListDates
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-CsvSafe([string]$path){
  if(!(Test-Path $path)){ return $null }
  try { return Import-Csv -Path $path }
  catch { return Import-Csv -Path $path -Encoding UTF8 }
}

function Read-JsonSafe([string]$path){
  if(!(Test-Path $path)){ return $null }
  $txt = Get-Content $path -Raw -Encoding UTF8
  return $txt | ConvertFrom-Json
}

$root = (Resolve-Path ".").Path
$dataDir = Join-Path $root "data"
$reportsDir = Join-Path $root "reports"
if(!(Test-Path $OutDir)){ New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$allCsv = Join-Path $dataDir "all_stocks_daily.csv"
if(!(Test-Path $allCsv)){ throw "Missing: $allCsv" }

# list dates
if($ListDates){
  $dates = (Import-Csv $allCsv | Select-Object -ExpandProperty date -Unique | Sort-Object)
  $dates | ForEach-Object { $_ } | Out-Host
  return
}

# resolve date
if([string]::IsNullOrWhiteSpace($Date)){
  $Date = (Import-Csv $allCsv | Select-Object -ExpandProperty date | Sort-Object | Select-Object -Last 1)
}
$Date = $Date.Trim()

$marketJson = Join-Path $dataDir "market_snapshot_taiex.json"
$market = Read-JsonSafe $marketJson

$rankingCsv = Join-Path $dataDir ("ranking_{0}.csv" -f $Date)
$breadthJson = Join-Path $dataDir ("breadth_{0}.json" -f $Date)
$planCsv = Join-Path $dataDir ("portfolio_plan_{0}.csv" -f $Date)

$ranking = Read-CsvSafe $rankingCsv
$breadth = Read-JsonSafe $breadthJson
$plan = Read-CsvSafe $planCsv

# compute top stats
$allRows = Import-Csv $allCsv | Where-Object { $_.date -eq $Date }
$successCount = ($allRows | Measure-Object).Count

function H([string]$s){ return ($s -replace "&","&amp;" -replace "<","&lt;" -replace ">","&gt;" -replace '"',"&quot;") }

$riskMode = if($market){ $market.risk_mode } else { "UNKNOWN" }
$trendOk  = if($market){ [bool]$market.trend_ok } else { $false }
$marketOk = if($market){ [bool]$market.market_ok } else { $false }

$breadthRatio = if($breadth){ [double]$breadth.breadth_ratio } else { 0.0 }

# plan summary
$planHoldings = 0
$planUsed = 0
$planCash = $Capital
if($plan -and $plan.Count -ge 1){
  $planHoldings = [int]$plan[0].holdings
  $planUsed = [double]$plan[0].used_capital
  $planCash = [double]$plan[0].cash_reserve
}

# HTML
$outPath = Join-Path $OutDir ("dashboard_{0}.html" -f $Date)

$topRowsHtml = ""
if($ranking){
  $take = $ranking | Select-Object -First 20
  $topRowsHtml = ($take | ForEach-Object {
    $code = H($_.code)
    $name = if($_.name){ H($_.name) } else { "" }
    $rank = H($_.rank)
    $score = H($_.total_score)
    "<tr><td>$rank</td><td>$code</td><td>$name</td><td style='text-align:right'>$score</td></tr>"
  }) -join "`n"
}

$planRowsHtml = ""
if($plan){
  $take2 = $plan | Where-Object { $_.code -and $_.code.Trim() -ne "" } | Select-Object -First 25
  $planRowsHtml = ($take2 | ForEach-Object {
    $code = H($_.code)
    $name = if($_.name){ H($_.name) } else { "" }
    $rank = H($_.rank)
    $score = H($_.total_score)
    $w = "{0:P2}" -f ([double]$_.weight)
    $amt = "{0:N0}" -f ([double]$_.amount)
    "<tr><td>$rank</td><td>$code</td><td>$name</td><td style='text-align:right'>$score</td><td style='text-align:right'>$w</td><td style='text-align:right'>$amt</td></tr>"
  }) -join "`n"
}

$html = @"
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<title>Investment Assistant Dashboard - $Date</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{font-family:Segoe UI, Arial, sans-serif; margin:20px;}
.grid{display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:12px;}
.card{border:1px solid #ddd; border-radius:12px; padding:12px;}
h1{margin:0 0 12px 0;}
h2{margin:18px 0 8px 0; font-size:16px;}
table{border-collapse:collapse; width:100%;}
th,td{border-bottom:1px solid #eee; padding:6px 8px; font-size:13px;}
th{text-align:left; background:#fafafa;}
.small{color:#666; font-size:12px;}
.kpi{font-size:22px; font-weight:700;}
</style>
</head>
<body>
  <h1>Investment Assistant Dashboard</h1>
  <div class="small">Date: <b>$Date</b></div>

  <div class="grid" style="margin-top:12px;">
    <div class="card">
      <div class="small">Market Risk Mode</div>
      <div class="kpi">$riskMode</div>
      <div class="small">market_ok=$marketOk, trend_ok=$trendOk</div>
    </div>
    <div class="card">
      <div class="small">Universe Rows (today)</div>
      <div class="kpi">$successCount</div>
      <div class="small">from all_stocks_daily.csv</div>
    </div>
    <div class="card">
      <div class="small">Breadth Ratio (score>=threshold)</div>
      <div class="kpi">$("{0:P2}" -f $breadthRatio)</div>
      <div class="small">drives dynamic holdings</div>
    </div>
    <div class="card">
      <div class="small">Portfolio Plan</div>
      <div class="kpi">$planHoldings holdings</div>
      <div class="small">Used: $("{0:N0}" -f $planUsed) | Cash: $("{0:N0}" -f $planCash)</div>
    </div>
  </div>

  <h2>Top 20 Ranking</h2>
  <div class="card">
    <table>
      <thead><tr><th>Rank</th><th>Code</th><th>Name</th><th style="text-align:right">Score</th></tr></thead>
      <tbody>
        $topRowsHtml
      </tbody>
    </table>
  </div>

  <h2>Portfolio Allocation (Plan)</h2>
  <div class="card">
    <table>
      <thead><tr><th>Rank</th><th>Code</th><th>Name</th><th style="text-align:right">Score</th><th style="text-align:right">Weight</th><th style="text-align:right">Amount</th></tr></thead>
      <tbody>
        $planRowsHtml
      </tbody>
    </table>
    <div class="small" style="margin-top:8px;">Source: $([System.IO.Path]::GetFileName($planCsv))</div>
  </div>

  <h2>Backtest v3 (Portfolio)</h2>
  <div class="card">
    <div class="small">See: reports\portfolio_backtest_v3.csv and reports\portfolio_backtest_v3_summary.json</div>
  </div>
</body>
</html>
"@

[System.IO.File]::WriteAllText($outPath, $html.Replace("`r`n","`n").Replace("`n","`r`n"), $utf8NoBom)
Write-Host ("OK: wrote HTML -> {0}" -f $outPath) -ForegroundColor Green
if($Open){ Start-Process $outPath | Out-Null }
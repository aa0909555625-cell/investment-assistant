#Requires -Version 5.1
[CmdletBinding()]
param(
  [int[]]$TopNList = @(1,2,3,5),
  [int[]]$HoldDaysList = @(3,5,7,10),
  [double[]]$ScoreMinList = @(0, 49, 50, 51),
  [string]$OutDir = "",
  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ throw "OutDir is empty" }
  New-Item -ItemType Directory -Force -Path $p | Out-Null
}

# ===== ROOT (string paths; PS 5.1 safe) =====
$ScriptRoot  = (Resolve-Path (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path  # ...\scripts
$ProjectRoot = (Resolve-Path (Join-Path $ScriptRoot "..")).Path
$DefaultOut  = Join-Path $ProjectRoot "reports\sweep"

if([string]::IsNullOrWhiteSpace($OutDir)){
  $OutDir = $DefaultOut
} else {
  if(-not [System.IO.Path]::IsPathRooted($OutDir)){
    $OutDir = Join-Path $ProjectRoot $OutDir.Trim()
  }
}
EnsureDir $OutDir

$bt = Join-Path $ScriptRoot "backtest_v1.ps1"
if(!(Test-Path $bt)){ throw "Missing script: $bt" }

$today = (Get-Date).ToString("yyyy-MM-dd")
$summaryCsv = Join-Path $OutDir ("backtest_sweep_summary_{0}.csv" -f $today)
$leaderHtml = Join-Path $OutDir ("backtest_sweep_leaderboard_{0}.html" -f $today)

$results = New-Object System.Collections.Generic.List[object]

function Parse-MetricsFromHtml([string]$htmlPath){
  $txt = Get-Content $htmlPath -Raw -Encoding UTF8

  $mEq = [regex]::Match($txt, 'FinalEq=([0-9.]+)')
  $mDd = [regex]::Match($txt, 'MaxDD=([+\-]?[0-9.]+)%')
  $mWr = [regex]::Match($txt, 'WinRate=([0-9.]+)%')
  $mTr = [regex]::Match($txt, 'Trades=([0-9]+)')

  if(-not $mEq.Success){ throw "Parse fail: FinalEq not found in $htmlPath" }
  if(-not $mDd.Success){ throw "Parse fail: MaxDD not found in $htmlPath" }
  if(-not $mWr.Success){ throw "Parse fail: WinRate not found in $htmlPath" }
  if(-not $mTr.Success){ throw "Parse fail: Trades not found in $htmlPath" }

  return [pscustomobject]@{
    FinalEq  = [double]$mEq.Groups[1].Value
    MaxDDPct = [double]$mDd.Groups[1].Value
    WinRate  = [double]$mWr.Groups[1].Value
    Trades   = [int]$mTr.Groups[1].Value
  }
}

Write-Host "=== BACKTEST SWEEP ===" -ForegroundColor Cyan
Write-Host ("TopN={0} | HoldDays={1} | ScoreMin={2}" -f ($TopNList -join ","), ($HoldDaysList -join ","), ($ScoreMinList -join ",")) -ForegroundColor DarkGray
Write-Host ("OutDir={0}" -f $OutDir) -ForegroundColor DarkGray

foreach($top in $TopNList){
  foreach($hold in $HoldDaysList){
    foreach($min in $ScoreMinList){

      $tag = ("top{0}_hold{1}_min{2}" -f $top, $hold, ($min.ToString().Replace(".","p")))
      $caseDir = Join-Path $OutDir $tag
      EnsureDir $caseDir

      # backtest_v1 writes: backtest_report_YYYY-MM-DD.html in OutDir
      Write-Host ("[RUN] {0}" -f $tag) -ForegroundColor Yellow
      & $bt -TopN $top -HoldDays $hold -ScoreMin $min -OutDir $caseDir -Open:$false | Out-Null

      $htmlPath = Join-Path $caseDir ("backtest_report_{0}.html" -f $today)
      if(!(Test-Path $htmlPath)){
        throw "Expected report missing: $htmlPath"
      }

      $mx = Parse-MetricsFromHtml -htmlPath $htmlPath

      $results.Add([pscustomobject]@{
        TopN     = $top
        HoldDays = $hold
        ScoreMin = $min
        FinalEq  = [Math]::Round($mx.FinalEq, 6)
        MaxDDPct = [Math]::Round($mx.MaxDDPct, 2)
        WinRate  = [Math]::Round($mx.WinRate, 2)
        Trades   = $mx.Trades
        Report   = $htmlPath
      }) | Out-Null
    }
  }
}

# sort: higher FinalEq better, then less drawdown (MaxDDPct closer to 0 is better), then higher WinRate
$sorted = $results | Sort-Object `
  @{Expression="FinalEq";Descending=$true}, `
  @{Expression={ [Math]::Abs($_.MaxDDPct) };Descending=$false}, `
  @{Expression="WinRate";Descending=$true}

$sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $summaryCsv
Write-Host ("OK: wrote summary -> {0}" -f $summaryCsv) -ForegroundColor Green

# leaderboard html
$html = New-Object System.Collections.Generic.List[string]
[void]$html.Add("<!doctype html>")
[void]$html.Add("<html><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width, initial-scale=1"">")
[void]$html.Add("<title>Backtest Sweep - {0}</title>" -f $today)
[void]$html.Add("<style>body{font-family:Segoe UI,Arial,sans-serif;margin:20px;} table{border-collapse:collapse;width:100%;} th,td{border:1px solid #eee;padding:6px 8px;font-size:13px;} th{background:#fafafa;text-align:left;} .hint{color:#666;font-size:12px;margin:8px 0 16px;}</style>")
[void]$html.Add("</head><body>")
[void]$html.Add("<h2>Backtest Sweep</h2>")
[void]$html.Add("<div class=""hint"">Sorted by FinalEq desc, then |MaxDD| asc, then WinRate desc. Date={0}</div>" -f $today)
[void]$html.Add("<table><thead><tr><th>#</th><th>TopN</th><th>HoldDays</th><th>ScoreMin</th><th>FinalEq</th><th>MaxDD%</th><th>WinRate%</th><th>Trades</th><th>Report</th></tr></thead><tbody>")

$rank = 0
foreach($r in $sorted){
  $rank++
  $rep = $r.Report
  $repEsc = $rep.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;")
  [void]$html.Add(("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td style=""text-align:right"">{4}</td><td style=""text-align:right"">{5}</td><td style=""text-align:right"">{6}</td><td style=""text-align:right"">{7}</td><td><a href=""file:///{8}"">open</a></td></tr>" -f `
    $rank, $r.TopN, $r.HoldDays, $r.ScoreMin, $r.FinalEq, $r.MaxDDPct, $r.WinRate, $r.Trades, ($repEsc -replace "\\","/")))
}
[void]$html.Add("</tbody></table>")
[void]$html.Add("</body></html>")

[System.IO.File]::WriteAllText($leaderHtml, ($html -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
Write-Host ("OK: wrote leaderboard -> {0}" -f $leaderHtml) -ForegroundColor Green

# open best
if($Open){
  Start-Process $leaderHtml | Out-Null
}

# console best
$best = $sorted | Select-Object -First 1
Write-Host ("[BEST] TopN={0} HoldDays={1} ScoreMin={2} FinalEq={3} MaxDD={4}% WinRate={5}% Trades={6}" -f `
  $best.TopN, $best.HoldDays, $best.ScoreMin, $best.FinalEq, $best.MaxDDPct, $best.WinRate, $best.Trades) -ForegroundColor Cyan
Write-Host ("[BEST] Report: {0}" -f $best.Report) -ForegroundColor DarkGray
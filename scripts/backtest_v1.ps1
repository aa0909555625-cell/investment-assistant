#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$TopN = 3,
  [int]$HoldDays = 5,
  [double]$ScoreMin = 0,
  [string]$OutDir = "",
  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function SafeTrim([object]$v){
  if($null -eq $v){ return "" }
  return ($v.ToString()).Trim()
}
function ToDouble([object]$v){
  if($null -eq $v){ return [double]::NaN }
  $s = (SafeTrim $v)
  if([string]::IsNullOrWhiteSpace($s)){ return [double]::NaN }
  $s = $s -replace ",",""
  $d = 0.0
  if([double]::TryParse($s, [ref]$d)){ return $d }
  return [double]::NaN
}
function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ throw "OutDir is empty" }
  New-Item -ItemType Directory -Force -Path $p | Out-Null
}

try {
  # ===== ROOT =====
  $ScriptRoot  = (Resolve-Path (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
  $ProjectRoot = (Resolve-Path (Join-Path $ScriptRoot "..")).Path
  $DefaultOut  = Join-Path $ProjectRoot "reports"

  if([string]::IsNullOrWhiteSpace($OutDir)){
    $OutDir = $DefaultOut
  } else {
    if(-not [System.IO.Path]::IsPathRooted($OutDir)){
      $od = $OutDir.Trim()
      if($od -eq ".\reports" -or $od -eq "reports"){
        $OutDir = $DefaultOut
      } else {
        $OutDir = Join-Path $ProjectRoot $od
      }
    }
  }
  EnsureDir $OutDir

  $dataPath = Join-Path $ProjectRoot "data\all_stocks_daily.csv"
  if(!(Test-Path $dataPath)){ throw "Missing data file: $dataPath" }

  $rows = @(Import-Csv $dataPath)
  if($rows.Count -le 0){ throw "No rows in CSV: $dataPath" }

  # ===== parse =====
  $items = New-Object System.Collections.Generic.List[object]
  foreach($r in $rows){
    $d = SafeTrim $r.date
    $code = SafeTrim $r.code
    if([string]::IsNullOrWhiteSpace($d) -or [string]::IsNullOrWhiteSpace($code)){ continue }

    [datetime]$dt = [datetime]::MinValue
    if(-not [datetime]::TryParse($d, [ref]$dt)){ continue }

    $items.Add([pscustomobject]@{
      date = $dt.Date
      code = $code
      name = (SafeTrim $r.name)
      sector = (SafeTrim $r.sector)
      total_score = (ToDouble $r.total_score)
      change_percent = (ToDouble $r.change_percent)
    }) | Out-Null
  }

  if($items.Count -le 0){ throw "No usable parsed rows from: $dataPath" }

  # ===== build DateTime[] safely (PS 5.1) =====
  $uniq = @($items | Select-Object -ExpandProperty date | Sort-Object -Unique)
  $datesList = New-Object System.Collections.Generic.List[datetime]
  foreach($x in $uniq){ $datesList.Add([datetime]$x) | Out-Null }
  $dates = $datesList.ToArray()

  if($dates.Length -le ($HoldDays + 1)){
    throw "Not enough dates for HoldDays=$HoldDays (dates=$($dates.Length))"
  }

  # ===== byCode map =====
  $byCode = @{}
  foreach($it in $items){
    if(-not $byCode.ContainsKey($it.code)){ $byCode[$it.code] = @{} }
    $byCode[$it.code][[datetime]$it.date] = [double]$it.change_percent
  }

  function GetHoldReturn([string]$code, [datetime]$startDate, [object[]]$allDates, [int]$holdDays){
    $idx = [Array]::IndexOf($allDates, $startDate)
    if($idx -lt 0){ return $null }
    if(($idx + $holdDays) -ge $allDates.Length){ return $null }

    if(-not $byCode.ContainsKey($code)){ return $null }
    $map = $byCode[$code]

    $mul = 1.0
    for($k=1; $k -le $holdDays; $k++){
      $d = [datetime]$allDates[$idx + $k]
      if(-not $map.ContainsKey($d)){ return $null }
      $cp = [double]$map[$d]
      if([double]::IsNaN($cp)){ return $null }
      $mul *= (1.0 + ($cp/100.0))
    }
    return $mul
  }

  # ===== backtest (non-overlap cycles) =====
  $equity = 1.0
  $trades = New-Object System.Collections.Generic.List[object]
  $equityCurve = New-Object System.Collections.Generic.List[object]

  $i = 0
  while($i -lt ($dates.Length - $HoldDays - 1)){
    $d0 = [datetime]$dates[$i]

    $cands = @(
      $items |
        Where-Object { $_.date -eq $d0 -and (-not [double]::IsNaN($_.total_score)) -and $_.total_score -ge $ScoreMin } |
        Sort-Object total_score -Descending |
        Select-Object -First $TopN
    )

    $selected = New-Object System.Collections.Generic.List[object]
    foreach($c in $cands){
      $hr = GetHoldReturn -code $c.code -startDate $d0 -allDates $dates -holdDays $HoldDays
      if($null -ne $hr){
        $selected.Add([pscustomobject]@{
          signal_date = $d0
          code = $c.code
          name = $c.name
          sector = $c.sector
          score = [double]$c.total_score
          hold_mul = [double]$hr
        }) | Out-Null
      }
    }

    if($selected.Count -gt 0){
      $avgMul = ($selected | Measure-Object -Property hold_mul -Average).Average
      $cycleRet = $avgMul - 1.0
      $equity *= $avgMul

      $endDate = [datetime]$dates[$i + $HoldDays]

      foreach($s in $selected){
        $trades.Add([pscustomobject]@{
          signal_date = $s.signal_date.ToString("yyyy-MM-dd")
          end_date    = $endDate.ToString("yyyy-MM-dd")
          code        = $s.code
          name        = $s.name
          sector      = $s.sector
          score       = [Math]::Round($s.score, 2)
          hold_return = [Math]::Round(($s.hold_mul - 1.0) * 100.0, 2)
        }) | Out-Null
      }

      $equityCurve.Add([pscustomobject]@{
        date = $endDate.ToString("yyyy-MM-dd")
        equity = [Math]::Round($equity, 6)
        cycle_return_pct = [Math]::Round($cycleRet * 100.0, 2)
        picks = $selected.Count
      }) | Out-Null
    }

    $i += $HoldDays
  }

  # ===== metrics =====
  $finalEq = $equity

  # CRITICAL (PS 5.1 StrictMode): DO NOT use @($equityCurve)
  $curve = $equityCurve.ToArray()
  $tradeArr = $trades.ToArray()

  $maxDd = 0.0
  $peak = 1.0
  foreach($p in $curve){
    $e = [double]$p.equity
    if($e -gt $peak){ $peak = $e }
    if($peak -gt 0){
      $dd = ($e/$peak) - 1.0
      if($dd -lt $maxDd){ $maxDd = $dd }
    }
  }

  $win = 0; $loss = 0
  foreach($p in $curve){
    if([double]$p.cycle_return_pct -ge 0){ $win++ } else { $loss++ }
  }
  $winRate = 0.0
  if(($win+$loss) -gt 0){ $winRate = ($win/($win+$loss))*100.0 }

  # ===== report =====
  $today = (Get-Date).ToString("yyyy-MM-dd")
  $outPath = Join-Path $OutDir ("backtest_report_{0}.html" -f $today)

  $html = New-Object System.Collections.Generic.List[string]
  [void]$html.Add("<!doctype html>")
  [void]$html.Add("<html><head><meta charset=""utf-8"">")
  [void]$html.Add("<meta name=""viewport"" content=""width=device-width, initial-scale=1"">")
  [void]$html.Add("<title>Backtest v1 - $today</title>")
  [void]$html.Add("<style>body{font-family:Segoe UI,Arial,sans-serif;margin:20px;} .grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;} .card{border:1px solid #ddd;border-radius:10px;padding:12px;} table{border-collapse:collapse;width:100%;} th,td{border:1px solid #eee;padding:6px 8px;font-size:13px;} th{background:#fafafa;text-align:left;}</style>")
  [void]$html.Add("</head><body>")

  [void]$html.Add("<h2>Backtest v1</h2>")
  [void]$html.Add("<div class=""grid"">")
  [void]$html.Add("<div class=""card""><b>Params</b><br>TopN=$TopN<br>HoldDays=$HoldDays<br>ScoreMin=$ScoreMin</div>")
  [void]$html.Add("<div class=""card""><b>Result</b><br>FinalEq=$(("{0:N4}" -f $finalEq))<br>MaxDD=$(("{0:N2}%" -f ($maxDd*100)))<br>WinRate=$(("{0:N1}%" -f $winRate))</div>")
  [void]$html.Add("<div class=""card""><b>Data</b><br>Rows=$($items.Count)<br>Dates=$($dates.Length)<br>Trades=$($tradeArr.Length)</div>")
  [void]$html.Add("</div>")

  [void]$html.Add("<h3>Equity Curve (cycle)</h3>")
  [void]$html.Add("<table><thead><tr><th>Date</th><th>Equity</th><th>CycleReturn%</th><th>Picks</th></tr></thead><tbody>")
  foreach($p in $curve){
    [void]$html.Add("<tr><td>$($p.date)</td><td style=""text-align:right"">$($p.equity)</td><td style=""text-align:right"">$($p.cycle_return_pct)</td><td style=""text-align:right"">$($p.picks)</td></tr>")
  }
  [void]$html.Add("</tbody></table>")

  [void]$html.Add("<h3>Trades</h3>")
  [void]$html.Add("<table><thead><tr><th>Signal</th><th>End</th><th>Code</th><th>Name</th><th>Sector</th><th>Score</th><th>HoldReturn%</th></tr></thead><tbody>")
  foreach($t in $tradeArr){
    [void]$html.Add("<tr><td>$($t.signal_date)</td><td>$($t.end_date)</td><td>$($t.code)</td><td>$($t.name)</td><td>$($t.sector)</td><td style=""text-align:right"">$($t.score)</td><td style=""text-align:right"">$($t.hold_return)</td></tr>")
  }
  [void]$html.Add("</tbody></table>")

  [void]$html.Add("</body></html>")

  [System.IO.File]::WriteAllText($outPath, ($html -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
  Write-Host ("OK: wrote report -> {0}" -f $outPath) -ForegroundColor Green
  Write-Host ("[INFO] FinalEq={0:N4} MaxDD={1:N2}% WinRate={2:N1}% Trades={3}" -f $finalEq, ($maxDd*100), $winRate, $tradeArr.Length) -ForegroundColor DarkGray

  if($Open){ Start-Process $outPath | Out-Null }

} catch {
  Write-Host ("[ERROR] {0}: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message) -ForegroundColor Red
  throw
}
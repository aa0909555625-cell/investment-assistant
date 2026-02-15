param(
  [string]$Date = "",
  [int]$Top = 20,
  [int]$Capital = 100000,
  [int]$Pick = 5,
  [switch]$OpenReport,
  [switch]$EnsureSampleData
)

$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$path){ if(!(Test-Path $path)){ New-Item -ItemType Directory -Path $path | Out-Null } }
function Ensure-File([string]$path,[string]$content){
  if(Test-Path $path){ Write-Host "SKIP: exists -> $path" }
  else { $content | Set-Content -Path $path -Encoding UTF8; Write-Host "OK: created -> $path" }
}
function HasCol($row,[string]$name){ return ($null -ne $row) -and ($null -ne $row.PSObject.Properties[$name]) }
function GetVal($row,[string]$name,$default=""){ if(HasCol $row $name){ return $row.$name }; return $default }
function ToInt($x,[int]$d=0){ try{ [int]$x } catch { $d } }
function ToDbl($x,[double]$d=0){ try{ [double]$x } catch { $d } }
function Clamp([double]$x,[double]$min,[double]$max){ if($x -lt $min){$min}else{ if($x -gt $max){$max}else{$x} } }

function MarketAction([int]$score){ if($score -ge 70){"BUY"} elseif($score -ge 40){"HOLD"} else{"SELL"} }
function InvestRatioByAction([string]$action){
  switch($action){
    "BUY" {0.8}
    "HOLD"{0.5}
    "SELL"{0.2}
    default{0.4}
  }
}
function BucketLabel([string]$bucket){
  switch($bucket){
    "trend"{"趨勢/動能"}
    "stable"{"穩健/低波"}
    "liquidity"{"成交量/流動性"}
    "volatility"{"波動/事件"}
    default{$bucket}
  }
}

# ----------------------------
# Paths
# ----------------------------
$base=".\data"
$reports=".\reports"
Ensure-Dir $base
Ensure-Dir $reports

$dailyScoresFile    = Join-Path $base "daily_scores.csv"
$marketSnapshotFile = Join-Path $base "market_snapshot.csv"
$codeNameMapFile    = Join-Path $base "code_name_map.csv"   # optional

# ----------------------------
# Sample data (optional)
# ----------------------------
if($EnsureSampleData){
  Ensure-File $dailyScoresFile @"
date,code,name,bucket,total_score,liquidity,volatility,momentum,change_percent,warnings
2026-02-10,3028,增你強,trend,67,5,15,96,9.2,"低流動性;單日大幅波動(>=8%)"
2026-02-10,3665,貿聯-KY,trend,66,5,20,97,8.3,"低流動性;單日大幅波動(>=8%)"
2026-02-10,2363,矽統,trend,65,7,29,97,9.1,"低流動性;單日大幅波動(>=8%)"
2026-02-10,3653,健策,trend,64,10,47,100,4.2,"低流動性"
2026-02-10,3432,台端,trend,61,0,33,96,8.8,"低流動性;單日大幅波動(>=8%)"
2026-02-10,3167,大量,trend,61,10,49,96,8.1,"低流動性;單日大幅波動(>=8%)"
2026-02-10,009816,凱基台灣TOP50,stable,87,75,8,61,1.0,
2026-02-10,00878,國泰永續高股息,stable,78,35,3,53,0.6,
2026-02-10,0056,元大高股息,stable,76,27,3,53,0.5,
2026-02-10,0050,元大台灣50,stable,75,37,9,60,0.9,
2026-02-10,00919,群益台灣精選高息,stable,75,23,3,52,0.5,
2026-02-10,00981A,主動統一台股增長,stable,75,34,8,58,0.8,
2026-02-10,2330,台積電,liquidity,93,100,17,67,1.3,
2026-02-10,2337,旺宏,liquidity,85,100,51,54,2.2,
2026-02-10,6770,力積電,liquidity,67,71,40,53,1.9,
2026-02-10,2344,華邦電,liquidity,65,73,47,30,1.1,
2026-02-10,4737,華廣,volatility,73,0,100,65,7.9,"高波動;低流動性"
2026-02-10,8046,南電,volatility,64,18,87,41,6.4,"高波動"
2026-02-10,3550,聯穎,volatility,62,14,85,43,6.1,"高波動"
2026-02-10,6887,寶綠特-KY,volatility,60,0,94,19,5.2,"高波動;低流動性"
"@

  Ensure-File $marketSnapshotFile @"
date,up_count,down_count,flat_count,limit_up,limit_down,volume
2026-02-10,812,632,128,42,9,3820
"@
}

# ----------------------------
# Determine date
# ----------------------------
if([string]::IsNullOrWhiteSpace($Date)){
  if(Test-Path $dailyScoresFile){
    $tmp=@(Import-Csv $dailyScoresFile)
    if($tmp.Count -gt 0 -and (HasCol $tmp[0] "date")){
      $Date = ($tmp | Sort-Object { [datetime]$_.date } | Select-Object -Last 1).date
    } else {
      $Date = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
    }
  } else {
    $Date = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
  }
}

if(!(Test-Path $dailyScoresFile)){
  Write-Host "ERROR: missing -> $dailyScoresFile" -ForegroundColor Red
  Write-Host "Fix: put daily_scores.csv into .\data\ or run with -EnsureSampleData" -ForegroundColor Yellow
  exit 1
}

# ----------------------------
# Load daily scores
# ----------------------------
$all=@(Import-Csv $dailyScoresFile)
$rows=@($all | Where-Object { (GetVal $_ "date" "") -eq $Date })
if($rows.Count -eq 0){
  Write-Host "ERROR: no rows for date=$Date in $dailyScoresFile" -ForegroundColor Red
  exit 1
}

# ----------------------------
# Optional code->name map
# CSV: code,name
# ----------------------------
$codeName=@{}
if(Test-Path $codeNameMapFile){
  $m=@(Import-Csv $codeNameMapFile)
  foreach($x in $m){
    $c = (GetVal $x "code" "")
    $n = (GetVal $x "name" "")
    if($c -and $n){ $codeName[$c]=$n }
  }
}

# ----------------------------
# Normalize rows
# (name fallback: map -> existing name -> code)
# ----------------------------
$norm = foreach($r in $rows){
  $code = (GetVal $r "code" "")
  $name = (GetVal $r "name" "")
  if(([string]::IsNullOrWhiteSpace($name)) -or ($name -eq $code)){
    if($codeName.ContainsKey($code)){ $name = $codeName[$code] }
  }
  if([string]::IsNullOrWhiteSpace($name)){ $name = $code }

  [pscustomobject]@{
    date           = (GetVal $r "date" "")
    code           = $code
    name           = $name
    bucket         = (GetVal $r "bucket" "")
    total_score    = ToDbl (GetVal $r "total_score" 0) 0
    liquidity      = ToDbl (GetVal $r "liquidity" 0) 0
    volatility     = ToDbl (GetVal $r "volatility" 0) 0
    momentum       = ToDbl (GetVal $r "momentum" 0) 0
    change_percent = ToDbl (GetVal $r "change_percent" 0) 0
    warnings       = (GetVal $r "warnings" "")
  }
}

# ----------------------------
# Market snapshot (optional)
# ----------------------------
$market=$null
if(Test-Path $marketSnapshotFile){
  $ms=@(Import-Csv $marketSnapshotFile)
  $m=@($ms | Where-Object { (GetVal $_ "date" "") -eq $Date } | Select-Object -First 1)
  if($m.Count -gt 0){
    $market=[pscustomobject]@{
      up_count   = ToInt (GetVal $m[0] "up_count" 0) 0
      down_count = ToInt (GetVal $m[0] "down_count" 0) 0
      flat_count = ToInt (GetVal $m[0] "flat_count" 0) 0
      limit_up   = ToInt (GetVal $m[0] "limit_up" 0) 0
      limit_down = ToInt (GetVal $m[0] "limit_down" 0) 0
      volume     = ToDbl (GetVal $m[0] "volume" 0) 0
    }
  }
}

# ----------------------------
# Scores
# ----------------------------
$avgTotal = ToDbl (($norm | Measure-Object total_score -Average).Average) 0
$extremeCount = @(
  $norm | Where-Object {
    ( [math]::Abs( (ToDbl $_.change_percent 0) ) -ge 8 ) -or
    ( (ToDbl $_.volatility 0) -ge 85 )
  }
).Count
$extremeRatio = if($norm.Count -gt 0){ ($extremeCount / [double]$norm.Count) } else { 0.0 }

$breadthScore=0.0
if($market -ne $null){
  $den=[double]($market.up_count + $market.down_count)
  if($den -gt 0){ $breadthScore = (([double]$market.up_count / $den) * 40.0) }
}

$avgScorePart = Clamp ((($avgTotal/100.0)*40.0)) 0.0 40.0
$penalty      = Clamp (($extremeRatio*20.0)) 0.0 20.0

$marketScore = [int]([math]::Round((Clamp (($breadthScore + $avgScorePart + (40.0 - $penalty))) 0.0 100.0),0))
$aggrScore   = [int]([math]::Round((Clamp (($breadthScore + $avgScorePart + (40.0 - (2.0*$penalty)))) 0.0 100.0),0))

$action = MarketAction $marketScore
$investRatioBase = InvestRatioByAction $action

# ----------------------------
# Top list (actual count)
# ----------------------------
$topN = [math]::Min($Top, $norm.Count)
$topRows = @($norm | Sort-Object total_score -Descending | Select-Object -First $topN)

# pick
$pickRows = @(
  $topRows |
    Where-Object { $_.total_score -ge 60 } |
    Select-Object -First ([math]::Max($Pick,1))
)
$allocTotal = [math]::Round($Capital * $investRatioBase)
$allocEach = if($pickRows.Count -gt 0){ [math]::Floor($allocTotal / $pickRows.Count) } else { 0 }

# ----------------------------
# Report
# ----------------------------
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$outTxt = Join-Path $reports ("tw_top{0}_{1}_{2}.txt" -f $topN, ($Date -replace "-",""), $ts)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(("台股 Top{0} 日報" -f $topN))
$lines.Add(("日期：{0}（v1.1｜單日資料規則型，非投資建議）" -f $Date))
$lines.Add("")

$lines.Add("市場盤口總覽（全市場）")
$lines.Add(("市場狀態：{0}" -f $action))
$lines.Add(("市場總分：{0}/100" -f $marketScore))
$lines.Add(("資金積極度：{0}/100" -f $aggrScore))
$lines.Add("（分數越高＝越適合進場/加碼；越低＝偏防守/減碼）")
$lines.Add("")

$lines.Add("市場廣度（漲/跌家數）")
if($market -eq $null){
  $lines.Add("尚無盤口資料（market_snapshot 尚未生成或日期不匹配）")
} else {
  $lines.Add(("上漲：{0}｜下跌：{1}｜平盤：{2}｜漲停：{3}｜跌停：{4}｜成交量：{5}" -f $market.up_count,$market.down_count,$market.flat_count,$market.limit_up,$market.limit_down,$market.volume))
}
$lines.Add("")

$lines.Add(("Top{0} 名單" -f $topN))
$lines.Add("#`t代號`t名稱`tBucket`t總分`tSignals`tWarnings")

$i=1
foreach($r in $topRows){
  $sig = (@{ liquidity=[int]$r.liquidity; volatility=[int]$r.volatility; momentum=[int]$r.momentum } | ConvertTo-Json -Compress)
  $warn = $r.warnings
  $lines.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $i,$r.code,$r.name,$r.bucket,[int]$r.total_score,$sig,$warn))
  $i++
}

$lines.Add("")
$lines.Add(("參數：?capital={0}&pick={1}（資金配置表）" -f $Capital,$Pick))
$lines.Add("")

$lines.Add("資金配置表（非選股，只是把資金平均切給前 N 名）")
$lines.Add(("建議動用資金（依市場狀態 {0}）：{1}（比例 {2:P0}）" -f $action,$allocTotal,$investRatioBase))
if($pickRows.Count -eq 0){
  $lines.Add("（無符合條件的 pick）")
} else {
  foreach($p in $pickRows){
    $lines.Add(("- {0} {1}｜{2}｜score={3}｜建議額度≈{4}" -f $p.code,$p.name,(BucketLabel $p.bucket),[int]$p.total_score,$allocEach))
  }
}

$lines.Add("")
$lines.Add("AI 文字解讀（v1.1｜規則型）")
$lines.Add("注意：目前僅用當日資料做相對排名，非投資建議。")
$lines.Add("")

$j=1
foreach($r in $topRows){
  $bucketText = BucketLabel $r.bucket
  $warnText = ""
  if(![string]::IsNullOrWhiteSpace($r.warnings)){ $warnText = (" ⚠ {0}" -f $r.warnings) }

  $lines.Add(("{0:D2}) {1}｜{2}（{3}｜總分 {4}）" -f $j,$r.code,$r.name,$bucketText,[int]$r.total_score))
  $lines.Add(("    指標：流動性 {0}｜波動 {1}｜動能 {2}" -f ([int]$r.liquidity),([int]$r.volatility),([int]$r.momentum)))

  if($r.bucket -eq "stable"){
    $lines.Add(("    解讀：波動相對較低、走勢較穩；若同時量能偏弱，容易出現流動性風險。{0}" -f $warnText).TrimEnd())
  } elseif($r.bucket -eq "liquidity"){
    $lines.Add(("    解讀：量能/成交相對強，適合做『可進可出』的觀察標的；仍需搭配波動與動能判斷。{0}" -f $warnText).TrimEnd())
  } elseif($r.bucket -eq "volatility"){
    $lines.Add(("    解讀：當日振幅相對大，屬事件/波動型標的；風險較高，需嚴格控位與停損。{0}" -f $warnText).TrimEnd())
  } else {
    $lines.Add(("    解讀：動能相對突出（當日變動在全市場屬前段），仍需留意量能/波動是否匹配。{0}" -f $warnText).TrimEnd())
  }
  $lines.Add("")
  $j++
}

$lines | Set-Content -Path $outTxt -Encoding UTF8
Write-Host "OK: wrote TXT -> $outTxt" -ForegroundColor Green
if($OpenReport){ Start-Process notepad.exe $outTxt | Out-Null }

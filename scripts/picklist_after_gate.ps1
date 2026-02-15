#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Date,
  [Parameter(Mandatory=$true)][string]$DailyCsv,
  [Parameter(Mandatory=$true)][string]$DecisionJson,
  [int]$Top = 200,
  [int]$MaxPositions = 5,
  [int]$Capital = 300000,
  [string]$ReportsDir = ".\reports",
  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p){ if(!(Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

function Get-FirstProp {
  param(
    [Parameter(Mandatory=$true)]$Obj,
    [Parameter(Mandatory=$true)][string[]]$Paths,
    $Default = $null
  )
  foreach($path in $Paths){
    try {
      $cur = $Obj
      foreach($seg in $path.Split(".")){
        if($null -eq $cur){ throw "null" }
        # note: PSObject property access; will throw in StrictMode if missing
        $cur = $cur.$seg
      }
      if($null -ne $cur -and "$cur" -ne ""){ return $cur }
    } catch { }
  }
  return $Default
}

if(!(Test-Path $DailyCsv)){ throw "DailyCsv not found: $DailyCsv" }
if(!(Test-Path $DecisionJson)){ throw "DecisionJson not found: $DecisionJson" }
EnsureDir $ReportsDir

$dec = Get-Content $DecisionJson -Raw -Encoding UTF8 | ConvertFrom-Json

# IMPORTANT:
# Gate validity is enforced by run_daily_with_gate.ps1 calling gate_check.ps1 first.
# Therefore, picklist should NOT hard-fail if decision json lacks 'gate' field.
$allowTrade = $true
$allowVal = Get-FirstProp -Obj $dec -Paths @("allow_trade","allowTrade","decision_v1.allow_trade","decision_v1.allowTrade","pass_gate","passGate") -Default $null
if($null -ne $allowVal){
  try { $allowTrade = [bool]$allowVal } catch { $allowTrade = $true }
}

if(-not $allowTrade){
  Write-Host "Decision says allow_trade=false -> no picklist output" -ForegroundColor Yellow
  exit 10
}

# knobs (fallback paths)
$exposureRaw = Get-FirstProp -Obj $dec -Paths @("exposure","suggested_exposure","decision_v1.exposure","decision.exposure") -Default 0.5
$exposure = 0.5
try { $exposure = [double]$exposureRaw } catch { $exposure = 0.5 }
if($exposure -lt 0){ $exposure = 0 }
if($exposure -gt 1){ $exposure = 1 }

$perTradeRaw = Get-FirstProp -Obj $dec -Paths @("per_trade_budget","perTradeBudget","decision_v1.per_trade_budget","decision_v1.perTradeBudget") -Default 0
$perTradeBudget = 0
try { $perTradeBudget = [double]$perTradeRaw } catch { $perTradeBudget = 0 }

$maxPosRaw = Get-FirstProp -Obj $dec -Paths @("max_position_value","maxPositionValue","decision_v1.max_position_value","decision_v1.maxPositionValue") -Default 0
$maxPosValue = 0
try { $maxPosValue = [double]$maxPosRaw } catch { $maxPosValue = 0 }

$allocTotal = [math]::Floor([double]$Capital * $exposure)
if($allocTotal -lt 0){ $allocTotal = 0 }

# read daily universe for date
$rows = Import-Csv $DailyCsv | Where-Object { $_.date -eq $Date }
if(-not $rows){ throw "No rows for Date=$Date in $DailyCsv" }

$rows2 = $rows | Where-Object { $_.total_score -ne $null -and $_.total_score -ne "" }
$sorted = $rows2 | Sort-Object {[double]$_.total_score} -Descending

# choose: Top universe then take MaxPositions
$picks = $sorted | Select-Object -First ([math]::Max($Top,1)) | Select-Object -First ([math]::Max($MaxPositions,1))
if(-not $picks){
  Write-Host "No picks after filtering." -ForegroundColor Yellow
  exit 0
}

$count = $picks.Count
$baseEach = [math]::Floor($allocTotal / $count)
if($perTradeBudget -gt 0){ $baseEach = [math]::Min($baseEach, [math]::Floor($perTradeBudget)) }
if($maxPosValue -gt 0){ $baseEach = [math]::Min($baseEach, [math]::Floor($maxPosValue)) }
if($baseEach -lt 0){ $baseEach = 0 }

$outCsv = Join-Path $ReportsDir ("picks_{0}.csv" -f $Date)
$outMd  = Join-Path $ReportsDir ("allocation_{0}.md" -f $Date)

$csvOut = @()
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# PickList / Allocation")
$md.Add("")
$md.Add(("Date: {0}" -f $Date))
$md.Add(("Exposure: {0:P0} | Capital: {1:N0} | AllocTotal: {2:N0} | MaxPositions: {3}" -f $exposure,$Capital,$allocTotal,$MaxPositions))
if($perTradeBudget -gt 0){ $md.Add(("PerTradeBudget(decision): {0:N0}" -f $perTradeBudget)) }
if($maxPosValue -gt 0){ $md.Add(("MaxPositionValue(decision): {0:N0}" -f $maxPosValue)) }
$md.Add(("AllocEach(final): {0:N0}" -f $baseEach))
$md.Add("")
$md.Add("| code | name | sector | total_score | alloc_twd | note |")
$md.Add("|---:|---|---|---:|---:|---|")

foreach($r in $picks){
  $code = "$($r.code)"; $name="$($r.name)"; $sector="$($r.sector)"
  $score = [double]$r.total_score
  $alloc = $baseEach
  $note = "Gate already passed upstream; allocation=min(exposure*capital/count, per_trade_budget, max_position_value)"
  $csvOut += [pscustomobject]@{
    date=$Date; code=$code; name=$name; sector=$sector; total_score=$score; alloc_twd=$alloc
  }
  $md.Add(("| {0} | {1} | {2} | {3:N1} | {4:N0} | {5} |" -f $code,$name,$sector,$score,$alloc,$note))
}

$csvOut | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
[System.IO.File]::WriteAllText($outMd, (($md -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("OK: wrote -> {0}" -f $outCsv) -ForegroundColor Green
Write-Host ("OK: wrote -> {0}" -f $outMd)  -ForegroundColor Green

if($Open){
  Start-Process $outMd  | Out-Null
  Start-Process $outCsv | Out-Null
}

exit 0
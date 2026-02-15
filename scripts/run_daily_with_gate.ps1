#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Date,
  [int]$Capital = 300000,
  [int]$Top = 200,
  [int]$MaxPositions = 5,
  [string]$ReportsDir = ".\reports",
  [string]$DailyCsv = ".\data\all_stocks_daily.csv",
  [string]$TaiexCsv = ".\data\taiex_daily.csv",
  [ValidateSet("stock","etf","daytrade_stock")][string]$CostMode = "stock",
  [double]$SlippageBps = 5.0,
  [switch]$Open,
  [switch]$MakePick
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p){ if(!(Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

function Find-Python {
  $venv = ".\.venv\Scripts\python.exe"
  if(Test-Path $venv){ return (Resolve-Path $venv).Path }
  return "python"
}

function Find-PyByContent {
  param(
    [Parameter(Mandatory=$true)][string[]]$MustContainAny,
    [string[]]$AlsoContainAll = @()
  )
  $cand = Get-ChildItem ".\scripts" -File -Filter "*.py" -ErrorAction SilentlyContinue
  foreach($f in $cand){
    $txt = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if(-not $txt){ continue }
    $hitAny = $false
    foreach($k in $MustContainAny){
      if($txt -match [regex]::Escape($k)){ $hitAny = $true; break }
    }
    if(-not $hitAny){ continue }

    $hitAll = $true
    foreach($k in $AlsoContainAll){
      if($txt -notmatch [regex]::Escape($k)){ $hitAll = $false; break }
    }
    if($hitAll){ return $f.FullName }
  }
  return $null
}

function Invoke-GateCheck {
  param(
    [Parameter(Mandatory=$true)][string]$GateScript,
    [Parameter(Mandatory=$true)][string]$Date,
    [Parameter(Mandatory=$true)][string]$DecisionPath
  )

  if(!(Test-Path $GateScript)){ throw "Gate script not found: $GateScript" }

  # Discover accepted parameters
  $cmd = Get-Command $GateScript -ErrorAction Stop
  $pnames = @()
  if($cmd -and $cmd.Parameters){
    $pnames = $cmd.Parameters.Keys
  }

  # Prefer common names
  $decisionParam = $null
  foreach($n in @("DecisionJson","DecisionPath","DecisionFile","Decision","Path","JsonPath","File")){
    if($pnames -contains $n){ $decisionParam = $n; break }
  }

  $args = @{}
  if($pnames -contains "Date"){ $args["Date"] = $Date }
  elseif($pnames -contains "date"){ $args["date"] = $Date }

  if($null -ne $decisionParam){
    $args[$decisionParam] = $DecisionPath
  } else {
    # If gate_check takes only one positional path, pass it as arg 0
    # but only if it has at least one parameter
    if($pnames.Count -eq 0){
      throw "gate_check has no discoverable parameters; cannot pass decision path safely."
    }
  }

  if($args.Count -gt 0){
    & $GateScript @args | Out-Host
  } else {
    # Fallback: try positional call (DecisionPath only)
    & $GateScript $DecisionPath | Out-Host
  }

  return $LASTEXITCODE
}

Write-Host ("=== RUN DAILY WITH GATE === Date={0} Capital={1} Top={2} MaxPos={3}" -f $Date,$Capital,$Top,$MaxPositions) -ForegroundColor Cyan

if(!(Test-Path $DailyCsv)){ throw "DailyCsv not found: $DailyCsv" }
if(!(Test-Path $TaiexCsv)){ Write-Host "WARN: TaiexCsv not found: $TaiexCsv (regime may degrade)" -ForegroundColor Yellow }

EnsureDir $ReportsDir

# outputs
$sectorHeat   = Join-Path $ReportsDir ("sector_heat_{0}.json" -f $Date)
$snapshotJson = Join-Path $ReportsDir ("market_snapshot_{0}.json" -f $Date)
$regimeJson   = Join-Path $ReportsDir ("regime_{0}.json" -f $Date)
$decisionJson = Join-Path $ReportsDir ("decision_{0}.json" -f $Date)

# stable scripts
$dashScript   = ".\scripts\build_dashboard_html.ps1"
$gateScript   = ".\scripts\gate_check.ps1"
$routerScript = ".\scripts\phaseE_strategy_router.py"
$costScript   = ".\scripts\cost_model_min.py"
$pickScript   = ".\scripts\picklist_after_gate.ps1"

foreach($s in @($dashScript,$gateScript,$routerScript,$costScript,$pickScript)){
  if(!(Test-Path $s)){ throw "Missing required script: $s" }
}

$py = Find-Python

# ---- 1) sector heat (prefer existing report) ----
if(!(Test-Path $sectorHeat)){
  $sectorPy = Find-PyByContent -MustContainAny @("sector_heat","sector heat") -AlsoContainAll @("argparse")
  if($null -eq $sectorPy){
    $list = (Get-ChildItem ".\scripts" -File -Filter "*.py" | Select-Object -ExpandProperty Name) -join ", "
    throw "Cannot find sector heat generator. Need reports\sector_heat_$Date.json OR a python script containing 'sector_heat'. scripts: $list"
  }
  Write-Host ("[AUTO] sector heat via {0}" -f $sectorPy) -ForegroundColor DarkGray
  & $py $sectorPy --date $Date --daily_csv $DailyCsv --out $sectorHeat | Out-Host
}
Write-Host $sectorHeat

# ---- 2) snapshot ----
if(!(Test-Path $snapshotJson)){
  $snapPy = Find-PyByContent -MustContainAny @("market_snapshot","market snapshot","snapshot") -AlsoContainAll @("argparse")
  if($null -eq $snapPy){
    $list = (Get-ChildItem ".\scripts" -File -Filter "*.py" | Select-Object -ExpandProperty Name) -join ", "
    throw "Cannot find snapshot generator. Need reports\market_snapshot_$Date.json OR a python script containing 'market_snapshot'. scripts: $list"
  }
  Write-Host ("[AUTO] snapshot via {0}" -f $snapPy) -ForegroundColor DarkGray
  & $py $snapPy --date $Date --daily_csv $DailyCsv --sector_heat $sectorHeat --out $snapshotJson --taiex_csv $TaiexCsv | Out-Host
}
Write-Host $snapshotJson

# ---- 3) regime ----
if(!(Test-Path $regimeJson)){
  $regPy = Find-PyByContent -MustContainAny @("no_trade_flag","market_regime","volatility_state","trend_strength","regime") -AlsoContainAll @("argparse")
  if($null -eq $regPy){
    $list = (Get-ChildItem ".\scripts" -File -Filter "*.py" | Select-Object -ExpandProperty Name) -join ", "
    throw "Cannot find regime generator. Need reports\regime_$Date.json OR a python script containing 'regime'. scripts: $list"
  }
  Write-Host ("[AUTO] regime via {0}" -f $regPy) -ForegroundColor DarkGray
  & $py $regPy --date $Date --snapshot $snapshotJson --out $regimeJson --taiex_csv $TaiexCsv | Out-Host
}
Write-Host $regimeJson

# ---- 4) decision router (IMPORTANT: phaseE_strategy_router.py does NOT accept --regime) ----
try {
  & $py $routerScript --date $Date --snapshot $snapshotJson --out $decisionJson --capital $Capital --max_positions $MaxPositions | Out-Host
} catch {
  throw "Router failed: $($_.Exception.Message)"
}
if(!(Test-Path $decisionJson)){
  throw "Router did not produce decision json: $decisionJson"
}
Write-Host $decisionJson

# ---- 5) cost inject ----
& $py $costScript --decision $decisionJson --mode $CostMode --slippage_bps $SlippageBps | Out-Host

# ---- 6) gate check (auto-parameter) ----
$gateExit = Invoke-GateCheck -GateScript $gateScript -Date $Date -DecisionPath $decisionJson

# ---- 7) dashboard always build ----
& $dashScript -Date $Date -Capital $Capital -Top $Top -OutDir $ReportsDir -Open:$Open | Out-Host

if($gateExit -ne 0){
  Write-Host ("GATE=BLOCK exit={0} Date={1} (dashboard built, no picklist)" -f $gateExit,$Date) -ForegroundColor Yellow
  exit 10
}

Write-Host ("GATE=OK Date={0}" -f $Date) -ForegroundColor Green

# ---- 8) picklist (Gate OK only) ----
$doPick = $true
if($PSBoundParameters.ContainsKey("MakePick")){
  $doPick = [bool]$MakePick
}
if($doPick){
  & $pickScript -Date $Date -DailyCsv $DailyCsv -DecisionJson $decisionJson -Top $Top -MaxPositions $MaxPositions -Capital $Capital -ReportsDir $ReportsDir -Open:$Open | Out-Host
}

Write-Host "PASS: Gate OK. Downstream picklist done." -ForegroundColor Green
exit 0
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Date = "",
  [int]$Capital = 300000,
  [int]$Top = 200,
  [int]$MaxPositions = 5,
  [ValidateSet("stock","etf","daytrade_stock")][string]$CostMode = "stock",
  [double]$SlippageBps = 5.0,
  [string]$ReportsDir = ".\reports",
  [string]$DailyCsv = ".\data\all_stocks_daily.csv",
  [string]$TaiexCsv = ".\data\taiex_daily.csv",
  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if([string]::IsNullOrWhiteSpace($Date)){
  $Date = (Get-Date).ToString("yyyy-MM-dd")
}

$runner = ".\scripts\run_daily_with_gate.ps1"
if(!(Test-Path $runner)){ throw "Missing: $runner" }

& $runner -Date $Date -Capital $Capital -Top $Top -MaxPositions $MaxPositions -ReportsDir $ReportsDir -DailyCsv $DailyCsv -TaiexCsv $TaiexCsv -CostMode $CostMode -SlippageBps $SlippageBps -Open:$Open | Out-Host
$exit = $LASTEXITCODE

$dash  = Join-Path $ReportsDir ("dashboard_{0}.html" -f $Date)
$picks = Join-Path $ReportsDir ("picks_{0}.csv" -f $Date)
$alloc = Join-Path $ReportsDir ("allocation_{0}.md" -f $Date)

Write-Host ""
Write-Host ("Exit={0}" -f $exit) -ForegroundColor Cyan
Write-Host ("Dashboard : {0}" -f $dash)  -ForegroundColor Green
Write-Host ("Allocation: {0}" -f $alloc) -ForegroundColor Green
Write-Host ("Picks     : {0}" -f $picks) -ForegroundColor Green

if($Open){
  if(Test-Path $dash){ Start-Process $dash | Out-Null }
  if(Test-Path $alloc){ Start-Process $alloc | Out-Null }
  if(Test-Path $picks){ Start-Process $picks | Out-Null }
}

exit $exit
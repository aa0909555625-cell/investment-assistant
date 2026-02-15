#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$TopN = 3,
  [int]$HoldDays = 5,
  [double]$ScoreMin = 0,
  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot  = (Resolve-Path (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptRoot "..")).Path

$bt = Join-Path $ScriptRoot "backtest_v1.ps1"
if(!(Test-Path $bt)){ throw "Missing: $bt" }

Push-Location $ProjectRoot
try {
  & $bt -TopN $TopN -HoldDays $HoldDays -ScoreMin $ScoreMin -Open:$Open
} finally {
  Pop-Location
}
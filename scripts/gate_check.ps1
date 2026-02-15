#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Date = "",
  [string]$ReportsDir = ".\reports",
  [string]$DecisionPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if([string]::IsNullOrWhiteSpace($Date)){
  $Date = (Get-Date).ToString("yyyy-MM-dd")
}

$rep = (Resolve-Path $ReportsDir -ErrorAction SilentlyContinue)
if($null -eq $rep){
  throw "ReportsDir not found: $ReportsDir"
}
$rep = $rep.Path

if([string]::IsNullOrWhiteSpace($DecisionPath)){
  $DecisionPath = Join-Path $rep ("decision_{0}.json" -f $Date)
}

if(!(Test-Path $DecisionPath)){
  throw "Decision file missing: $DecisionPath"
}

$dec = (Get-Content $DecisionPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$d = $dec.decision
$inp = $dec.inputs

$gate = ""
$allow = $true
$reason = ""

if($null -ne $d){
  $gate = [string]$d.gate
  if($null -ne $d.allow_trade){ $allow = [bool]$d.allow_trade }
}
if($null -ne $inp){
  $reason = [string]$inp.no_trade_reason
}

if($gate -eq "NO_TRADE" -or $allow -eq $false){
  if([string]::IsNullOrWhiteSpace($reason)){ $reason = "Gate is NO_TRADE" }
  Write-Host ("GATE=NO_TRADE Date={0} Reason={1}" -f $Date, $reason) -ForegroundColor Yellow
  exit 10
}

Write-Host ("GATE=OK Date={0}" -f $Date) -ForegroundColor Green
exit 0
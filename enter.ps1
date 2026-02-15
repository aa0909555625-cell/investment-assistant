#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Capital = 300000,
  [int]$Top = 4000,
  [switch]$RunUpdate,
  [switch]$OpenReports
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path $PSScriptRoot | Select-Object -ExpandProperty Path
Set-Location $ProjectRoot

Write-Host "=== Investment Assistant Boot ===" -ForegroundColor Cyan
Write-Host ("ProjectRoot: {0}" -f $ProjectRoot) -ForegroundColor DarkGray
Write-Host ""

$required = @(
  ".\data\all_stocks_daily.csv",
  ".\data\all_stocks_decisions.csv",
  ".\data\allocation_log.csv",
  ".\scripts\update_to_latest.ps1",
  ".\scripts\open_latest_reports.ps1"
)

foreach ($r in $required) {
  if (Test-Path $r) { Write-Host ("OK: {0}" -f $r) -ForegroundColor Green }
  else { Write-Host ("Missing: {0}" -f $r) -ForegroundColor Red }
}

Write-Host ""
Write-Host "Quick Commands:" -ForegroundColor Yellow
Write-Host ("1) Full pipeline: .\scripts\update_to_latest.ps1 -Capital {0} -Top {1}" -f $Capital, $Top) -ForegroundColor White
Write-Host "2) Open latest reports: .\scripts\open_latest_reports.ps1" -ForegroundColor White
Write-Host "3) Build universe (Top200): .\scripts\build_universe_from_twse.ps1 -TopN 200" -ForegroundColor White
Write-Host ""
Write-Host "=== Ready ===" -ForegroundColor Cyan

if ($RunUpdate) {
  Write-Host ""
  Write-Host "=== RUN update_to_latest ===" -ForegroundColor Cyan
  & .\scripts\update_to_latest.ps1 -Capital $Capital -Top $Top
}

if ($OpenReports) {
  Write-Host ""
  Write-Host "=== OPEN latest reports ===" -ForegroundColor Cyan
  & .\scripts\open_latest_reports.ps1
}
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ReportsDir = ".\reports",
  [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Anchor to project root ----
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path

function Resolve-ProjectPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $ProjectRoot }
  if ([System.IO.Path]::IsPathRooted($p)) { return $p }

  $rel = $p.Trim()
  if ($rel.StartsWith(".\")) { $rel = $rel.Substring(2) }
  elseif ($rel.StartsWith("./")) { $rel = $rel.Substring(2) }

  return (Join-Path $ProjectRoot $rel)
}

$dir = Resolve-ProjectPath $ReportsDir
if (!(Test-Path $dir)) { throw "ReportsDir not found: $dir" }

function Get-Latest([string]$pattern){
  $files = Get-ChildItem -Path $dir -Filter $pattern -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  if ($files -and $files.Count -gt 0) { return $files[0].FullName }
  return $null
}

$latest = [ordered]@{
  Dashboard         = Get-Latest "tw_dashboard_*.html"
  PerformanceReport = Get-Latest "performance_report_*.html"
  EquityCurve       = Get-Latest "equity_curve_*.html"
  PortfolioCurve    = Get-Latest "portfolio_curve_*.html"
}

Write-Host "=== OPEN LATEST REPORTS ===" -ForegroundColor Cyan
Write-Host ("ProjectRoot: {0}" -f $ProjectRoot) -ForegroundColor DarkGray
Write-Host ("ReportsDir : {0}" -f $dir) -ForegroundColor DarkGray
Write-Host ""

foreach ($k in $latest.Keys) {
  $p = $latest[$k]
  if ([string]::IsNullOrWhiteSpace($p)) {
    Write-Host ("Missing: {0}" -f $k) -ForegroundColor Yellow
  } else {
    Write-Host ("OK: {0} -> {1}" -f $k, $p) -ForegroundColor Green
  }
}

if ($ListOnly) {
  Write-Host ""
  Write-Host "ListOnly=True (no open)." -ForegroundColor Yellow
  exit 0
}

Write-Host ""
Write-Host "Opening..." -ForegroundColor Yellow

$opened = 0
foreach ($k in $latest.Keys) {
  $p = $latest[$k]
  if (![string]::IsNullOrWhiteSpace($p) -and (Test-Path $p)) {
    Start-Process $p | Out-Null
    $opened++
  }
}

Write-Host ("DONE. opened={0}" -f $opened) -ForegroundColor Cyan
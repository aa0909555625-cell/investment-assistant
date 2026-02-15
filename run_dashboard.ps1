#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Date = "",
  [int]$Capital = 300000,
  [int]$Top = 4000,
  [switch]$Open,
  [switch]$RefreshSectors,
  [int]$Timeout = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Info($m){ Write-Host $m -ForegroundColor Cyan }
function Ok($m){ Write-Host $m -ForegroundColor Green }

$root = (Resolve-Path ".").Path
if([string]::IsNullOrWhiteSpace($Date)){ $Date = (Get-Date -Format "yyyy-MM-dd") }

Write-Host "=== RUN DASHBOARD (Phase C) ==="
Write-Host ("Date={0} Capital={1} Top={2} Open={3}" -f $Date, $Capital, $Top, $Open.IsPresent)

$python = Join-Path $root ".venv\Scripts\python.exe"
if(!(Test-Path $python)){ throw "Missing venv python: $python" }

# Optional: refresh sectors mapping into data\all_stocks_daily.csv (Phase C-Next: remove Unknown)
if($RefreshSectors){
  $secScript = Join-Path $root "scripts\refresh_company_sectors.ps1"
  if(!(Test-Path $secScript)){ throw "Missing sector refresh script: $secScript" }
  Info ("RUN: refresh sectors -> {0}" -f $secScript)
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $secScript | Out-Host
}

# Phase C snapshot (writes indices_YYYY-MM-DD.json + market_snapshot_YYYY-MM-DD.json)
$scriptSnap = Join-Path $root "scripts\phaseC_market_snapshot.py"
if(!(Test-Path $scriptSnap)){ throw "Missing script: $scriptSnap" }

$outDir = Join-Path $root "reports"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$dataCsv = Join-Path $root "data\all_stocks_daily.csv"
if(!(Test-Path $dataCsv)){ throw "Missing data_csv: $dataCsv" }

$args = @(
  $scriptSnap,
  "--date", $Date,
  "--top",  [string]$Top,
  "--outdir", $outDir,
  "--data_csv", $dataCsv,
  "--timeout", [string]$Timeout
)

Info ("RUN: {0} {1}" -f $python, ($args -join " "))
& $python @args | Out-Host
if($LASTEXITCODE -ne 0){ throw "phaseC_market_snapshot.py failed." }

# Build HTML
$builder = Join-Path $root "scripts\build_dashboard_html.ps1"
if(!(Test-Path $builder)){ throw "Missing builder: $builder" }

$psArgs = @(
  "-NoProfile",
  "-ExecutionPolicy","Bypass",
  "-File", $builder,
  "-Date", $Date,
  "-Capital", [string]$Capital,
  "-Top", [string]$Top,
  "-OutDir", $outDir
)

if($Open.IsPresent){ $psArgs += "-Open" }

& powershell.exe @psArgs | Out-Host
if($LASTEXITCODE -ne 0){ throw "build_dashboard_html.ps1 failed." }

Ok "DONE."
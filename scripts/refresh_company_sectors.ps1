#Requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$UpdateAllStocks,
  [string]$OutCsv = ".\data\company_sectors.csv",
  [string]$AllStocksCsv = ".\data\all_stocks_daily.csv",
  [int]$Timeout = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-DirOfFile([string]$filePath){
  $dir = Split-Path -Parent $filePath
  if([string]::IsNullOrWhiteSpace($dir)){ return }
  if(!(Test-Path $dir)){
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
}

Write-Host "=== refresh_company_sectors.ps1 (wrapper) ===" -ForegroundColor Cyan

$root = (Resolve-Path ".").Path
$pyExe = Join-Path $root ".venv\Scripts\python.exe"
$pyScript = Join-Path $root "scripts\refresh_company_sectors.py"
$outAbs = Join-Path $root $OutCsv
$allAbs = Join-Path $root $AllStocksCsv

if(!(Test-Path $pyExe)){ throw "Missing venv python: $pyExe" }
if(!(Test-Path $pyScript)){ throw "Missing script: $pyScript" }

Ensure-DirOfFile $outAbs

Write-Host ("RUN: {0} {1} --out {2} --timeout {3}" -f $pyExe, $pyScript, $outAbs, $Timeout) -ForegroundColor DarkGray
& $pyExe $pyScript --out $outAbs --timeout $Timeout
if($LASTEXITCODE -ne 0){ throw "refresh_company_sectors.py failed." }

if(!(Test-Path $outAbs)){ throw "Expected output missing: $outAbs" }
$rows = Import-Csv $outAbs -Encoding UTF8
Write-Host ("OK: sector map loaded rows={0}" -f $rows.Count) -ForegroundColor Green
if($rows.Count -lt 500){ throw "Sector map rows too small (<500). Stop to avoid poisoning sectors." }

# build map
$map = @{}
foreach($r in $rows){
  $c = ([string]$r.code).Trim()
  if($c -match '^\d{4,6}$'){
    $sec = ([string]$r.sector).Trim()
    if([string]::IsNullOrWhiteSpace($sec)){ $sec = "Unknown" }
    $map[$c] = $sec
  }
}

if($UpdateAllStocks){
  if(!(Test-Path $allAbs)){ throw "Missing all_stocks_daily.csv: $allAbs" }

  $tmp = [System.IO.Path]::GetTempFileName()
  $data = Import-Csv $allAbs -Encoding UTF8
  $changed = 0

  foreach($r in $data){
    $code = ([string]$r.code).Trim()
    if([string]::IsNullOrWhiteSpace($code)){ continue }

    if($r.PSObject.Properties.Match('sector').Count -eq 0){
      $r | Add-Member -NotePropertyName sector -NotePropertyValue "" -Force
    }

    $cur = ([string]$r.sector).Trim()
    $need = $false
    if([string]::IsNullOrWhiteSpace($cur)){ $need = $true }
    elseif($cur -match '^(?i)unknown$'){ $need = $true }

    if($need -and $map.ContainsKey($code)){
      $newSec = $map[$code]
      if([string]::IsNullOrWhiteSpace($newSec)){ $newSec = "Unknown" }
      if($cur -ne $newSec){
        $r.sector = $newSec
        $changed++
      }
    }
  }

  $data | Export-Csv -Path $tmp -NoTypeInformation -Encoding UTF8
  Copy-Item $tmp $allAbs -Force
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue

  $unknownCount = ($data | Where-Object { ($_.sector -eq "") -or ($_.sector -match '^(?i)unknown$') } | Measure-Object).Count

  Write-Host ("OK: updated all_stocks_daily.csv changed={0}" -f $changed) -ForegroundColor Green
  Write-Host ("INFO: Unknown/blank sector count now = {0}" -f $unknownCount) -ForegroundColor Yellow
}

exit 0
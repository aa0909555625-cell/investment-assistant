#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InCsv = ".\data\all_stocks_daily.csv",
  [string]$MapCsv = ".\data\sector_map.csv",
  [string]$OutCsv = ".\data\all_stocks_daily.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if(!(Test-Path $InCsv)){ throw "Missing: $InCsv" }
if(!(Test-Path $MapCsv)){ throw "Missing: $MapCsv" }

$map = @{}
Import-Csv $MapCsv | ForEach-Object {
  $c = ($_.code.ToString()).Trim()
  $s = ($_.sector.ToString()).Trim()
  if($c -and $s){ $map[$c] = $s }
}

$rows = Import-Csv $InCsv
foreach($r in $rows){
  $code = ($r.code.ToString()).Trim()
  if($map.ContainsKey($code)){
    $r.sector = $map[$code]
  } elseif([string]::IsNullOrWhiteSpace($r.sector) -or $r.sector -eq "unknown"){
    # keep as-is (unknown) for now
  }
}

$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host ("OK: applied sector_map -> {0} (rows={1})" -f $OutCsv, $rows.Count) -ForegroundColor Green
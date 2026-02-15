param(
  [Parameter(Mandatory=$false)]
  [int]$KeepDays = 30,

  [Parameter(Mandatory=$false)]
  [switch]$WhatIfOnly
)

$ErrorActionPreference = "Stop"

function Prune([string]$path, [string]$pattern, [int]$days) {
  if (!(Test-Path $path)) { return }
  $cut = (Get-Date).AddDays(-1 * $days)
  $files = Get-ChildItem $path -Filter $pattern -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cut }

  foreach($f in $files) {
    if ($WhatIfOnly) {
      Write-Host ("WHATIF: delete {0}" -f $f.FullName) -ForegroundColor Yellow
    } else {
      Remove-Item $f.FullName -Force
      Write-Host ("OK: deleted {0}" -f $f.FullName) -ForegroundColor DarkGray
    }
  }
}

Prune ".\reports" "*.txt" $KeepDays
Prune ".\reports" "*.json" $KeepDays
Prune ".\archive" "*" $KeepDays

Write-Host "DONE: retention cleanup" -ForegroundColor Green

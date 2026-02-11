[CmdletBinding()]
param(
  [string]$Tag = "E"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$rep = ".\reports\weekly"
$log = ".\logs\weekly"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$out = Join-Path $rep ("acceptance_{0}_{1}" -f $Tag, $stamp)

New-Item -ItemType Directory -Force -Path $out | Out-Null

function Get-Latest([string]$dir, [string]$filter) {
  if (-not (Test-Path $dir)) { return $null }
  return Get-ChildItem $dir -Filter $filter -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 1
}

$latestSummary = Get-Latest $rep "weekly_summary_*.txt"
$latestLog     = Get-Latest $log "weekly_task_*.log"

if ($latestSummary) { Copy-Item -Force $latestSummary.FullName $out }
if ($latestLog)     { Copy-Item -Force $latestLog.FullName     $out }

$ls = Join-Path $rep "last_success.json"
if (Test-Path $ls) { Copy-Item -Force $ls $out }

# include latest archived failure snapshot if exists (for audit)
$arch = Get-Latest (Join-Path $rep "archive") "last_failure_*.json"
if ($arch) { Copy-Item -Force $arch.FullName $out }

Write-Host ("OK -> acceptance bundle: {0}" -f $out)
Get-ChildItem $out | Select-Object Name,Length,LastWriteTime
exit 0
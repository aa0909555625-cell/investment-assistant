[CmdletBinding()]
param(
  [int]$LogDays = 30,
  [int]$ArchiveDays = 7,
  [switch]$VerboseMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
  param(
    [string]$Message,
    [ValidateSet("INFO","WARN","ERROR","OK")]
    [string]$Level = "INFO"
  )
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$ts][$Level] $Message"
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$logRoot = Join-Path $repo "logs"
$reportsRoot = Join-Path $repo "reports"

$now = Get-Date
$logCutoff = $now.AddDays(-$LogDays)
$archiveCutoff = $now.AddDays(-$ArchiveDays)

Write-Status "Retention cleanup started"
Write-Status "Repo: $repo"
Write-Status "LogDays=$LogDays (cutoff=$($logCutoff.ToString('yyyy-MM-dd HH:mm:ss')))"
Write-Status "ArchiveDays=$ArchiveDays (cutoff=$($archiveCutoff.ToString('yyyy-MM-dd HH:mm:ss')))"

# 1) Logs cleanup
if (Test-Path $logRoot) {
  $logs = Get-ChildItem $logRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $logCutoff }

  $count = 0
  foreach ($f in $logs) {
    if ($VerboseMode) { Write-Status "Delete log: $($f.FullName)" "INFO" }
    Remove-Item -Force $f.FullName -ErrorAction SilentlyContinue
    $count++
  }
  Write-Status "Deleted old logs: $count" "OK"
} else {
  Write-Status "Logs folder not found: $logRoot" "WARN"
}

# 2) Reports archive cleanup (generated runtime artifacts)
if (Test-Path $reportsRoot) {
  $archives = Get-ChildItem $reportsRoot -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\archive$" -or $_.Name -eq "archive" }

  $deleted = 0
  foreach ($dir in $archives) {
    $files = Get-ChildItem $dir.FullName -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $archiveCutoff }

    foreach ($f in $files) {
      if ($VerboseMode) { Write-Status "Delete archive file: $($f.FullName)" "INFO" }
      Remove-Item -Force $f.FullName -ErrorAction SilentlyContinue
      $deleted++
    }
  }
  Write-Status "Deleted old archive files: $deleted" "OK"
} else {
  Write-Status "Reports folder not found: $reportsRoot" "WARN"
}

Write-Status "Retention cleanup finished" "OK"
exit 0
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo   = Split-Path -Parent $PSScriptRoot
$repDir = Join-Path $repo "reports\weekly"
$arcDir = Join-Path $repDir "archive"
$lf     = Join-Path $repDir "last_failure.json"

New-Item -ItemType Directory -Force -Path $repDir,$arcDir | Out-Null

if (-not (Test-Path $lf)) { exit 0 }

# Read snapshot
$raw = Get-Content -LiteralPath $lf -Raw -ErrorAction Stop
$js  = $null
try { $js = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $js = $null }

# Archive first (always)
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$arc = Join-Path $arcDir ("last_failure_{0}.json" -f $stamp)
Copy-Item -LiteralPath $lf -Destination $arc -Force
Remove-Item -LiteralPath $lf -Force -ErrorAction SilentlyContinue

# Build message
$exitCode = ""
$summary  = ""
$logPath  = ""
$tailText = ""

if ($js) {
  $exitCode = [string]$js.exitCode
  $summary  = [string]$js.summaryPath
  $logPath  = [string]$js.logPath
  if ($js.logTail) {
    $tailText = ($js.logTail | ForEach-Object { [string]$_ }) -join "`r`n"
  }
} else {
  $exitCode = "(unknown)"
}

$msg = "Weekly FAILED (ExitCode=$exitCode)`r`n"
if ($summary) { $msg += "Summary:`r`n$summary`r`n" }
if ($logPath) { $msg += "Log:`r`n$logPath`r`n" }
if ($tailText) { $msg += "`r`nLog tail:`r`n$tailText" }

# Show popup (interactive only)
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "scripts\notify.ps1") `
  -Title "Investment Assistant - Weekly FAILED" `
  -Message $msg `
  -TimeoutSec 0 | Out-Null

exit 0
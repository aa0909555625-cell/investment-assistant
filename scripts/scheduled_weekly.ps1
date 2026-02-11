Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 weekly
$code = [int]$LASTEXITCODE

# ExitCode=2 is WARN (do NOT notify)
if ($code -ne 0 -and $code -ne 2) {
  $logDir = Join-Path $repo "logs\weekly"
  $latestLog = Get-ChildItem $logDir -Filter "weekly_task_*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 1

  $msg = "ExitCode=$code"
  if ($latestLog) { $msg += " | Log=" + $latestLog.FullName }

  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\notify.ps1 -Title "Investment Assistant" -Message $msg
}

exit $code
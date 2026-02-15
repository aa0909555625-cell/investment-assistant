[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [ValidateSet("weekly","status","health","help")]
  [string]$Command = "help",

  [Parameter(Position=1)]
  [string]$Arg1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "[INFO] $m" }
function Done($m){ Write-Host "[DONE] $m" }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[FAIL] $m" -ForegroundColor Red }

$repo = Split-Path -Parent $PSCommandPath
Set-Location $repo

$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Get-LatestFile([string]$dir, [string]$filter){
  if (-not (Test-Path -LiteralPath $dir)) { return $null }
  return Get-ChildItem -LiteralPath $dir -Filter $filter -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 1
}

function Show-Status {
  $rep = Join-Path $repo "reports\weekly"
  $log = Join-Path $repo "logs\weekly"

  $latestSummary = Get-LatestFile $rep "weekly_summary_*.txt"
  $latestLog     = Get-LatestFile $log "weekly_task_*.log"
  $ls            = Join-Path $rep "last_success.json"

  Info ("RootDir:       {0}" -f $repo)

  if ($latestSummary) {
    Info ("LatestSummary: {0}" -f $latestSummary.FullName)
    Info ("SummaryTime :  {0}" -f $latestSummary.LastWriteTime)
    # tail 3 for quick read
    $tail = Get-Content -LiteralPath $latestSummary.FullName -Tail 3 -ErrorAction SilentlyContinue
    if ($tail) {
      Info "SummaryTail(3):"
      $tail | ForEach-Object { "  " + $_ } | Write-Host
    }
  } else {
    Warn "LatestSummary: <none>"
  }

  if (Test-Path -LiteralPath $ls) {
    Info ("last_success.json: {0}" -f $ls)
  } else {
    Warn "last_success.json: <missing>"
  }

  if ($latestLog) {
    Info ("LatestLog    : {0}" -f $latestLog.FullName)
    Info ("LogTime      : {0}" -f $latestLog.LastWriteTime)
    $tail = Get-Content -LiteralPath $latestLog.FullName -Tail 3 -ErrorAction SilentlyContinue
    if ($tail) {
      Info "LogTail(3):"
      $tail | ForEach-Object { "  " + $_ } | Write-Host
    }
  } else {
    Warn "LatestLog: <none>"
  }
}

function Run-Weekly {
  $script = Join-Path $repo "scripts\run_weekly_task.ps1"
  if (-not (Test-Path -LiteralPath $script)) { throw "Not found: $script" }

  Info ("Engine: {0}" -f $psExe)
  Info ("Run:    {0}" -f $script)

  & $psExe -NoProfile -ExecutionPolicy Bypass -File $script
  $code = [int]$LASTEXITCODE

  if ($code -eq 0) {
    Info "weekly: OK"
  } elseif ($code -eq 2) {
    Warn "weekly: WARN (ExitCode=2)"
  } else {
    Fail "weekly: FAIL (ExitCode=$code)"
  }

  # show where outputs are
  $rep = Join-Path $repo "reports\weekly"
  $log = Join-Path $repo "logs\weekly"
  $latestSummary = Get-LatestFile $rep "weekly_summary_*.txt"
  $latestLog     = Get-LatestFile $log "weekly_task_*.log"

  Done ("weekly ExitCode={0} | Summary={1} | Log={2}" -f `
    $code, `
    $(if($latestSummary){$latestSummary.FullName}else{"<none>"}), `
    $(if($latestLog){$latestLog.FullName}else{"<none>"}) )

  exit $code
}

function Run-Health {
  $script = Join-Path $repo "scripts\health_check.ps1"
  if (-not (Test-Path -LiteralPath $script)) { throw "Not found: $script" }

  # allow override minutes via Arg1
  $mins = 15
  if ($Arg1 -and ($Arg1 -as [int]) -ne $null) { $mins = [int]$Arg1 }

  & $psExe -NoProfile -ExecutionPolicy Bypass -File $script -MaxAgeMinutes $mins
  exit [int]$LASTEXITCODE
}

switch ($Command) {
  "weekly" { Run-Weekly }
  "status" { Show-Status; exit 0 }
  "health" { Run-Health }
  default {
    @"
Usage:
  .\run.ps1 weekly
  .\run.ps1 status
  .\run.ps1 health [MaxAgeMinutes]

Examples:
  .\run.ps1 health
  .\run.ps1 health 30
"@ | Write-Host
    exit 0
  }
}
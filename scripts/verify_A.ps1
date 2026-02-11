Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "=== A VERIFY START ==="

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# 0) Verify task principal (SYSTEM / Highest)
$tn = "InvestmentAssistant-Weekly"
$task = Get-ScheduledTask -TaskName $tn -ErrorAction Stop
$pri  = $task.Principal
Write-Host ("TaskPrincipal: UserId={0} LogonType={1} RunLevel={2}" -f $pri.UserId,$pri.LogonType,$pri.RunLevel)

if ($pri.UserId -ne "SYSTEM") { throw "A FAIL: Task is not running as SYSTEM." }
if ($pri.RunLevel -ne "Highest") { throw "A FAIL: Task is not Highest." }

# 1) Cleanup old last_failure.json (if any)
$repDir = Join-Path $repo "reports\weekly"
$arcDir = Join-Path $repDir "archive"
New-Item -ItemType Directory -Force -Path $repDir,$arcDir | Out-Null

$lf = Join-Path $repDir "last_failure.json"
if (Test-Path $lf) { Remove-Item -Force $lf }

# 2) Prepare paths safely (PS 5.1 compatible)
$summaryFile = Join-Path $repDir "weekly_summary_2026-07.txt"
$summaryPath = ""
if (Test-Path $summaryFile) {
    $summaryPath = (Resolve-Path $summaryFile).Path
}

$logDir = Join-Path $repo "logs\weekly"
$logPath = ""
$latestLog = Get-ChildItem $logDir -Filter "weekly_task_*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 1
if ($latestLog) {
    $logPath = $latestLog.FullName
}

# 3) Write simulated failure snapshot
$payload = [ordered]@{
    generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    exitCode    = 9
    repo        = $repo
    summaryPath = $summaryPath
    logPath     = $logPath
    logTail     = @(
        "SIMULATED FAILURE",
        "tail line 1",
        "tail line 2"
    )
} | ConvertTo-Json -Depth 8

Set-Content -LiteralPath $lf -Value $payload -Encoding utf8 -NoNewline
Write-Host "OK -> wrote reports\weekly\last_failure.json"

if (-not (Test-Path $lf)) {
    throw "A FAIL: last_failure.json not created."
}

# 4) Run notifier (simulate next logon)
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "scripts\notify_on_logon.ps1") | Out-Null
Write-Host "OK -> ran notify_on_logon.ps1"

# 5) Assertions after notifier
$existsAfter = Test-Path $lf
Write-Host ("last_failure.json exists after notifier? {0}" -f $existsAfter)

$latestArc = Get-ChildItem $arcDir -Filter "last_failure_*.json" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 1

if ($existsAfter) {
    throw "A FAIL: last_failure.json still exists (should be archived & removed)."
}
if (-not $latestArc) {
    throw "A FAIL: archive snapshot not created."
}

Write-Host ("archive latest: {0}" -f $latestArc.FullName)
Write-Host "=== A VERIFY PASS ==="
exit 0
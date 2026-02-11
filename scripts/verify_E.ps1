Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "=== E VERIFY START ==="

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Invoke-RunWeekly {
  $engine = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
  $run = Join-Path $repo "run.ps1"
  $p = Start-Process -FilePath $engine -ArgumentList @(
    "-NoProfile","-ExecutionPolicy","Bypass","-File",$run,"weekly"
  ) -WorkingDirectory $repo -NoNewWindow -PassThru -Wait
  return [int]$p.ExitCode
}

$successPath = ".\reports\weekly\last_success.json"
$failurePath = ".\reports\weekly\last_failure.json"

# 1) Normal weekly -> must refresh last_success.json
$before = $null
if (Test-Path $successPath) { $before = (Get-Item $successPath).LastWriteTime }

$code = Invoke-RunWeekly
Write-Host ("weekly ExitCode={0}" -f $code)

if (-not (Test-Path $successPath)) { throw "last_success.json not found after weekly" }
$after = (Get-Item $successPath).LastWriteTime
if ($before -and $after -le $before) { throw "last_success.json was not refreshed (LastWriteTime did not increase)" }

$succ = Get-Content $successPath -Raw | ConvertFrom-Json
Write-Host ("last_success.json -> exitCode={0} generatedAt={1}" -f $succ.exitCode, $succ.generatedAt)

# 2) Force failure -> must create last_failure.json
$env:IA_FORCE_FAIL = "1"
try {
  $fcode = Invoke-RunWeekly
  Write-Host ("forced weekly ExitCode={0}" -f $fcode)
} finally {
  Remove-Item Env:\IA_FORCE_FAIL -ErrorAction SilentlyContinue
}

if (-not (Test-Path $failurePath)) { throw "last_failure.json not found after forced failure" }
$fail = Get-Content $failurePath -Raw | ConvertFrom-Json
$tailCount = 0
try { $tailCount = ($fail.logTail | Measure-Object).Count } catch { $tailCount = 0 }
Write-Host ("last_failure.json -> exitCode={0} logTailCount={1}" -f $fail.exitCode, $tailCount)

# 3) notify_on_logon should archive and remove last_failure.json
$engine = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$notify = Join-Path $repo "scripts\notify_on_logon.ps1"
$p = Start-Process -FilePath $engine -ArgumentList @(
  "-NoProfile","-ExecutionPolicy","Bypass","-File",$notify
) -WorkingDirectory $repo -NoNewWindow -PassThru -Wait
Write-Host ("notify_on_logon ExitCode={0}" -f $p.ExitCode)

if (Test-Path $failurePath) { throw "last_failure.json still exists after notify_on_logon" }

$arch = Get-ChildItem .\reports\weekly\archive -Filter "last_failure_*.json" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Desc | Select-Object -First 1
if (-not $arch) { throw "No archived last_failure_*.json found" }

Write-Host ("archive latest: {0}" -f $arch.FullName)
Write-Host "=== E VERIFY PASS ==="
exit 0
[CmdletBinding()]
param(
  [int]$MaxAgeMinutes = 1440,
  [switch]$VerboseMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$logsDir = Join-Path $repo "logs\health"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $logsDir ("health_check_{0}.log" -f $ts)

$healthScript = Join-Path $PSScriptRoot "health_check.ps1"

"=== run_health_check.ps1 ===" | Out-File -FilePath $logPath -Encoding UTF8
("Time        : {0}" -f (Get-Date)) | Out-File -FilePath $logPath -Encoding UTF8 -Append
("Repo        : {0}" -f $repo) | Out-File -FilePath $logPath -Encoding UTF8 -Append
("Script      : {0}" -f $healthScript) | Out-File -FilePath $logPath -Encoding UTF8 -Append
("MaxAgeMinutes: {0}" -f $MaxAgeMinutes) | Out-File -FilePath $logPath -Encoding UTF8 -Append
("VerboseMode : {0}" -f $VerboseMode.IsPresent) | Out-File -FilePath $logPath -Encoding UTF8 -Append
"" | Out-File -FilePath $logPath -Encoding UTF8 -Append

try {
  # 同時輸出到 console + log
  if ($VerboseMode) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $healthScript -MaxAgeMinutes $MaxAgeMinutes -VerboseMode 2>&1 |
      Tee-Object -FilePath $logPath -Append
  } else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $healthScript -MaxAgeMinutes $MaxAgeMinutes 2>&1 |
      Tee-Object -FilePath $logPath -Append
  }

  $code = [int]$LASTEXITCODE
  "" | Out-File -FilePath $logPath -Encoding UTF8 -Append
  ("ExitCode   : {0}" -f $code) | Out-File -FilePath $logPath -Encoding UTF8 -Append

  exit $code
}
catch {
  "" | Out-File -FilePath $logPath -Encoding UTF8 -Append
  ("[WRAPPER_ERROR] {0}" -f $_.Exception.Message) | Out-File -FilePath $logPath -Encoding UTF8 -Append
  if ($_.ScriptStackTrace) { ("Stack: {0}" -f $_.ScriptStackTrace) | Out-File -FilePath $logPath -Encoding UTF8 -Append }
  exit 1
}
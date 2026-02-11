[CmdletBinding()]
param(
  [int]$MaxAgeMinutes = 1440,
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

# =========================
# 固定路徑初始化
# =========================
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$healthScript = Join-Path $PSScriptRoot "health_check.ps1"

$logsDir = Join-Path $repo "logs\health"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $logsDir ("health_check_{0}.log" -f $ts)

# =========================
# Header
# =========================
"=== run_health_check.ps1 ===" | Out-File $logPath -Encoding UTF8
("Time         : {0}" -f (Get-Date)) | Out-File $logPath -Append
("Repo         : {0}" -f $repo) | Out-File $logPath -Append
("Script       : {0}" -f $healthScript) | Out-File $logPath -Append
("MaxAgeMinutes: {0}" -f $MaxAgeMinutes) | Out-File $logPath -Append
("VerboseMode  : {0}" -f $VerboseMode.IsPresent) | Out-File $logPath -Append
"" | Out-File $logPath -Append

# =========================
# Run health check
# =========================
try {
  if ($VerboseMode) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
      -File $healthScript `
      -ProjectRoot $repo `
      -MaxAgeMinutes $MaxAgeMinutes `
      -VerboseMode 2>&1 |
      Tee-Object -FilePath $logPath -Append
  }
  else {
    & powershell -NoProfile -ExecutionPolicy Bypass `
      -File $healthScript `
      -ProjectRoot $repo `
      -MaxAgeMinutes $MaxAgeMinutes 2>&1 |
      Tee-Object -FilePath $logPath -Append
  }

  $code = [int]$LASTEXITCODE
}
catch {
  $msg = $_.Exception.Message
  Write-Status $msg "ERROR"
  ("[ERROR] {0}" -f $msg) | Out-File $logPath -Append

  # Event Log (failure)
  try {
    if (-not [System.Diagnostics.EventLog]::SourceExists("InvestmentAssistant")) {
      New-EventLog -LogName Application -Source "InvestmentAssistant" -ErrorAction SilentlyContinue
    }
    Write-EventLog -LogName Application -Source "InvestmentAssistant" -EventId 5001 -EntryType Error `
      -Message ("HealthCheck exception. Repo={0} Log={1} Error={2}" -f $repo, $logPath, $msg)
  } catch { }

  exit 1
}

"" | Out-File $logPath -Append
("ExitCode    : {0}" -f $code) | Out-File $logPath -Append

if ($code -eq 0) {
  Write-Status "Health check PASSED" "OK"
} else {
  Write-Status "Health check FAILED (code=$code)" "ERROR"

  # Event Log (failure)
  try {
    if (-not [System.Diagnostics.EventLog]::SourceExists("InvestmentAssistant")) {
      New-EventLog -LogName Application -Source "InvestmentAssistant" -ErrorAction SilentlyContinue
    }
    Write-EventLog -LogName Application -Source "InvestmentAssistant" -EventId 5002 -EntryType Error `
      -Message ("HealthCheck FAILED. Repo={0} ExitCode={1} Log={2}" -f $repo, $code, $logPath)
  } catch { }
}

exit $code
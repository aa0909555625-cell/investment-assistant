Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
  [string]$Title   = "Investment Assistant",
  [string]$Message = "Weekly task failed. Please check logs.",
  [int]$TimeoutSec = 0
)

function Show-Popup {
  param([string]$T,[string]$M,[int]$Sec)

  try {
    # 64 = Info icon, 16 = Error icon (we'll use Info here)
    $ws = New-Object -ComObject WScript.Shell
    [void]$ws.Popup($M, $Sec, $T, 64)
    return $true
  } catch {
    return $false
  }
}

# Ensure non-empty message (avoid msg.exe-like "invalid parameter" issues)
if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "(no message)" }

$ok = Show-Popup -T $Title -M $Message -Sec $TimeoutSec
if (-not $ok) {
  # Fallback: write to host only
  Write-Host ("[{0}] {1}" -f $Title, $Message)
}

exit 0
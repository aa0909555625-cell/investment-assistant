param(
  [Parameter(Mandatory=$false)]
  [string]$Title = "Investment Assistant",

  [Parameter(Mandatory=$false)]
  [string]$Message = "Task completed.",

  [Parameter(Mandatory=$false)]
  [ValidateSet("Info","Warn","Error")]
  [string]$Level = "Info"
)

$ErrorActionPreference = "Stop"

function Try-Toast([string]$t, [string]$m) {
  try {
    if (Get-Module -ListAvailable -Name BurntToast) {
      Import-Module BurntToast -ErrorAction Stop | Out-Null
      New-BurntToastNotification -Text $t, $m | Out-Null
      return $true
    }
  } catch { }
  return $false
}

$tag = "[{0}]" -f $Level.ToUpper()
$line = "{0} {1} {2}" -f $tag, $Title, $Message

if (-not (Try-Toast $Title $line)) {
  if ($Level -eq "Error") { Write-Host $line -ForegroundColor Red }
  elseif ($Level -eq "Warn") { Write-Host $line -ForegroundColor Yellow }
  else { Write-Host $line -ForegroundColor Cyan }
}

param(
  [Parameter(Mandatory=$true)]
  [string]$Date
)

$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$p) {
  if (!(Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

# Validate date format
if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') {
  throw "Date must be YYYY-MM-DD. Got: $Date"
}

# Minimal raw store (so rehab can be extended to consume)
$rawDir = ".\data\raw"
Ensure-Dir $rawDir

$markerName = "tw_fetch_marker_{0}.json" -f $Date.Replace("-","")
$markerPath = Join-Path $rawDir $markerName

$payload = @{
  date       = $Date
  fetched_at = (Get-Date).ToString("s")
  source     = "placeholder"
  note       = "Replace this placeholder with real TWSE/TPEx fetch implementation."
} | ConvertTo-Json -Depth 5

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# IMPORTANT: don't use Resolve-Path on a file that doesn't exist yet
[System.IO.File]::WriteAllText($markerPath, $payload.Replace("`r`n","`n").Replace("`n","`r`n"), $utf8NoBom)

Write-Host ("OK: wrote raw marker -> {0}" -f $markerPath) -ForegroundColor Green
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

function Normalize-File([string]$path) {
  # DO NOT touch this script while it is running
  if ((Resolve-Path $path).Path -eq (Resolve-Path $PSCommandPath).Path) { return }

  $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $path))
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

  $text = if ($hasBom) {
    [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length-3)
  } else {
    [System.Text.Encoding]::UTF8.GetString($bytes)
  }

  $text = $text -replace "`r?`n", "`r`n"
  $text = $text -replace "`0", ""

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Resolve-Path $path), $text, $utf8NoBom)
}

function Syntax-Check([string]$path) {
  $raw = Get-Content $path -Raw -Encoding UTF8
  [void][scriptblock]::Create($raw)
}

Write-Host ("=== HEALTH CHECK ({0}) ===" -f (Get-Date -Format "yyyyMMdd_HHmmss")) -ForegroundColor Cyan
Write-Host ("Root: {0}" -f (Get-Location).Path) -ForegroundColor DarkGray

# folders
foreach($d in @(".\data",".\reports",".\logs",".\archive",".\scripts")) {
  if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# scan scripts (skip *.bak*)
$ps1 = @()
if (Test-Path ".\run.ps1") { $ps1 += ".\run.ps1" }
$ps1 += Get-ChildItem ".\scripts" -Filter "*.ps1" -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -notmatch "\.bak_" } |
  Select-Object -ExpandProperty FullName

$bad = New-Object System.Collections.Generic.List[string]
$ok = 0

foreach($f in $ps1) {
  try {
    Normalize-File $f
    Syntax-Check $f
    $ok++
  } catch {
    $bad.Add("$f :: $($_.Exception.Message)")
  }
}

Write-Host ("OK: ps1 checked = {0}" -f $ok) -ForegroundColor Green
if ($bad.Count -gt 0) {
  Write-Host "ERROR: syntax issues found:" -ForegroundColor Red
  $bad | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
  throw "health_check failed due to syntax errors."
}

Write-Host "OK: health_check PASS" -ForegroundColor Green

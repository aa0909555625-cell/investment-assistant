$ErrorActionPreference="Stop"

function SyntaxCheck([string]$path){
  $raw = Get-Content $path -Raw -Encoding UTF8
  [void][scriptblock]::Create($raw)
}

Write-Host "=== LINT PS1 ===" -ForegroundColor Cyan

$files = @()
if(Test-Path ".\run.ps1"){ $files += ".\run.ps1" }
$files += Get-ChildItem ".\scripts" -Filter "*.ps1" -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch "\\archive\\" -and $_.Name -notmatch "\.bak_" } |
  Select-Object -ExpandProperty FullName

$bad = New-Object System.Collections.Generic.List[string]
$ok = 0
foreach($f in $files){
  try { SyntaxCheck $f; $ok++ } catch { $bad.Add("$f :: $($_.Exception.Message)") }
}

Write-Host ("OK: checked={0}" -f $ok) -ForegroundColor Green
if($bad.Count -gt 0){
  Write-Host "ERROR: issues:" -ForegroundColor Red
  $bad | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
  throw "lint failed"
}
Write-Host "OK: lint PASS" -ForegroundColor Green

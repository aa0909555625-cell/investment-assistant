param(
  [Parameter(Mandatory=$false)]
  [switch]$FixPolicy
)
$ErrorActionPreference="Stop"

Write-Host "=== ENV CHECK ===" -ForegroundColor Cyan
Write-Host ("PSVersion: {0}" -f $PSVersionTable.PSVersion) -ForegroundColor DarkGray
Write-Host ("ExecutionPolicy(CurrentUser): {0}" -f (Get-ExecutionPolicy -Scope CurrentUser)) -ForegroundColor DarkGray

if($FixPolicy){
  $p = Get-ExecutionPolicy -Scope CurrentUser
  if($p -eq "Restricted" -or $p -eq "AllSigned"){
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
    Write-Host "OK: set ExecutionPolicy(CurrentUser)=RemoteSigned" -ForegroundColor Green
  } else {
    Write-Host "OK: policy unchanged" -ForegroundColor DarkGray
  }
}

# UTF-8 console hint
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
Write-Host "OK: console UTF-8 set (best effort)" -ForegroundColor Green

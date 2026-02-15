#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)][string]$Content,
  [switch]$NormalizeCrlf,
  [switch]$EnsureDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if($EnsureDir){
  $dir = Split-Path -Parent $Path
  if($dir -and !(Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$c = $Content
if($NormalizeCrlf){
  $c = $c.Replace("`r`n","`n").Replace("`n","`r`n")
}

[System.IO.File]::WriteAllText($Path, $c, $utf8NoBom)
exit 0
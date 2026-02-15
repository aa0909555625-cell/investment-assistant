#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Ps1Utf8Bom {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Content
  )
  $utf8Bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8Bom)

  # hard-parse check
  [void][scriptblock]::Create((Get-Content $Path -Raw -Encoding UTF8))
}

function Read-TextUtf8 {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path
  )
  return (Get-Content $Path -Raw -Encoding UTF8)
}
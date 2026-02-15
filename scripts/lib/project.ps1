Set-StrictMode -Version Latest

function Resolve-IAProjectRoot {
    [CmdletBinding()]
    param(
        [Parameter()][string]$HintPath
    )

    # Use hint if provided
    if ($HintPath -and (Test-Path $HintPath)) {
        $p = Resolve-Path $HintPath
        if (Test-Path (Join-Path $p.Path ".git")) { return $p.Path }
        if (Test-Path (Join-Path $p.Path "scripts")) { return $p.Path }
    }

    # Walk up from current script location
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $cur  = Resolve-Path $here

    while ($true) {
        $p = $cur.Path

        if (Test-Path (Join-Path $p ".git")) { return $p }
        if (Test-Path (Join-Path $p "scripts")) { return $p }

        $parent = Split-Path -Parent $p
        if ($parent -eq $p -or -not $parent) { break }
        $cur = Resolve-Path $parent
    }

    throw "Cannot resolve project root. HintPath=$HintPath"
}

function Get-IANotificationConfig {
    [CmdletBinding()]
    param()

    $cfgPath = "C:\ProgramData\InvestmentAssistant\config\notifications.json"
    if (-not (Test-Path $cfgPath)) {
        throw "Notification config not found: $cfgPath"
    }

    return (Get-Content $cfgPath -Raw | ConvertFrom-Json)
}

function Get-IAGmailAppPassword {
    [CmdletBinding()]
    param()

    $passPath = "C:\ProgramData\InvestmentAssistant\secrets\gmail_app_password.txt"
    if (-not (Test-Path $passPath)) {
        throw "Gmail app password not found: $passPath"
    }

    return (Get-Content $passPath -Raw).Trim()
}
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,

    [Parameter()]
    [int]$MaxAgeMinutes = 1440,

    [Parameter()]
    [string[]]$RequiredPatterns = @(
        "phase5_signals_*.csv",
        "phase6_trades_*.csv",
        "phase6_equity_*.csv",
        "prices_*.csv"
    ),

    [Parameter()]
    [int]$MinMatch = 1,

    [Parameter()]
    [switch]$AnyRecent,

    [Parameter()]
    [switch]$VerboseMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][ValidateSet("INFO","WARN","ERROR","OK")][string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp][$Level] $Message"
}

function Format-Dt([datetime]$dt) {
    return $dt.ToString("yyyy-MM-dd HH:mm:ss")
}

function Get-RecentFilesByPattern {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][datetime]$Threshold
    )

    if (-not (Test-Path -LiteralPath $Dir)) { return @() }

    $items = Get-ChildItem -LiteralPath $Dir -Filter $Pattern -File -ErrorAction SilentlyContinue
    if (-not $items) { return @() }

    return @($items | Where-Object { $_.LastWriteTime -ge $Threshold })
}

try {
    $dataPath = Join-Path $ProjectRoot "data"
    $threshold = (Get-Date).AddMinutes(-$MaxAgeMinutes)

    Write-Status "Health check started"
    Write-Status ("Project root: {0}" -f [string]$ProjectRoot)
    Write-Status ("Data path: {0}" -f [string]$dataPath)
    Write-Status ("MaxAgeMinutes: {0} (threshold: {1})" -f [string]$MaxAgeMinutes, (Format-Dt $threshold))

    if (-not (Test-Path -LiteralPath $dataPath)) {
        Write-Status ("Data directory not found: {0}" -f [string]$dataPath) "ERROR"
        exit 1
    }

    if ($AnyRecent) {
        Write-Status "Mode: AnyRecent"

        $recentAny = @(
            Get-ChildItem -LiteralPath $dataPath -Recurse -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -ge $threshold }
        )

        if ($recentAny.Count -eq 0) {
            Write-Status ("No recent data files found within {0} minutes" -f [string]$MaxAgeMinutes) "WARN"
            exit 2
        }

        Write-Status ("Found {0} recent file(s)" -f [string]$recentAny.Count)

        if ($VerboseMode) {
            $recentAny | Sort-Object LastWriteTime -Desc | Select-Object -First 50 | ForEach-Object {
                Write-Host (" - {0} (LastWrite: {1})" -f $_.FullName, (Format-Dt $_.LastWriteTime))
            }
        }

        Write-Status "Health check PASSED" "OK"
        exit 0
    }

    Write-Status "Mode: RequiredPatterns"
    Write-Status ("RequiredPatterns: {0}" -f ($RequiredPatterns -join ", "))
    Write-Status ("MinMatch: {0}" -f [string]$MinMatch)

    $matches = @()
    foreach ($p in $RequiredPatterns) {
        $matches += Get-RecentFilesByPattern -Dir $dataPath -Pattern $p -Threshold $threshold
    }

    $matches = @($matches | Sort-Object LastWriteTime -Desc)
    $count = $matches.Count

    if ($count -lt $MinMatch) {
        Write-Status ("Recent required outputs found: {0}, need at least: {1}" -f [string]$count, [string]$MinMatch) "WARN"

        if ($VerboseMode) {
            foreach ($p in $RequiredPatterns) {
                $latest = Get-ChildItem -LiteralPath $dataPath -Filter $p -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Desc | Select-Object -First 1
                if ($null -eq $latest) {
                    Write-Host (" - {0}: (no file)" -f $p)
                } else {
                    Write-Host (" - {0}: latest {1} ({2})" -f $p, (Format-Dt $latest.LastWriteTime), $latest.Name)
                }
            }
        }

        exit 2
    }

    Write-Status ("Found {0} recent required output file(s)" -f [string]$count)

    if ($VerboseMode) {
        $matches | Select-Object -First 50 | ForEach-Object {
            Write-Host (" - {0} (LastWrite: {1})" -f $_.FullName, (Format-Dt $_.LastWriteTime))
        }
    }

    Write-Status "Health check PASSED" "OK"
    exit 0
}
catch {
    Write-Status $_.Exception.Message "ERROR"
    exit 1
}
param()

$ErrorActionPreference = "Stop"

function Pause-Here([string]$msg="Press any key to continue...") {
  Write-Host ""
  Write-Host $msg -ForegroundColor Yellow
  $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

try {
  Set-Location "D:\projects\investment-assistant"

  $scriptPath = ".\scripts\top20_daily.ps1"
  if (!(Test-Path $scriptPath)) { throw "missing -> $scriptPath" }

  $bak = "$scriptPath.bak_{0}.ps1" -f (Get-Date -Format "yyyyMMdd_HHmmss")
  Copy-Item $scriptPath $bak -Force
  Write-Host "OK: backup -> $bak" -ForegroundColor DarkGray

  $lines = Get-Content $scriptPath -Encoding UTF8

  # Replace a safe range around the previous parser error line (1-based)
  $start = 210
  $end   = 235

  if ($lines.Count -lt $end) {
    throw ("file too short ({0} lines). can't patch range {1}..{2}" -f $lines.Count, $start, $end)
  }

  $before = @()
  if ($start -gt 1) { $before = $lines[0..($start-2)] }

  $after = @()
  if ($end -lt $lines.Count) { $after = $lines[$end..($lines.Count-1)] }

  $patch = @(
    '# ----------------------------'
    '# Market Score (0-100) + Aggressiveness (0-100)  [HARD NUMERIC]'
    '# ----------------------------'
    '$avgTotal = D (($norm | Measure-Object total_score -Average).Average) 0'
    ''
    '# Parser-safe: explicit parentheses for function calls'
    '$extremeCountRaw = @('
    '  $norm | Where-Object {'
    '    ( [math]::Abs( D (GetVal $_ "change_percent" 0) 0 ) -ge 8 ) -or'
    '    ( I (GetVal $_ "volatility" 0) 0 -ge 85 )'
    '  }'
    ').Count'
    '$extremeCount = I $extremeCountRaw 0'
    ''
    '$extremeRatio = if ($norm.Count -gt 0) { D (($extremeCount / [double]$norm.Count)) 0 } else { 0.0 }'
    ''
    '$breadthScore = 0.0'
    'if ($market) {'
    '  $den = D (($market.up_count + $market.down_count)) 0'
    '  if ($den -gt 0) {'
    '    $breadthScore = D ((D $market.up_count 0 / $den) * 40.0) 0'
    '  }'
    '}'
    ''
    '$avgScorePart = Clamp ((D $avgTotal 0 / 100.0) * 40.0) 0.0 40.0'
    '$penalty      = Clamp ($extremeRatio * 20.0) 0.0 20.0'
    ''
    '$marketScore = [int]([math]::Round((Clamp (($breadthScore + $avgScorePart + (40.0 - $penalty))) 0.0 100.0),0))'
    '$aggrScore   = [int]([math]::Round((Clamp (($breadthScore + $avgScorePart + (40.0 - (2.0 * $penalty)))) 0.0 100.0),0))'
    ''
    '$action = MarketAction $marketScore'
    ''
    '# ----------------------------'
    '# Allocation'
    '# ----------------------------'
  )

  $newLines = @()
  $newLines += $before
  $newLines += $patch
  $newLines += $after

  Set-Content -Path $scriptPath -Value $newLines -Encoding UTF8
  Write-Host ("OK: patched lines {0}..{1} -> {2}" -f $start,$end,$scriptPath) -ForegroundColor Green

  # Syntax check
  [void][scriptblock]::Create((Get-Content $scriptPath -Raw -Encoding UTF8))
  Write-Host "OK: syntax check PASS" -ForegroundColor Green

  Pause-Here "Patch done. Press any key to run Top20 report..."
  
  & .\scripts\top20_daily.ps1 -Date "2026-02-10" -Capital 100000 -Pick 5 -OpenReport

  Write-Host ""
  Write-Host "DONE" -ForegroundColor Green
  Pause-Here "Finished. Press any key to exit..."
}
catch {
  Write-Host ""
  Write-Host "ERROR:" -ForegroundColor Red
  Write-Host $_.Exception.GetType().FullName -ForegroundColor Yellow
  Write-Host $_.Exception.Message -ForegroundColor Yellow
  Write-Host ""
  Write-Host "TIP: You can rollback with the .bak file shown above." -ForegroundColor Yellow
  Pause-Here "Patch failed. Press any key to exit..."
  throw
}

Write-Host "=== Investment Assistant :: Phase ⑥-2 Best From Sweep ==="

$IN = "data/metrics_sweep.csv"
if (-not (Test-Path $IN)) {
    Write-Host "❌ Missing: $IN"
    exit 1
}

$rows = Import-Csv $IN | ForEach-Object {
    $_.return_pct   = [double]$_.return_pct
    $_.max_drawdown = [double]$_.max_drawdown
    $_.trades       = [int]$_.trades
    $_.end_value    = [double]$_.end_value
    $_
}

if (-not $rows) {
    Write-Host "❌ No rows found in $IN"
    exit 1
}

$rows_traded = $rows | Where-Object { $_.trades -gt 0 }

if ($rows_traded) {
    $best = $rows_traded | Sort-Object return_pct -Descending | Select-Object -First 1
    Write-Host "✔ Best picked from TRADED rows (trades > 0)"
} else {
    $best = $rows | Sort-Object return_pct -Descending | Select-Object -First 1
    Write-Host "⚠ No traded rows found; Best picked from ALL rows (may be trades=0)"
}

Write-Host "`n✔ Best Row:`n"
$best | Format-List

Remove-Item data\trades.csv -ErrorAction SilentlyContinue
Remove-Item data\equity.csv -ErrorAction SilentlyContinue
Remove-Item data\metrics.json -ErrorAction SilentlyContinue
Remove-Item data\portfolio.json -ErrorAction SilentlyContinue

# parse params: "short=1 long=3" / "period=14 os=30 ob=70"
$params = @{}
$best.params -split " " | ForEach-Object {
    $kv = $_ -split "="
    if ($kv.Count -eq 2) { $params[$kv[0]] = $kv[1] }
}

$pyArgs = @("--backtest", "--strategy", $best.strategy)

if ($best.strategy -eq "ma") {
    $pyArgs += @("--ma-short", $params["short"], "--ma-long", $params["long"])
}
elseif ($best.strategy -eq "rsi") {
    $pyArgs += @("--rsi-period", $params["period"], "--rsi-oversold", $params["os"], "--rsi-overbought", $params["ob"])
}
else {
    Write-Host "❌ Unknown strategy: $($best.strategy)"
    exit 1
}

python -m src.main @pyArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Backtest failed"
    exit 1
}

$best | ConvertTo-Json -Depth 3 | Out-File "data/best_from_sweep.json" -Encoding UTF8
Write-Host "✔ Wrote data/best_from_sweep.json"

Write-Host "`n=== OUTPUT CHECK ==="
"trades.csv exists:  $(Test-Path data/trades.csv)"
"equity.csv exists:  $(Test-Path data/equity.csv)"
"metrics.json exists: $(Test-Path data/metrics.json)"

Write-Host "`n=== Phase ⑥-2 DONE ==="

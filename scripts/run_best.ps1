Write-Host "=== Investment Assistant :: Phase ④ Best Params + Backtest ==="

# ---------- 0. Guards ----------
if (!(Test-Path data\metrics_sweep.csv)) {
    Write-Host "❌ metrics_sweep.csv not found. Run sweep first."
    exit 1
}

# ---------- 1. Select Best Params ----------
$rows = Import-Csv data\metrics_sweep.csv

# Sort: highest return_pct, then lowest max_drawdown
$best = $rows |
    Sort-Object @{Expression = {[double]$_.return_pct}; Descending = $true},
                @{Expression = {[double]$_.max_drawdown}; Ascending = $true} |
    Select-Object -First 1

$bestParams = @{
    ma_short = [int]$best.ma_short
    ma_long  = [int]$best.ma_long
    return_pct = [double]$best.return_pct
    max_drawdown = [double]$best.max_drawdown
    trades = [int]$best.trades
    end_value = [double]$best.end_value
}

$bestParams | ConvertTo-Json -Depth 5 | Set-Content data\best_params.json -Encoding UTF8

Write-Host "✔ Best Params Selected:"
$bestParams | Format-Table

# ---------- 2. Clean Old Outputs ----------
Remove-Item data\trades.csv -ErrorAction SilentlyContinue
Remove-Item data\equity.csv -ErrorAction SilentlyContinue
Remove-Item data\metrics.json -ErrorAction SilentlyContinue
Remove-Item data\portfolio.json -ErrorAction SilentlyContinue

# ---------- 3. Run Backtest With Best Params ----------
python -m src.main `
    --backtest `
    --csv data/2330.csv `
    --symbol 2330.TW `
    --ma-short $bestParams.ma_short `
    --ma-long  $bestParams.ma_long

Write-Host "=== Phase ④ DONE ==="

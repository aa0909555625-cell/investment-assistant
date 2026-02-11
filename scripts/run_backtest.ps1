Write-Host "=== Investment Assistant :: Phase ③ Backtest ==="

# ---------- Compile Check ----------
$files = @(
  "src/domain/portfolio.py",
  "src/services/broker.py",
  "src/services/equity.py",
  "src/services/metrics.py",
  "src/market_data.py",
  "src/strategy/ma_cross.py",
  "src/main.py"
)

foreach ($f in $files) {
  python -m py_compile $f
  if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Compile failed: $f"
    exit 1
  }
}

# ---------- Clean Outputs ----------
Remove-Item data\trades.csv  -ErrorAction SilentlyContinue
Remove-Item data\equity.csv  -ErrorAction SilentlyContinue
Remove-Item data\metrics.json -ErrorAction SilentlyContinue

# ---------- Run Backtest ----------
python -m src.main `
  --backtest `
  --csv data/2330.csv `
  --symbol 2330.TW `
  --ma-short 1 `
  --ma-long 2

# ---------- Summary ----------
Write-Host ""
Write-Host "=== OUTPUT : trades (head) ==="
if (Test-Path data\trades.csv) {
  Get-Content data\trades.csv | Select-Object -First 10
}

Write-Host ""
Write-Host "=== OUTPUT : equity (tail) ==="
if (Test-Path data\equity.csv) {
  Get-Content data\equity.csv | Select-Object -Last 5
}

Write-Host ""
Write-Host "=== OUTPUT : metrics ==="
if (Test-Path data\metrics.json) {
  Get-Content data\metrics.json
}

Write-Host ""
Write-Host "=== DONE ==="

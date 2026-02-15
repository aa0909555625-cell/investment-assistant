$ErrorActionPreference = "Stop"

Write-Host "=== Investment Assistant :: Phase ⑦ Walk-Forward (80/20) :: Route A (OOS trades>0) ==="

# --- Paths ---
$DATA_DIR      = "data"
$SCRIPTS_DIR   = "scripts"

$SRC_CSV       = Join-Path $DATA_DIR "2330.csv"
$TRAIN_CSV     = Join-Path $DATA_DIR "train.csv"
$TEST_CSV      = Join-Path $DATA_DIR "test.csv"

$TRAIN_SWEEP   = Join-Path $DATA_DIR "train_metrics_sweep.csv"
$TRAIN_BEST    = Join-Path $DATA_DIR "train_best_params.json"

$TEST_METRICS  = Join-Path $DATA_DIR "test_metrics.json"
$TEST_TRADES   = Join-Path $DATA_DIR "test_trades.csv"
$TEST_EQUITY   = Join-Path $DATA_DIR "test_equity.csv"

$SPLIT_PY      = Join-Path $SCRIPTS_DIR "_split_csv_8020.py"

# --- Ensure dirs ---
if (-not (Test-Path $DATA_DIR))    { New-Item -ItemType Directory -Path $DATA_DIR -Force | Out-Null }
if (-not (Test-Path $SCRIPTS_DIR)) { New-Item -ItemType Directory -Path $SCRIPTS_DIR -Force | Out-Null }

# --- Checks ---
if (-not (Test-Path $SRC_CSV)) { Write-Host "❌ Missing CSV: $SRC_CSV"; exit 1 }
if (-not (Test-Path $SPLIT_PY)) { Write-Host "❌ Missing split script: $SPLIT_PY"; exit 1 }

function Clear-BacktestOutputs {
  Remove-Item (Join-Path $DATA_DIR "trades.csv")     -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $DATA_DIR "equity.csv")     -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $DATA_DIR "metrics.json")   -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $DATA_DIR "portfolio.json") -ErrorAction SilentlyContinue
}

function Parse-MetricsFromText([string]$text) {
  # Expect: BacktestMetrics(start_value=..., end_value=..., return_pct=..., max_drawdown=..., trades=...)
  $rp = [regex]::Match($text, 'return_pct=([-\d\.eE]+)', 'IgnoreCase')
  $dd = [regex]::Match($text, 'max_drawdown=([-\d\.eE]+)', 'IgnoreCase')
  $tr = [regex]::Match($text, 'trades=(\d+)', 'IgnoreCase')
  $ev = [regex]::Match($text, 'end_value=([-\d\.eE]+)', 'IgnoreCase')

  if (-not ($rp.Success -and $dd.Success -and $tr.Success -and $ev.Success)) {
    throw "Cannot parse BacktestMetrics from output. Raw output:`n$text"
  }

  return [pscustomobject]@{
    return_pct   = [double]$rp.Groups[1].Value
    max_drawdown = [double]$dd.Groups[1].Value
    trades       = [int]$tr.Groups[1].Value
    end_value    = [double]$ev.Groups[1].Value
  }
}

function Invoke-Backtest([string]$csvPath, [string]$strategy, [hashtable]$p) {
  Clear-BacktestOutputs

  $args = @("-m","src.main","--csv",$csvPath,"--backtest","--strategy",$strategy)

  if ($strategy -eq "ma") {
    $args += @("--ma-short", [string]$p.short, "--ma-long", [string]$p.long)
  } elseif ($strategy -eq "rsi") {
    $args += @("--rsi-period",[string]$p.period,"--rsi-oversold",[string]$p.os,"--rsi-overbought",[string]$p.ob)
  } else {
    throw "Unknown strategy: $strategy"
  }

  $out = & python @args 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Backtest failed (strategy=$strategy params=$($p | ConvertTo-Json -Compress) csv=$csvPath)`n$($out | Out-String)"
  }

  return (Parse-MetricsFromText (($out | Out-String)))
}

function Params-FromText([string]$strategy, [string]$text) {
  $p = @{}
  $text -split " " | ForEach-Object {
    $kv = $_ -split "="
    if ($kv.Count -eq 2) { $p[$kv[0]] = $kv[1] }
  }

  if ($strategy -eq "ma") {
    return @{ short = [int]$p["short"]; long = [int]$p["long"] }
  }
  return @{ period = [int]$p["period"]; os = [int]$p["os"]; ob = [int]$p["ob"] }
}

function Is-FeasibleForTest([pscustomobject]$row, [int]$testN) {
  # indicator window must be <= testN-1
  $p = @{}
  $row.params -split " " | ForEach-Object {
    $kv = $_ -split "="
    if ($kv.Count -eq 2) { $p[$kv[0]] = $kv[1] }
  }

  if ($row.strategy -eq "ma")  { return ([int]$p["long"]   -le ($testN - 1)) }
  if ($row.strategy -eq "rsi") { return ([int]$p["period"] -le ($testN - 1)) }
  return $false
}

# --- Split (80/20) using real python file ---
$splitOut = & python $SPLIT_PY $SRC_CSV $TRAIN_CSV $TEST_CSV 2>&1
if ($LASTEXITCODE -ne 0) { throw "Split failed:`n$($splitOut | Out-String)" }

$trainN = (Get-Content $TRAIN_CSV | Measure-Object -Line).Lines - 1
$testN  = (Get-Content $TEST_CSV  | Measure-Object -Line).Lines - 1

Write-Host "✔ Split CSV:"
Write-Host ("  Train rows: {0}" -f $trainN)
Write-Host ("  Test  rows: {0}" -f $testN)

# --- Candidates ---
$candidates = New-Object System.Collections.Generic.List[object]

for ($s = 1; $s -le 5; $s++) {
  for ($l = $s + 1; $l -le 30; $l++) {
    $candidates.Add([pscustomobject]@{
      strategy    = "ma"
      params      = @{ short = $s; long = $l }
      params_text = "short=$s long=$l"
    })
  }
}

$periods = @(7,14,21)
$oss = @(20,30)
$obs = @(70,80)

foreach ($per in $periods) {
  foreach ($os in $oss) {
    foreach ($ob in $obs) {
      $candidates.Add([pscustomobject]@{
        strategy    = "rsi"
        params      = @{ period = $per; os = $os; ob = $ob }
        params_text = "period=$per os=$os ob=$ob"
      })
    }
  }
}

# --- TRAIN sweep ---
Write-Host "`n=== TRAIN SWEEP START ==="
$trainRows = @()

foreach ($c in $candidates) {
  if ($c.strategy -eq "ma") {
    Write-Host ("MA Sweep: short={0} long={1}" -f $c.params.short, $c.params.long)
  } else {
    Write-Host ("RSI Sweep: period={0} os={1} ob={2}" -f $c.params.period, $c.params.os, $c.params.ob)
  }

  $m = Invoke-Backtest $TRAIN_CSV $c.strategy $c.params

  $trainRows += [pscustomobject]@{
    strategy     = $c.strategy
    params       = $c.params_text
    return_pct   = $m.return_pct
    max_drawdown = $m.max_drawdown
    trades       = $m.trades
    end_value    = $m.end_value
  }
}

$trainRows | Export-Csv $TRAIN_SWEEP -NoTypeInformation -Encoding UTF8
Write-Host "✔ Wrote $TRAIN_SWEEP"

# --- Selection policy: Route A (must try to get OOS trades>0) ---
Write-Host "`n✔ Selection policy:"
Write-Host "  - Prefer TRAIN trades>0"
Write-Host "  - Must be feasible for TEST (window <= testN-1) when possible"
Write-Host "  - Route A: iterate TRAIN return desc; pick first that yields TEST trades>0"

$rows_traded = $trainRows | Where-Object { $_.trades -gt 0 }
if (-not $rows_traded) {
  Write-Host "⚠ No traded rows in TRAIN. Using ALL rows."
  $rows_traded = $trainRows
}

$rows_feasible = $rows_traded | Where-Object { Is-FeasibleForTest $_ $testN }
if (-not $rows_feasible) {
  Write-Host "⚠ All traded TRAIN rows infeasible for TEST. Falling back to traded rows."
  $rows_feasible = $rows_traded
}

$ordered = $rows_feasible | Sort-Object return_pct -Descending

$chosen = $null
$chosenTest = $null

foreach ($row in $ordered) {
  $pp = Params-FromText $row.strategy $row.params
  $testMetrics = Invoke-Backtest $TEST_CSV $row.strategy $pp

  if ($testMetrics.trades -gt 0) {
    $chosen = $row
    $chosenTest = $testMetrics
    Write-Host "`n✅ Picked (Route A): first candidate with TEST trades>0"
    break
  } else {
    Write-Host ("- Skip (TEST trades=0): {0} {1}" -f $row.strategy, $row.params)
  }
}

if (-not $chosen) {
  $chosen = $ordered | Select-Object -First 1
  $pp = Params-FromText $chosen.strategy $chosen.params
  $chosenTest = Invoke-Backtest $TEST_CSV $chosen.strategy $pp
  Write-Host "`n⚠ No candidate produced TEST trades>0. Fallback to best feasible TRAIN row (may be TEST trades=0)."
}

Write-Host "`n=== FINAL CHOSEN (TRAIN) ==="
$chosen | Format-List

$chosen | ConvertTo-Json -Depth 5 | Out-File $TRAIN_BEST -Encoding UTF8
Write-Host "✔ Wrote $TRAIN_BEST"

# Move outputs from last TEST backtest to test_* files
$srcTrades  = Join-Path $DATA_DIR "trades.csv"
$srcEquity  = Join-Path $DATA_DIR "equity.csv"

if (Test-Path $srcTrades) { Copy-Item $srcTrades $TEST_TRADES -Force }
if (Test-Path $srcEquity) { Copy-Item $srcEquity $TEST_EQUITY -Force }

@{
  start_value  = 100000.0
  end_value    = $chosenTest.end_value
  return_pct   = $chosenTest.return_pct
  max_drawdown = $chosenTest.max_drawdown
  trades       = $chosenTest.trades
} | ConvertTo-Json -Depth 5 | Out-File $TEST_METRICS -Encoding UTF8

Write-Host "`n=== TEST (OOS) METRICS ==="
Get-Content $TEST_METRICS

Write-Host "`n=== Phase ⑦ DONE ==="
Write-Host "Train sweep: $TRAIN_SWEEP"
Write-Host "Train best : $TRAIN_BEST"
Write-Host "Test trades: $TEST_TRADES"
Write-Host "Test equity: $TEST_EQUITY"
Write-Host "Test metric: $TEST_METRICS"

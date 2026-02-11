# Strategy Baseline v1.0 (2330)

## Frozen Definition
- RSI(14) timing
- Trend gate: SMA(50/200), trend_mode = both
- Single position, all-in (no pyramiding)
- Exit: RSI signal OR trend_break (close < SMA50)  (exit_mode=both, trend_exit=sma_fast)
- cooldown_bars = 2
- stop_loss = 0 (not enabled)
- slippage_bps = 0 (not enabled)
- fees: buy_fee=0.001425, sell_fee=0.001425, sell_tax=0.003

## Baseline Command (for reproducibility)
.\.venv\Scripts\python.exe .\scripts\run_pipeline.py --symbol 2330 --in data/2330.csv --rsi_period 14 --buy_rsi 50 --sell_rsi 60 --cooldown_bars 2

## Baseline Result (from reports/report_2330.md)
- Period: 2024-02-15 → 2026-02-10
- Start Equity: 1,000,000
- End Equity: 1,358,537
- Total Return: 35.85%
- Max Drawdown: -10.84%
- Sharpe (rough): 1.19
- Trades: 7
- Win Rate: 42.86%
- Avg Hold Days: 24

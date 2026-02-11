# Strategy Baseline v1.5 (2330)

## Core Idea
RSI timing + Trend-following exits with trailing stop.
Designed for capturing long trends with minimal trades.

## Parameters
- RSI period: 14
- Buy RSI >= 50
- Exit mode: trend-only
- Trend exit: SMA_fast
- Trailing stop (low-based): 10%
- Hard stop loss (low-based): 4%
- Cooldown bars: 2
- Slippage: 5 bps
- Position: single, all-in
- No pyramiding, no RSI sell exit

## Final Results
- End Equity: 1,415,837
- Total Return: 41.58%
- Max Drawdown: -11.40%
- Sharpe (rough): 1.28
- Trades: 4
- Win Rate: 25%

## Baseline Command
python scripts/phase6_backtest_singlepos.py \
  --in data/phase5_signals_2330.csv \
  --exit_mode trend \
  --trend_exit sma_fast \
  --stop_loss 0.04 --stop_loss_mode low \
  --trailing_stop 0.10 --trailing_mode low \
  --cooldown_bars 2 --slippage_bps 5

## Regime-based Allocation (Monthly)
We run monthly regime check using month-end Close/SMA50/SMA200.

### Base rule
- If strong_trend = True (Close > SMA200 AND SMA50 > SMA200): allocation_base = v1.1=60% / v1.5=40%
- Else: allocation_base = v1.1=80% / v1.5=20%

### Overheat downgrade rule (risk control)
- Compute dist_to_sma50_pct = (Close / SMA50 - 1)
- If dist_to_sma50_pct >= 10%: allocation_final = v1.1=80% / v1.5=20% (downgrade: overheated)
- Else: allocation_final = allocation_base

### Latest snapshot
- Month: 2026-02
- Date:  2026-02-10
- Close: 1880.0
- SMA50: 1624.6
- SMA200:1298.575
- StrongTrend: True
- DistToSMA50(%): 15.72
- Overheated: True
- AllocationFinal: v1.1=80% / v1.5=20% (downgrade: overheated)


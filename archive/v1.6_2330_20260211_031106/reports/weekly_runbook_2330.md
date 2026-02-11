# Weekly Runbook (2330)

## Latest Monthly Regime Snapshot
- Month: 2026-02
- Date:  2026-02-10
- Close: 1880.0
- SMA50: 1624.6
- SMA200:1298.575
- StrongTrend: True
- DistToSMA50(%): 15.72
- Overheated: True
- AllocationFinal: v1.1=80% / v1.5=20% (downgrade: overheated)

## Strategy Metrics (Core 6 lines)

### v1.1 (baseline / exit_mode=both)
- End Equity: 1,358,537
- Total Return: 35.85%
- Max Drawdown: -10.84%
- Sharpe (rough): 1.19
- Trade Count: 7
- Win Rate: 42.86%

### v1.5 (trend-only / stop_loss_low 4% / trailing_low 10%)
- End Equity: 1,415,837
- Total Return: 41.58%
- Max Drawdown: -11.40%
- Sharpe (rough): 1.28
- Trade Count: 4
- Win Rate: 25.00%

## Recent Trades (v1.5 last 5)
| entry_date | exit_date | entry_price | exit_price | return_pct | exit_reason |
|---|---|---:|---:|---:|---|
| 2024-12-23 | 2025-02-14 | 1080.54 | 1059.47 | -1.95% | trend_break |
| 2025-02-18 | 2025-02-20 | 1100.55 | 1079.46 | -1.92% | trend_break |
| 2025-08-21 | 2025-11-21 | 1150.575 | 1384.3075 | 20.31% | trend_break |
| 2025-11-26 | 2025-12-01 | 1440.72 | 1409.295 | -2.18% | trend_break |

## Output Files (isolated)
- v1.1 trades: data\phase6_trades_2330_v11.csv
- v1.1 equity: data\phase6_equity_2330_v11.csv
- v1.5 trades: data\phase6_trades_2330_v15.csv
- v1.5 equity: data\phase6_equity_2330_v15.csv

## Action (this week)
- Follow AllocationFinal: **v1.1=80% / v1.5=20% (downgrade: overheated)**
